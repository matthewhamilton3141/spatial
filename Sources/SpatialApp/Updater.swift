import AppKit
import Security

/// Keeps Spatial current. Once a day it asks GitHub for the latest release;
/// if that's newer, it downloads and checks it in the background, then swaps
/// it in and relaunches while Spotify isn't playing (or straight away from
/// the menu). Only a copy in an Applications folder replaces itself; anywhere
/// else (a dev build, a copy run from Downloads) the menu just offers it.
///
/// `defaults write local.spatial autoUpdate -bool false` turns it all off.
/// Test hooks: `updateFeed` (a URL serving GitHub's latest-release JSON),
/// `updateAnywhere` (install outside Applications), `updateIdleSeconds`.
final class Updater {
    enum State: Equatable {
        case idle
        case checking
        case downloading(version: String)
        case ready(version: String, app: URL)    // downloaded and checked
        case installing(version: String)
        case failed(String)
    }

    private(set) var state = State.idle {
        didSet {
            if state != oldValue { onChange?(); log("update: \(state)") }
        }
    }
    var onChange: (() -> Void)?

    static let repo = "matthewhamilton3141/spatial"
    static let releasesPage = URL(string: "https://github.com/\(repo)/releases/latest")!
    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    private let defaults = UserDefaults.standard
    var enabled: Bool { defaults.object(forKey: "autoUpdate") as? Bool ?? true }
    /// Spotify must have been quiet this long before an update installs by itself.
    var idleSecondsBeforeInstall: Int {
        let v = defaults.integer(forKey: "updateIdleSeconds")
        return v > 0 ? v : 120
    }
    private var customFeed: URL? { defaults.string(forKey: "updateFeed").flatMap(URL.init(string:)) }
    private var feed: URL { customFeed ?? URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")! }
    private var lastCheck: Date {
        get { defaults.object(forKey: "lastUpdateCheck") as? Date ?? .distantPast }
        set { defaults.set(newValue, forKey: "lastUpdateCheck") }
    }
    private let launchedAt = Date()

    // MARK: Checking

    /// Called once a second; checks when a day has passed since the last one
    /// (and never in the first half minute after launch).
    func checkIfDue() {
        guard enabled, Date().timeIntervalSince(launchedAt) > 30 else { return }
        switch state {
        case .idle, .failed: break
        default: return
        }
        guard Date().timeIntervalSince(lastCheck) > 24 * 3600 else { return }
        check()
    }

    func check(completion: ((String) -> Void)? = nil) {
        state = .checking
        lastCheck = Date()
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                let result = self.read(data: data, response: response, error: error)
                completion?(result)
            }
        }.resume()
    }

    /// Main thread. Returns a one-line summary (for `--check-update`).
    private func read(data: Data?, response: URLResponse?, error: Error?) -> String {
        if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
            return fail("GitHub answered \(status)")
        }
        guard let data,
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { $0["name"] as? String == "Spatial.zip" }),
              let link = asset["browser_download_url"] as? String,
              let url = URL(string: link) else {
            return fail(error.map { "couldn't check: \($0.localizedDescription)" } ?? "couldn't read the latest release")
        }
        let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard Self.isNewer(latest, than: current) else {
            state = .idle
            return "up to date (\(current), latest \(latest))"
        }
        // The real feed only ever points at this repo's own release files.
        if customFeed == nil, !link.hasPrefix("https://github.com/\(Self.repo)/releases/download/") {
            return fail("unexpected download address \(link)")
        }
        download(version: latest, from: url)
        return "\(latest) is newer than \(current): downloading"
    }

    private func fail(_ why: String) -> String {
        state = .failed(why)
        lastCheck = Date().addingTimeInterval(-23 * 3600)   // try again in an hour
        return why
    }

    // MARK: Downloading and checking the new copy

    private func download(version: String, from url: URL) {
        state = .downloading(version: version)
        URLSession.shared.downloadTask(with: url) { file, response, error in
            // The downloaded file is deleted when this returns: unpack it now.
            var outcome: Result<URL, Error>
            if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                outcome = .failure(UpdateError("download answered \(status)"))
            } else if let file {
                outcome = Result { try self.unpackAndVerify(zip: file, version: version) }
            } else {
                outcome = .failure(UpdateError(error?.localizedDescription ?? "download failed"))
            }
            DispatchQueue.main.async {
                switch outcome {
                case let .success(app): self.state = .ready(version: version, app: app)
                case let .failure(why): _ = self.fail("\(why)")
                }
            }
        }.resume()
    }

    /// Background. Unzips the download and checks it's really a newer
    /// Spatial: same bundle ID, the advertised version, runs on this macOS,
    /// and an intact code signature.
    private func unpackAndVerify(zip: URL, version: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("spatial-update-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let archive = dir.appendingPathComponent("Spatial.zip")
        try fm.moveItem(at: zip, to: archive)
        try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, dir.appendingPathComponent("unpacked").path])
        let app = dir.appendingPathComponent("unpacked/Spatial.app")
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] else {
            throw UpdateError("the download has no Spatial.app")
        }
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier else {
            throw UpdateError("the download holds a different app (\(info["CFBundleIdentifier"] ?? "?"))")
        }
        guard info["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("the download is version \(info["CFBundleShortVersionString"] ?? "?"), expected \(version)")
        }
        if let minimum = info["LSMinimumSystemVersion"] as? String, !Self.runsOnThisMac(minimum) {
            throw UpdateError("\(version) needs macOS \(minimum)")
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError("couldn't read the new copy's signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidityWithErrors(code, flags, nil, nil) == errSecSuccess else {
            throw UpdateError("the new copy fails its code-signature check")
        }
        try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    // MARK: Installing

    /// Whether this copy can replace itself: it sits in an Applications
    /// folder this user can write to (not translocated, not a dev build).
    var canInstallInPlace: Bool {
        let path = Bundle.main.bundlePath
        let fm = FileManager.default
        let inApplications = path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
        return (inApplications || defaults.bool(forKey: "updateAnywhere"))
            && !path.contains("/AppTranslocation/")
            && fm.isWritableFile(atPath: (path as NSString).deletingLastPathComponent)
            && fm.isWritableFile(atPath: path)
    }

    /// Swaps the checked copy in for this one and opens it. The new copy's
    /// one-at-a-time rule then quits this one, which hands Spotify back on
    /// the way out. Main thread.
    func install() {
        guard case let .ready(version, staged) = state, canInstallInPlace else { return }
        let dest = Bundle.main.bundleURL
        state = .installing(version: version)
        DispatchQueue.global(qos: .utility).async {
            do {
                let fm = FileManager.default
                // Next to the app, on its volume, so the swap is one rename.
                let near = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: dest, create: true)
                defer { try? fm.removeItem(at: near) }
                let incoming = near.appendingPathComponent("Spatial.app")
                try Self.run("/usr/bin/ditto", [staged.path, incoming.path])
                _ = try fm.replaceItemAt(dest, withItemAt: incoming)
                try? fm.removeItem(at: staged.deletingLastPathComponent().deletingLastPathComponent())
                DispatchQueue.main.async { self.relaunch(version) }
            } catch {
                DispatchQueue.main.async { _ = self.fail("couldn't replace Spatial: \(error.localizedDescription)") }
            }
        }
    }

    private func relaunch(_ version: String) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.activates = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    _ = self.fail("installed \(version) but couldn't open it: \(error.localizedDescription)")
                    return
                }
                // The new copy quits this one; if it somehow doesn't, go anyway
                // rather than leave two copies each playing Spotify.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { NSApp.terminate(nil) }
            }
        }
    }

    // MARK: Helpers

    /// Compares dotted version numbers: 1.0.10 is newer than 1.0.9.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    static func runsOnThisMac(_ minimum: String) -> Bool {
        let parts = minimum.split(separator: ".").map { Int($0) ?? 0 }
        let version = OperatingSystemVersion(majorVersion: parts.count > 0 ? parts[0] : 0,
                                             minorVersion: parts.count > 1 ? parts[1] : 0,
                                             patchVersion: parts.count > 2 ? parts[2] : 0)
        return ProcessInfo.processInfo.isOperatingSystemAtLeast(version)
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError("\((tool as NSString).lastPathComponent) failed (\(process.terminationStatus))")
        }
    }

    private func log(_ line: String) {
        guard args.contains("--log") else { return }
        FileHandle.standardError.write("\(line)\n".data(using: .utf8)!)
    }
}

struct UpdateError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
