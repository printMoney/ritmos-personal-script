#!/bin/bash
# Builds "QuickToggles.app" (menu bar app) and installs it to ~/Applications.
# Needs Xcode Command Line Tools (run `xcode-select --install` once if missing).
#
# Personal script, provided as-is with no warranty: use at your own risk.
# https://github.com/printMoney/ritmos-personal-script
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/QuickToggles.app"
SRC="$(mktemp -d)/main.swift"

cat > "$SRC" <<'SWIFT'
import Cocoa
import IOKit
import IOKit.hid

// The dropdown is a small panel of our own: macOS 27 pushes a standard menu-bar menu ~30pt
// below the menu bar on Macs with a notch, and keeps moving it back there.
final class TogglePanel: NSPanel {
    var onCancel: (() -> Void)?
    var onQuit: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel?() }   // Esc closes it
    override func performKeyEquivalent(with event: NSEvent) -> Bool {   // ⌘Q quits
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "q" { onQuit?(); return true }
        return super.performKeyEquivalent(with: event)
    }
}

// A plain menu-style row (like "Quit Claude" in Claude's menu): text that highlights on hover,
// with an optional symbol on the right (the Preferences chevron).
final class MenuRow: NSView {
    let label: NSTextField
    let accessory = NSImageView()
    let onClick: () -> Void

