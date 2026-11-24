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

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var caffeinate: Process?
    let awakeItem = NSMenuItem(title: "Keep Display Awake (caffeinate -d)", action: #selector(toggleAwake), keyEquivalent: "")
    let fnItem = NSMenuItem(title: "F1–F12 as Standard Function Keys", action: #selector(toggleFn), keyEquivalent: "")

    let nightItem = NSMenuItem(title: "Night Mode (Night Shift + True Tone + Auto-Brightness)", action: #selector(toggleNight), keyEquivalent: "")

    func applicationDidFinishLaunching(_ n: Notification) {
        setupNight()
        let menu = NSMenu()
        menu.delegate = self
        awakeItem.target = self
        fnItem.target = self
        nightItem.target = self
        menu.addItem(awakeItem)
        menu.addItem(fnItem)
        menu.addItem(nightItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        menu.items.last?.target = self
        statusItem.menu = menu
        refresh()
    }

    func menuWillOpen(_ menu: NSMenu) { refresh() }

    func refresh() {
        let awake = caffeinate?.isRunning ?? false
        awakeItem.state = awake ? .on : .off
        fnItem.state = fnEnabled() ? .on : .off
        nightItem.state = nightAllOn() ? .on : .off
        let name = awake ? "cup.and.saucer.fill" : "cup.and.saucer"
        statusItem.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Quick Toggles")
    }

    // MARK: caffeinate
    @objc func toggleAwake() {
        if let p = caffeinate, p.isRunning {
            p.terminate()
            caffeinate = nil
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
            p.arguments = ["-d"]
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
