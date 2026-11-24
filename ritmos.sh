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

// Holds the glass with some room around it for a soft shadow. The shadow belongs to this view's
// layer, so it scales and fades together with the open and close animations.
final class PanelHostView: NSView {
    static let margin: CGFloat = 24
    var cornerRadius: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let soft = NSShadow()
        soft.shadowColor = NSColor.black.withAlphaComponent(0.28)
        soft.shadowBlurRadius = 20
        soft.shadowOffset = NSSize(width: 0, height: -8)
        shadow = soft
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let m = PanelHostView.margin
        layer?.shadowPath = CGPath(roundedRect: bounds.insetBy(dx: m, dy: m), cornerWidth: cornerRadius,
                                   cornerHeight: cornerRadius, transform: nil)
    }
}

// A transform that scales a layer by `s` around `pivot` (a point in the layer's own coordinates).
func scaleTransform(_ s: CGFloat, around pivot: CGPoint, of layer: CALayer, size: CGSize) -> CATransform3D {
    let px = pivot.x - layer.anchorPoint.x * size.width
    let py = pivot.y - layer.anchorPoint.y * size.height
    var t = CATransform3DMakeTranslation(px, py, 0)
    t = CATransform3DScale(t, s, s, 1)
    return CATransform3DTranslate(t, -px, -py, 0)
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
        setHighlighted(false, animated: false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    func setSymbol(_ name: String) {
        accessory.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
    }
    func setHighlighted(_ on: Bool, animated: Bool = true) {   // the highlight fades in and out
        let color = on ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
        if animated, let layer = layer {
            let fade = CABasicAnimation(keyPath: "backgroundColor")
            fade.fromValue = layer.presentation()?.backgroundColor ?? layer.backgroundColor
            fade.toValue = color
            fade.duration = on ? 0.1 : 0.22
            layer.add(fade, forKey: "highlight")
        }
        layer?.backgroundColor = color
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
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 22, weight: .medium))
        circle = NSButton(image: icon ?? NSImage(), target: target, action: action)
        subtitleLabel = NSTextField(labelWithString: subtitle)
        super.init(frame: .zero)
        edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)   // icon lands 16pt from the panel edge
        circle.imagePosition = .imageOnly
        circle.imageScaling = .scaleNone
        circle.widthAnchor.constraint(equalToConstant: 44).isActive = true
        circle.heightAnchor.constraint(equalToConstant: 44).isActive = true
        circle.isBordered = false   // older macOS: just the tinted icon
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            circle.isBordered = true
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
        NSAnimationContext.runAnimationGroup { context in   // let the fill fade rather than snap
            context.duration = 0.25
            context.allowsImplicitAnimation = true
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                self.circle.tintProminence = self.state == .on ? .primary : .none
                return
            }
            #endif
            self.circle.contentTintColor = self.state == .on ? .controlAccentColor : .secondaryLabelColor
        }
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
    let descSwitch = NSSwitch()
    let opacitySlider = NSSlider()
    let bounceSlider = NSSlider()
    let speedSlider = NSSlider()
    let prefsClip = NSView()          // shows the preference rows like a drawer
    let prefsContent = NSStackView()
    lazy var prefsClipHeight = prefsClip.heightAnchor.constraint(equalToConstant: 0)
    var glassView: NSView?
    lazy var quitRow = MenuRow(title: "Quit QuickToggles") { [weak self] in self?.quit() }
    let panel = TogglePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let host = PanelHostView()
    var panelOpen = false
    var openPivot = CGPoint.zero   // where the panel grows from: the glass edge right under the icon
    var clickMonitor: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        setupNight()
        // Spacing follows macOS menu-bar menus (Claude's included): rows sit 6pt in from the panel
        // edge with their text at 16pt, and separators are inset to the text.
        descSwitch.controlSize = .small
        descSwitch.state = showDescriptions ? .on : .off
        descSwitch.target = self
        descSwitch.action = #selector(descriptionsSwitched(_:))
        setUpSlider(opacitySlider, value: glassOpacity, continuous: true, action: #selector(opacityChanged(_:)))
        setUpSlider(bounceSlider, value: bounce, continuous: false, action: #selector(feelChanged(_:)))
        setUpSlider(speedSlider, value: speed, continuous: false, action: #selector(feelChanged(_:)))
        var prefRows = [prefRow("Show Descriptions", descSwitch)]
        if liquidGlassAvailable { prefRows.append(prefRow("Background Opacity", opacitySlider)) }
        prefRows += [prefRow("Animation Bounce", bounceSlider), prefRow("Animation Speed", speedSlider)]
        prefsContent.orientation = .vertical
        prefsContent.alignment = .leading
        prefsContent.spacing = 0
        prefsContent.translatesAutoresizingMaskIntoConstraints = false
        for row in prefRows {
            prefsContent.addArrangedSubview(row)
            row.trailingAnchor.constraint(equalTo: prefsContent.trailingAnchor).isActive = true
        }
        prefsClip.wantsLayer = true
        prefsClip.layer?.masksToBounds = true   // the rows are revealed as the drawer opens
        prefsClip.addSubview(prefsContent)
        NSLayoutConstraint.activate([
            prefsContent.topAnchor.constraint(equalTo: prefsClip.topAnchor),
            prefsContent.leadingAnchor.constraint(equalTo: prefsClip.leadingAnchor),
            prefsContent.trailingAnchor.constraint(equalTo: prefsClip.trailingAnchor),
            prefsClipHeight,
        ])
        setPreferencesExpanded(false, animated: false)   // opened from the Preferences row
        applyDescriptions(animated: false)

        let prefsLine = makeSeparator(), quitLine = makeSeparator()
        let stack = NSStackView(views: [awakeItem, fnItem, nightItem, prefsLine, prefsRow, prefsClip, quitLine, quitRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 6, bottom: 5, right: 6)
        stack.setCustomSpacing(8, after: nightItem)
        stack.setCustomSpacing(1, after: prefsLine)
        stack.setCustomSpacing(0, after: prefsRow)
        stack.setCustomSpacing(0, after: prefsClip)
        stack.setCustomSpacing(1, after: quitLine)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        for row in stack.arrangedSubviews {   // every row spans the panel, 6pt in from each side
            row.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -6).isActive = true
        }

        // While the panel animates to a new size the content can briefly be bigger than the panel, so
        // it sits in a clipping wrapper: pinned top-left, with the right and bottom edges free to give
        // way. That also keeps it from forcing the window's size in the middle of an animation.
        let wrapper = NSView()
        wrapper.wantsLayer = true
        wrapper.layer?.masksToBounds = true
        wrapper.addSubview(stack)
        let trailing = stack.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor)
        let bottom = stack.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor)
        trailing.priority = NSLayoutConstraint.Priority(490)   // below .windowSizeStayPut (500): can't resize the window
        bottom.priority = NSLayoutConstraint.Priority(490)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor),
            stack.topAnchor.constraint(equalTo: wrapper.topAnchor),
            trailing, bottom,
        ])
        let (background, radius) = makeBackground(around: wrapper)
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wrapper.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            wrapper.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            wrapper.topAnchor.constraint(equalTo: background.topAnchor),
            wrapper.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])

        host.cornerRadius = radius
        background.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(background)
        let m = PanelHostView.margin
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: m),
            background.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -m),
            background.topAnchor.constraint(equalTo: host.topAnchor, constant: m),
            background.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -m),
        ])
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false   // PanelHostView draws the shadow, so it moves with the animations
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

    // Clear Liquid Glass on macOS 26+ (with an adjustable veil so text stays readable), the frosted
    // menu material on older systems. Returns the view and its corner radius.
    func makeBackground(around content: NSView) -> (NSView, CGFloat) {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .clear
            glass.cornerRadius = 28
            glassView = glass
            applyGlassOpacity()   // the veil over the glass, from the Background Opacity preference
            if glass.responds(to: NSSelectorFromString("setEffectIsInteractive:")) {
                glass.setValue(true, forKey: "effectIsInteractive")   // macOS 27: the glass reacts to the pointer
            }
            glass.contentView = content
            return (glass, 28)
        }
        #endif
        let frosted = NSVisualEffectView()
        frosted.material = .menu
        frosted.state = .active
        frosted.maskImage = roundedMask(radius: 14)
        frosted.addSubview(content)
        return (frosted, 14)
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

    // Opens right under the menu bar, growing out of the icon with a soft spring. Click outside
    // it, press Esc or click the icon again to close it.
    @objc func togglePanel() {
        if panelOpen { closePanel(); return }
        guard let button = statusItem.button, let window = button.window else { return }
        let midClose = panel.isVisible   // still fading out from the last close
        panelOpen = true
        resizeTimer?.invalidate()        // a leftover resize must not move the freshly placed panel
        refresh()
        quitRow.setHighlighted(false, animated: false)
        prefsRow.setHighlighted(false, animated: false)
        setPreferencesExpanded(false, animated: false)   // Preferences starts collapsed each time
        let size = host.fittingSize
        let m = PanelHostView.margin
        let icon = window.convertToScreen(button.convert(button.bounds, to: nil))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? icon
        let glassLeft = min(icon.minX, visible.maxX - (size.width - 2 * m) - 6)
        let glassTop = min(icon.minY, visible.maxY) - 2
        panel.setFrame(NSRect(x: glassLeft - m, y: glassTop + m - size.height, width: size.width, height: size.height),
                       display: false)
        host.layoutSubtreeIfNeeded()
        openPivot = CGPoint(x: icon.midX - panel.frame.minX, y: size.height - m)
        animateOpen(continuing: midClose)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            guard let self = self else { return }
            // a click on the icon itself toggles the panel through togglePanel() instead
            if let iconWindow = self.statusItem.button?.window, iconWindow.frame.contains(NSEvent.mouseLocation) { return }
            self.closePanel()
        }
    }

    // Grows out of the icon: scale 86% -> 100% on a spring (Animation Bounce/Speed), fading in quickly.
    func animateOpen(continuing midClose: Bool) {
        guard let layer = host.layer else { return }
        let fromTransform = midClose ? (layer.presentation()?.transform ?? CATransform3DIdentity)
                                     : scaleTransform(0.86, around: openPivot, of: layer, size: host.bounds.size)
        let fromOpacity = midClose ? (layer.presentation()?.opacity ?? 1) : 0
        layer.removeAllAnimations()
        let grow = makeSpring()
        grow.fromValue = NSValue(caTransform3D: fromTransform)
        grow.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = fromOpacity
        fade.toValue = 1
        fade.duration = 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(grow, forKey: "grow")
        layer.add(fade, forKey: "fade")
    }

    // Shrinks back toward the icon while fading out, then hides the window.
    func closePanel() {
        guard panelOpen else { return }
        panelOpen = false
        statusItem.button?.highlight(false)
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
        guard let layer = host.layer else { panel.orderOut(nil); return }
        let current = layer.presentation()
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = NSValue(caTransform3D: current?.transform ?? CATransform3DIdentity)
        shrink.toValue = NSValue(caTransform3D: scaleTransform(0.94, around: openPivot, of: layer, size: host.bounds.size))
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = current?.opacity ?? 1
        fade.toValue = 0
        for animation in [shrink, fade] {
            animation.duration = closeDuration
            animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.9, 0.6)
            animation.fillMode = .forwards
            animation.isRemovedOnCompletion = false
        }
        layer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self = self, !self.panelOpen else { return }   // reopened in the meantime
            self.panel.orderOut(nil)
            layer.removeAllAnimations()
        }
        layer.add(shrink, forKey: "shrink")
        layer.add(fade, forKey: "fade")
        CATransaction.commit()
    }

    // Resizes the panel smoothly with its top edge pinned under the menu bar. `step` gets the eased
    // progress (0...1) on every frame, so the content changes in lockstep with the window.
    var resizeTimer: Timer?
    func animatePanel(to size: NSSize, step: @escaping (CGFloat) -> Void = { _ in }) {
        resizeTimer?.invalidate()
        let from = panel.frame
        let duration = resizeDuration
        let start = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            let t = min(1, (CACurrentMediaTime() - start) / duration)
            let eased = CGFloat(1 - pow(1 - t, 3))   // ease-out: quick start, soft landing
            step(eased)
            let w = from.width + (size.width - from.width) * eased
            let h = from.height + (size.height - from.height) * eased
            self.panel.setFrame(NSRect(x: from.minX, y: from.maxY - h, width: w, height: h), display: true)
            if t >= 1 { timer.invalidate(); self.resizeTimer = nil }
        }
        RunLoop.main.add(timer, forMode: .common)
        resizeTimer = timer
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

    func applyDescriptions(animated: Bool) {
        let subtitles = [awakeItem, fnItem, nightItem].map { $0.subtitleLabel }
        subtitles.forEach { $0.isHidden = !showDescriptions }
        guard animated else { return }
        let showing = showDescriptions
        if showing { subtitles.forEach { $0.alphaValue = 0 } }
        animatePanel(to: host.fittingSize) { progress in
            if showing { subtitles.forEach { $0.alphaValue = progress } }
        }
    }

    @objc func descriptionsSwitched(_ sender: NSSwitch) {
        showDescriptions = sender.state == .on
        applyDescriptions(animated: true)
    }

    // The preference rows sit in a clipping "drawer" whose height slides between 0 and their full height.
    func setPreferencesExpanded(_ expanded: Bool, animated: Bool) {
        prefsRow.setSymbol(expanded ? "chevron.down" : "chevron.right")
        let height = expanded ? prefsContent.fittingSize.height : 0
        guard animated else {
            prefsClipHeight.constant = height
            prefsContent.alphaValue = expanded ? 1 : 0
            return
        }
        let fit = host.fittingSize
        let from = prefsClipHeight.constant
        let target = NSSize(width: fit.width, height: fit.height + height - from)
        animatePanel(to: target) { progress in
            self.prefsClipHeight.constant = from + (height - from) * progress
            self.prefsContent.alphaValue = expanded ? progress : 1 - progress
        }
    }

    func togglePreferences() {
        setPreferencesExpanded(prefsClipHeight.constant == 0, animated: true)
    }

    // MARK: Look and feel preferences (saved as soon as they change)
    func storedValue(_ key: String, default value: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? value
    }
    var glassOpacity: Double {   // 0 = pure clear glass ... 1 = nearly solid
        get { storedValue("BackgroundOpacity", default: 0.25) }
        set { UserDefaults.standard.set(newValue, forKey: "BackgroundOpacity") }
    }
    var bounce: Double {         // 0 = no bounce ... 1 = springy
        get { storedValue("AnimationBounce", default: 0.7) }
        set { UserDefaults.standard.set(newValue, forKey: "AnimationBounce") }
    }
    var speed: Double {          // 0 = relaxed ... 1 = snappy
        get { storedValue("AnimationSpeed", default: 0.45) }
        set { UserDefaults.standard.set(newValue, forKey: "AnimationSpeed") }
    }
    var closeDuration: Double { 0.26 - 0.14 * speed }
    var resizeDuration: Double { 0.42 - 0.22 * speed }

    var liquidGlassAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    // The opening spring: Speed sets how quickly it moves, Bounce how far it overshoots.
    func makeSpring() -> CASpringAnimation {
        let spring = CASpringAnimation(keyPath: "transform")
        spring.mass = 1
        spring.stiffness = CGFloat(120 + 480 * speed)
        spring.damping = CGFloat(1.0 - 0.6 * bounce) * 2 * sqrt(spring.stiffness)   // damping ratio 1.0 ... 0.4
        spring.duration = spring.settlingDuration
        return spring
    }

    func applyGlassOpacity() {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), let glass = glassView as? NSGlassEffectView {
            let veil = CGFloat(glassOpacity) * 0.8
            glass.tintColor = NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor.black.withAlphaComponent(veil) : NSColor.white.withAlphaComponent(veil)
            }
        }
        #endif
    }

    @objc func opacityChanged(_ sender: NSSlider) {   // live while dragging
        glassOpacity = sender.doubleValue
        applyGlassOpacity()
    }

    // Saves Bounce or Speed, then gives the panel a little bounce so the new feel is easy to judge.
    @objc func feelChanged(_ sender: NSSlider) {
        if sender === bounceSlider { bounce = sender.doubleValue } else { speed = sender.doubleValue }
        guard let layer = host.layer else { return }
        let pulse = makeSpring()
        pulse.fromValue = NSValue(caTransform3D: scaleTransform(0.94, around: openPivot, of: layer, size: host.bounds.size))
        pulse.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        layer.add(pulse, forKey: "pulse")
    }

    func setUpSlider(_ slider: NSSlider, value: Double, continuous: Bool, action: Selector) {
        slider.minValue = 0
        slider.maxValue = 1
        slider.doubleValue = value
        slider.isContinuous = continuous
        slider.controlSize = .small
        slider.target = self
        slider.action = action
        slider.widthAnchor.constraint(equalToConstant: 110).isActive = true
    }

    func prefRow(_ title: String, _ control: NSView) -> NSStackView {   // label left, control right
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        let row = NSStackView(views: [label, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .equalSpacing
        row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        row.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return row
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