    init(title: String, symbol: String? = nil, onClick: @escaping () -> Void) {
        label = NSTextField(labelWithString: title)
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 13
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        accessory.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        addSubview(accessory)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 26),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        if let symbol = symbol { setSymbol(symbol) }
        setHighlighted(false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setSymbol(_ name: String) {
        accessory.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
    }
    func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on ? NSColor.selectedContentBackgroundColor.cgColor : nil
        label.textColor = on ? .white : .labelColor
        accessory.contentTintColor = on ? .white : .secondaryLabelColor
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { setHighlighted(true) }
    override func mouseExited(with event: NSEvent) { setHighlighted(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}

// One Control Center-style row: a round toggle button with an icon, then a title and subtitle.
// On macOS 26+ the button is Liquid Glass and fills with the accent color when on.
final class ToggleRow: NSStackView {
    let circle: NSButton
    let subtitleLabel: NSTextField
    var state: NSControl.StateValue = .off { didSet { applyState() } }

    init(symbol: String, title: String, subtitle: String, target: AnyObject, action: Selector) {
        let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        circle = NSButton(image: icon ?? NSImage(), target: target, action: action)
        subtitleLabel = NSTextField(labelWithString: subtitle)
        super.init(frame: .zero)
        edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)   // icon lands 16pt from the panel edge
        circle.imagePosition = .imageOnly
        circle.imageScaling = .scaleProportionallyDown
        circle.widthAnchor.constraint(equalToConstant: 30).isActive = true
        circle.heightAnchor.constraint(equalToConstant: 30).isActive = true
        circle.controlSize = .large
        circle.bezelStyle = .circular
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            circle.bezelStyle = .glass
            circle.borderShape = .circle
            circle.controlSize = .extraLarge
        }
        #endif
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.addGestureRecognizer(NSClickGestureRecognizer(target: target, action: action))   // the text toggles too
        orientation = .horizontal
        alignment = .centerY
        spacing = 12
        addArrangedSubview(circle)
        addArrangedSubview(labels)
        applyState()
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func applyState() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            circle.tintProminence = state == .on ? .primary : .none
            return
        }
        #endif
        circle.contentTintColor = state == .on ? .controlAccentColor : .secondaryLabelColor
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var caffeinate: Process?
    var iconName = ""
    lazy var awakeItem = ToggleRow(symbol: "cup.and.saucer.fill", title: "Keep Display Awake",
                                   subtitle: "caffeinate -d, turns off after 45 min", target: self, action: #selector(toggleAwake))
    lazy var fnItem = ToggleRow(symbol: "keyboard", title: "Standard Function Keys",
                                subtitle: "F1–F12 without holding fn", target: self, action: #selector(toggleFn))
    lazy var nightItem = ToggleRow(symbol: "moon.fill", title: "Night Mode",
                                   subtitle: "Night Shift, True Tone and Auto-Brightness", target: self, action: #selector(toggleNight))
    lazy var prefsRow = MenuRow(title: "Preferences", symbol: "chevron.right") { [weak self] in self?.togglePreferences() }
    let descRow = NSStackView()
    lazy var descRowHeight = descRow.heightAnchor.constraint(equalToConstant: 0)
    let descSwitch = NSSwitch()
    lazy var quitRow = MenuRow(title: "Quit QuickToggles") { [weak self] in self?.quit() }
    let panel = TogglePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    var clickMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        setupNight()
        // Spacing follows macOS menu-bar menus (Claude's included): rows sit 6pt in from the panel
        // edge with their text at 16pt, and separators are inset to the text.
        let descLabel = NSTextField(labelWithString: "Show Descriptions")
        descLabel.font = .systemFont(ofSize: 13)
        descSwitch.controlSize = .small
        descSwitch.state = showDescriptions ? .on : .off
        descSwitch.target = self
        descSwitch.action = #selector(descriptionsSwitched(_:))
        descRow.orientation = .horizontal
        descRow.alignment = .centerY
        descRow.distribution = .equalSpacing
        descRow.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        descRow.addArrangedSubview(descLabel)
        descRow.addArrangedSubview(descSwitch)
        descRowHeight.isActive = true
        setPreferencesExpanded(false)   // revealed by the Preferences row
        applyDescriptions()

        let prefsLine = makeSeparator(), quitLine = makeSeparator()
        let stack = NSStackView(views: [awakeItem, fnItem, nightItem, prefsLine, prefsRow, descRow, quitLine, quitRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 6, bottom: 5, right: 6)
        stack.setCustomSpacing(8, after: nightItem)
        stack.setCustomSpacing(1, after: prefsLine)
        stack.setCustomSpacing(0, after: prefsRow)
        stack.setCustomSpacing(0, after: descRow)
        stack.setCustomSpacing(1, after: quitLine)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        for row in stack.arrangedSubviews {   // every row spans the panel, 6pt in from each side
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true
        }

        let background = makeBackground(around: stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        panel.setContentSize(background.fittingSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.closePanel() }
        panel.onQuit = { [weak self] in self?.quit() }

        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        refresh()
    }

    // Liquid Glass on macOS 26+, the frosted menu material on older systems.
    func makeBackground(around content: NSView) -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 22
            glass.contentView = content
            return glass
        }
        #endif
        let frosted = NSVisualEffectView()
        frosted.material = .menu
        frosted.state = .active
        frosted.maskImage = roundedMask(radius: 12)
        frosted.addSubview(content)
        return frosted
    }

    func roundedMask(radius: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // Opens right under the menu bar, lined up with the icon. Click outside it, press Esc
    // or click the icon again to close it.
    @objc func togglePanel() {
        if panel.isVisible { closePanel(); return }
        guard let button = statusItem.button, let window = button.window else { return }
        refresh()
        quitRow.setHighlighted(false)
        prefsRow.setHighlighted(false)
        setPreferencesExpanded(false)   // Preferences starts collapsed each time
        if let content = panel.contentView { content.layoutSubtreeIfNeeded(); panel.setContentSize(content.fittingSize) }
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? icon
        let x = min(icon.minX, visible.maxX - panel.frame.width - 6)
        panel.setFrameTopLeftPoint(NSPoint(x: x, y: min(icon.minY, visible.maxY) - 2))
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            // a click on the icon itself toggles the panel through togglePanel() instead
            if let iconWindow = self.statusItem.button?.window, iconWindow.frame.contains(NSEvent.mouseLocation) { return }
            self.closePanel()
        }
    }

    func closePanel() {
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
    }

    func makeSeparator() -> NSView {   // a hairline inset to the text, centered in 9pt of space
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        let space = NSView()
        space.addSubview(line)
        NSLayoutConstraint.activate([
            space.heightAnchor.constraint(equalToConstant: 9),
            line.leadingAnchor.constraint(equalTo: space.leadingAnchor, constant: 10),
            line.trailingAnchor.constraint(equalTo: space.trailingAnchor, constant: -10),
            line.centerYAnchor.constraint(equalTo: space.centerYAnchor),
        ])
        return space
    }

    // MARK: Preferences (one option: show or hide the description under each toggle)
    var showDescriptions: Bool {
        get { UserDefaults.standard.object(forKey: "ShowDescriptions") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "ShowDescriptions") }
    }

    func applyDescriptions() {
        for row in [awakeItem, fnItem, nightItem] { row.subtitleLabel.isHidden = !showDescriptions }
    }

    @objc func descriptionsSwitched(_ sender: NSSwitch) {
        showDescriptions = sender.state == .on
        applyDescriptions()
        resizePanel()
    }

    // The option row collapses to zero height instead of being hidden, so it keeps its constraints.
    func setPreferencesExpanded(_ expanded: Bool) {
        descRowHeight.constant = expanded ? 26 : 0
        descRow.arrangedSubviews.forEach { $0.isHidden = !expanded }
        prefsRow.setSymbol(expanded ? "chevron.down" : "chevron.right")
    }

    func togglePreferences() {
        setPreferencesExpanded(descRowHeight.constant == 0)
        resizePanel()
    }

    func resizePanel() {   // grow or shrink downward, keeping the top edge under the menu bar
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        panel.setFrame(NSRect(x: panel.frame.minX, y: panel.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    func refresh() {
        let awake = caffeinate?.isRunning ?? false
        awakeItem.state = awake ? .on : .off
        fnItem.state = fnEnabled() ? .on : .off
        nightItem.state = nightAllOn() ? .on : .off
        let name = awake ? "cup.and.saucer.fill" : "cup.and.saucer"
        if name != iconName {   // only touch the menu bar icon when it actually changes
            iconName = name
            statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Quick Toggles")
        }
    }

    // MARK: caffeinate
    @objc func toggleAwake() {
        if let p = caffeinate, p.isRunning {
            p.terminate()
            caffeinate = nil
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-d", "-t", "2700"]   // display stays awake for at most 45 minutes
            p.terminationHandler = { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }
            try? p.run()
            caffeinate = p
        }
        refresh()
    }

    // MARK: Fn keys
    let prefKey = "com.apple.keyboard.fnState" as CFString

    func fnEnabled() -> Bool {
        let v = CFPreferencesCopyValue(prefKey, kCFPreferencesAnyApplication,
                                       kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (v as? Bool) ?? ((v as? NSNumber)?.boolValue ?? false)
    }

    @objc func toggleFn() {
        let on = !fnEnabled()
        // 1) persist the setting (what System Settings does)
        CFPreferencesSetValue(prefKey, on as CFBoolean, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        // 2) apply live to the keyboard driver
        let service = IOServiceGetMatchingService(mach_port_t(0), IOServiceMatching(kIOHIDSystemClass))
        if service != 0 {
            var connect: io_connect_t = 0
            if IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS {
                var value: UInt32 = on ? 1 : 0
                _ = IOHIDSetParameter(connect, "HIDFKeyMode" as CFString, &value, 4)
                IOServiceClose(connect)
            }
            IOObjectRelease(service)
        }
        // 3) tell other parts of the system
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("com.apple.keyboard.fnStateDidChange"), object: nil,
            userInfo: nil, deliverImmediately: true)
        refresh()
    }

    // MARK: Night mode (private Apple frameworks, loaded at runtime)
    typealias SendVoidBool = @convention(c) (AnyObject, Selector, Bool) -> Void
    typealias SendGetBool = @convention(c) (AnyObject, Selector) -> Bool
    typealias SendStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Bool
    typealias DSSet = @convention(c) (UInt32, Bool) -> Int32
    typealias DSGet = @convention(c) (UInt32, UnsafeMutablePointer<Bool>) -> Int32

    var msgSend: UnsafeMutableRawPointer?
    var blueLight: AnyObject?
    var trueTone: AnyObject?
    var dsSet: DSSet?
    var dsGet: DSGet?
    var builtinDisplay: UInt32 = 0

    func setupNight() {
        msgSend = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "objc_msgSend")
        _ = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_LAZY)
        blueLight = (NSClassFromString("CBBlueLightClient") as? NSObject.Type)?.init()
        trueTone = (NSClassFromString("CBTrueToneClient") as? NSObject.Type)?.init()
        if let ds = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY) {
            if let s = dlsym(ds, "DisplayServicesEnableAmbientLightCompensation") { dsSet = unsafeBitCast(s, to: DSSet.self) }
            if let g = dlsym(ds, "DisplayServicesAmbientLightCompensationEnabled") { dsGet = unsafeBitCast(g, to: DSGet.self) }
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetActiveDisplayList(16, &ids, &count)
        builtinDisplay = ids.prefix(Int(count)).first(where: { CGDisplayIsBuiltin($0) != 0 }) ?? CGMainDisplayID()
    }

    func callBool(_ obj: AnyObject, _ sel: String) -> Bool {
        guard let m = msgSend, obj.responds(to: Selector(sel)) else { return false }
        return unsafeBitCast(m, to: SendGetBool.self)(obj, Selector(sel))
    }
    func callSet(_ obj: AnyObject, _ sel: String, _ v: Bool) {
        guard let m = msgSend, obj.responds(to: Selector(sel)) else { return }
        unsafeBitCast(m, to: SendVoidBool.self)(obj, Selector(sel), v)
    }

    func nightShiftOn() -> Bool {
        guard let m = msgSend, let c = blueLight, c.responds(to: Selector(("getBlueLightStatus:"))) else { return false }
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 8)
        defer { buf.deallocate() }
        memset(buf, 0, 128)
        _ = unsafeBitCast(m, to: SendStatus.self)(c, Selector(("getBlueLightStatus:")), buf)
        return buf.load(as: UInt8.self) != 0   // first byte = "active"
    }
    func trueToneAvailable() -> Bool { trueTone.map { callBool($0, "supported") } ?? false }
    func trueToneOn() -> Bool { trueTone.map { callBool($0, "enabled") } ?? false }
    func autoBrightnessOn() -> Bool {
        var v = false
        if let g = dsGet, g(builtinDisplay, &v) == 0 { return v }
        return false
    }

    func nightAllOn() -> Bool {
        var on = nightShiftOn() || blueLight == nil
        if trueToneAvailable() { on = on && trueToneOn() }
        if dsGet != nil { on = on && autoBrightnessOn() }
        return on
    }

    @objc func toggleNight() {
        let target = !nightAllOn()
        if let c = blueLight { callSet(c, "setEnabled:", target) }
        if let t = trueTone, trueToneAvailable() { callSet(t, "setEnabled:", target) }
        _ = dsSet?(builtinDisplay, target)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.refresh() }
        refresh()
    }

    @objc func quit() {
        caffeinate?.terminate()
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
SWIFT

# Quit a running copy (and its caffeinate helper) so the new build actually launches.
if pgrep -x QuickToggles >/dev/null; then
  pkill -P "$(pgrep -d , -x QuickToggles)" caffeinate 2>/dev/null || true
  pkill -x QuickToggles || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x QuickToggles >/dev/null || break; sleep 0.3; done
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O "$SRC" -o "$APP/Contents/MacOS/QuickToggles"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>QuickToggles</string>
  <key>CFBundleIdentifier</key><string>local.quicktoggles</string>
  <key>CFBundleExecutable</key><string>QuickToggles</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || true
echo "Installed: $APP"
open "$APP"
