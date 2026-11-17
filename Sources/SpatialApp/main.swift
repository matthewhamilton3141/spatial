import AppKit

// Spatial              menu bar app: Spotify through Apple's spatial renderer
// Spatial --smoke      headless self-test of both engines, prints PASS or FAIL
// Spatial --probe      lists audio processes and the output device; no tap, no permission
// Spatial --transparency  (via `open --args`) null test of the system player, muted
// Spatial --log        (with the app) prints state and input level to stderr once a second

let args = CommandLine.arguments

if args.contains("--smoke") {
    exit(runSmokeTest() ? 0 : 1)
}

if args.contains("--probe") {
    runProbe()
    exit(0)
}

// Spatial --check-update   (run from inside the app bundle) asks GitHub for
// the latest release; if it's newer, downloads and checks it the way an
// update would, and reports. Installs nothing.
if args.contains("--check-update") {
    let updater = Updater()
    updater.onChange = {
        switch updater.state {
        case let .ready(version, app): print("ready: \(version) downloaded and verified at \(app.path)"); exit(0)
        case let .failed(why): print("failed: \(why)"); exit(1)
        default: break
        }
    }
    updater.check { result in
        print(result)
        if case .downloading = updater.state { return }
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
