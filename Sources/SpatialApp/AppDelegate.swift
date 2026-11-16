import AppKit

/// Remembered choices.
struct Settings {
    private static let d = UserDefaults.standard

    static var enabled: Bool {
        get { d.object(forKey: "enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "enabled") }
    }
    static var engine: EngineKind {
        get { EngineKind(rawValue: d.string(forKey: "engine") ?? "") ?? .system }
        set { d.set(newValue.rawValue, forKey: "engine") }
    }
    static var headTracking: HeadTracking {
        get { HeadTracking(rawValue: d.string(forKey: "headTracking") ?? "") ?? .builtIn }
        set { d.set(newValue.rawValue, forKey: "headTracking") }
    }
    /// The menu bar icon is hidden; opening Spatial again brings it back.
    static var iconHidden: Bool {
        get { d.bool(forKey: "iconHidden") }
        set { d.set(newValue, forKey: "iconHidden") }
    }
}

/// A menu bar item: Spatial Audio on/off, engine, head tracking.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var item: NSStatusItem!
    private let router = Router(engine: Settings.engine)
    private let motion = HeadMotion()
    private var silentSeconds = 0
    private var meter: Timer?
    private var monitor: OutputMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The null test runs inside a launched app: macOS only grants audio
        // capture to a properly launched app, otherwise the tap hears silence.
        if args.contains("--transparency") {
            Thread.detachNewThread {
                let ok = runTransparencyTest()
                exit(ok ? 0 : 1)
            }
            return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = SpatialIcon.menuBarImage()
        item.isVisible = !Settings.iconHidden
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        router.onChange = { [weak self] in self?.refreshIcon() }
        router.headTracking = Settings.headTracking
        router.setEnabled(Settings.enabled)
        updateMotion()

        // Once a second: is sound actually arriving while Spotify plays?
        meter = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        refreshIcon()
    }

    /// Opening Spatial while it runs (Spotlight, Finder, `open`) shows the
    /// menu bar icon again if it was hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Settings.iconHidden {
            Settings.iconHidden = false
            item?.isVisible = true
        }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        router.setEnabled(false)   // hand Spotify back to the speakers
    }

    private func tick() {
        // `defaults write local.spatial captureTo <dir>` (+ optional
        // captureSeconds) records Spotify in vs this app out, live.
        let d = UserDefaults.standard
        d.synchronize()
        if let dir = d.string(forKey: "captureTo") {
            d.removeObject(forKey: "captureTo")
            let secs = d.double(forKey: "captureSeconds") > 0 ? d.double(forKey: "captureSeconds") : 30
            let ok = router.startCapture(dir: dir, seconds: secs)
            FileHandle.standardError.write("capture \(ok ? "started" : "skipped (not running)") -> \(dir)\n".data(using: .utf8)!)
        }
        let peak = router.takePeak()
        if case .running = router.state, router.targetIsPlaying, peak == 0 {
            silentSeconds += 1
        } else {
            silentSeconds = 0
        }
        if args.contains("--log") {
            if monitor == nil, !args.contains("--no-monitor"), case .running = router.state {
                let m = OutputMonitor()
                do { try m.start(); monitor = m } catch {
                    FileHandle.standardError.write("monitor: \(error)\n".data(using: .utf8)!)
                }
            }
            let heard = monitor.map { String(format: " OUT %.4f", $0.takePeak()) } ?? ""
            let ahead = String(format: "%.0f ms", router.player.queuedAhead * 1000)
            let failure = router.player.failed.map { " player failed: \($0)" } ?? ""
            FileHandle.standardError.write("state \(router.state) peak \(peak) queued \(ahead)\(heard)\(failure)\n".data(using: .utf8)!)
        }
    }

    private func refreshIcon() {
        if case .running = router.state {
            item.button?.appearsDisabled = false
        } else {
            item.button?.appearsDisabled = true
        }
    }

    /// CoreMotion drives the listener unless the mixer is tracking by itself.
    private func updateMotion() {
        let wants = Settings.enabled && Settings.engine.rendersItself && Settings.headTracking == .motion
        if wants {
            motion.start { [weak self] pose in self?.router.engine.setHeadPose(pose) }
        } else {
            motion.stop()
        }
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // The master switch. Off hands Spotify straight back to your
        // headphones: no reroute, no extra delay, exactly as without Spatial.
        let toggle = NSMenuItem(title: "Spatial Audio", action: #selector(toggleEnabled), keyEquivalent: "s")
        toggle.state = Settings.enabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(disabled(statusLine()))
        if let personal = router.engine.usingPersonalProfile, case .running(_, _, .headphones) = router.state {
            menu.addItem(disabled(personal ? "Using your personalized profile" : "Using the generic profile"))
        }
        if silentSeconds >= 3 {
            menu.addItem(disabled("No sound arriving: allow Spatial under"))
            menu.addItem(disabled("Privacy & Security › Screen & System Audio Recording"))
        }
        if Settings.enabled, !Settings.engine.rendersItself {
            menu.addItem(disabled("Fixed or Head Tracked: Control Center"))
            menu.addItem(disabled("› your AirPods › Spatial Audio"))
        }
        menu.addItem(.separator())

        let head = NSMenuItem(title: "Head Tracking", action: nil, keyEquivalent: "")
        let headMenu = NSMenu()
        for mode in HeadTracking.allCases {
            let m = NSMenuItem(title: mode.title, action: #selector(pickHead(_:)), keyEquivalent: "")
            m.representedObject = mode.rawValue
            m.state = Settings.headTracking == mode ? .on : .off
            m.target = self
            headMenu.addItem(m)
        }
        headMenu.addItem(.separator())
        let recenter = NSMenuItem(title: "Recenter", action: #selector(recenter), keyEquivalent: "r")
        recenter.target = self
        recenter.isEnabled = motion.isRunning
        headMenu.addItem(recenter)
        head.submenu = headMenu
        if Settings.engine.rendersItself { menu.addItem(head) }

        let engine = NSMenuItem(title: "Engine", action: nil, keyEquivalent: "")
        let engineMenu = NSMenu()
        for kind in EngineKind.allCases {
            let m = NSMenuItem(title: kind.title, action: #selector(pickEngine(_:)), keyEquivalent: "")
            m.representedObject = kind.rawValue
            m.state = Settings.engine == kind ? .on : .off
            m.target = self
            engineMenu.addItem(m)
        }
        engine.submenu = engineMenu
        menu.addItem(engine)

        menu.addItem(.separator())
        let hide = NSMenuItem(title: "Hide Menu Bar Icon", action: #selector(hideIcon), keyEquivalent: "")
        hide.target = self
        hide.toolTip = "Spatial keeps running. Open Spatial again to bring the icon back."
        menu.addItem(hide)
        menu.addItem(disabled("Open Spatial again to bring it back"))
        menu.addItem(NSMenuItem(title: "Quit Spatial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func statusLine() -> String {
        switch router.state {
        case .off: return "Off: Spotify plays as usual"
        case .waiting: return "Waiting for Spotify"
        case let .running(device, rate, _): return "Spotify → \(device) · \(Int(rate / 1000)) kHz"
        case let .failed(why): return "Couldn't start: \(why)"
        }
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        m.isEnabled = false
        return m
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        router.setEnabled(Settings.enabled)
        updateMotion()
    }

    @objc private func pickHead(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = HeadTracking(rawValue: raw) else { return }
        Settings.headTracking = mode
        router.headTracking = mode
        updateMotion()
    }

    @objc private func recenter() { motion.recenter() }

    @objc private func hideIcon() {
        Settings.iconHidden = true
        item.isVisible = false
    }

    @objc private func pickEngine(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = EngineKind(rawValue: raw) else { return }
        Settings.engine = kind
        router.setEngine(kind)
        router.headTracking = Settings.headTracking
        updateMotion()
    }
}
