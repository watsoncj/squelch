import AppKit
import Security
import os

/// Self-updater backed by the GitHub Releases the release script already
/// publishes (Developer-ID signed, notarized zips). Checks quietly in the
/// background, downloads and verifies without interrupting anything, and
/// only then surfaces a "restart to update" chip — the swap happens when
/// the user clicks it, never on its own.
///
/// Trust model: the new bundle must satisfy a designated requirement
/// pinned to the *running* app's Team ID. Ad-hoc dev builds (make_app.sh)
/// have no Team ID and never auto-install; a manual check there just
/// offers the releases page.
///
/// Automatic checks and downloads stay off constrained (Low Data Mode)
/// and expensive (hotspot) networks — portable ops on a phone tether
/// shouldn't pay for a background zip. A manual check is explicit
/// consent and goes through regardless.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Phase: Equatable {
        case idle
        case checking
        case downloading(String) // version being fetched/verified
        case ready(String)       // staged + signature-verified; restart installs
        case installing
    }

    @Published private(set) var phase: Phase = .idle

    /// The verified, staged bundle (set exactly when phase is .ready).
    private var stagedApp: URL?
    private var timer: Timer?
    private var inFlight: Task<Void, Never>?

    nonisolated static let repo = "watsoncj/squelch"
    nonisolated static let releasesPage = URL(string: "https://github.com/watsoncj/squelch/releases/latest")!
    nonisolated private static let log = Logger(subsystem: "com.watsoncj.squelch", category: "updater")

    /// AppModel builds its model objects outside the main actor.
    nonisolated init() {}

    var readyVersion: String? {
        if case .ready(let version) = phase { return version }
        return nil
    }

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    // MARK: - Scheduling

    /// First check shortly after launch (don't compete with audio/CAT
    /// startup), then periodically — decode sessions run for days, so a
    /// launch-only check would go stale.
    func startAutomaticChecks() {
        guard Self.canAutoInstall else {
            Self.log.info("auto-update disabled (dev build, translocated, or app dir not writable)")
            return
        }
        // Leftover staging from a previous update cycle
        try? FileManager.default.removeItem(at: Self.stagingRoot)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.check(manual: false)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(manual: false) }
        }
    }

    func checkNow() { check(manual: true) }

    private func check(manual: Bool) {
        // Checked at fire time, not at scheduling, so the Settings toggle
        // takes effect immediately in both directions without a relaunch.
        if !manual, !UserDefaults.standard.bool(forKey: SettingsKeys.autoUpdateCheck) { return }
        switch phase {
        case .ready(let version):
            if manual { offerRestart(version: version) }
            return
        case .checking, .installing:
            return
        case .downloading(let version):
            if manual {
                alert(title: "Downloading Squelch \(version)",
                      message: "A restart chip appears in the toolbar once it's downloaded and verified.")
            }
            return
        case .idle:
            break
        }

        phase = .checking
        inFlight = Task {
            do {
                let release = try await Self.fetchLatestRelease(userInitiated: manual)
                let remote = Self.normalized(release.tagName)
                guard Self.isNewer(remote, than: Self.currentVersion) else {
                    phase = .idle
                    if manual {
                        alert(title: "You're up to date",
                              message: "Squelch \(Self.currentVersion) is the latest version.")
                    }
                    return
                }
                guard Self.canAutoInstall else {
                    // Manual check from a dev build: point at the page instead
                    phase = .idle
                    if manual { offerReleasesPage(version: remote) }
                    return
                }
                guard let asset = Self.zipAsset(in: release) else {
                    throw UpdateError.noAsset
                }
                phase = .downloading(remote)
                Self.log.info("downloading \(remote) from \(asset.browserDownloadURL)")
                let app = try await Self.downloadAndStage(asset: asset, version: remote, userInitiated: manual)
                guard let team = Self.teamIdentifier(ofCodeAt: Bundle.main.bundleURL),
                      Self.validate(appAt: app, teamID: team) else {
                    try? FileManager.default.removeItem(at: Self.stagingRoot)
                    throw UpdateError.signatureMismatch
                }
                stagedApp = app
                phase = .ready(remote)
                Self.log.info("\(remote) staged and verified at \(app.path)")
            } catch {
                Self.log.error("update check failed: \(error.localizedDescription)")
                phase = .idle
                if manual {
                    alert(title: "Couldn't check for updates", message: error.localizedDescription)
                }
            }
        }
    }

    // MARK: - Install

    /// Swap the staged bundle into the running app's place and relaunch.
    /// The old bundle goes to the Trash (the running process keeps its
    /// mapped binary alive regardless). On any failure the original is
    /// restored and we stay on the current version.
    func installAndRelaunch() {
        guard case .ready(let version) = phase, let staged = stagedApp else { return }
        phase = .installing
        let fm = FileManager.default
        let dest = Bundle.main.bundleURL
        var oldInTrash: NSURL?
        do {
            try fm.trashItem(at: dest, resultingItemURL: &oldInTrash)
            do {
                try fm.moveItem(at: staged, to: dest)
            } catch {
                // Staging on another volume — copy instead
                do {
                    try fm.copyItem(at: staged, to: dest)
                } catch {
                    try? fm.removeItem(at: dest)
                    if let old = oldInTrash as URL? { try? fm.moveItem(at: old, to: dest) }
                    throw error
                }
            }
        } catch {
            Self.log.error("install failed: \(error.localizedDescription)")
            phase = .ready(version)
            alert(title: "Couldn't install the update", message: error.localizedDescription)
            return
        }
        try? fm.removeItem(at: Self.stagingRoot)
        relaunch(appAt: dest)
    }

    /// Terminate and reopen: a detached shell waits for this pid to exit,
    /// then opens the (now updated) bundle.
    private func relaunch(appAt url: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.1; done; /usr/bin/open \"\(url.path)\""
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script]
        try? helper.run()
        NSApp.terminate(nil)
    }

    // MARK: - GitHub release feed

    struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum UpdateError: LocalizedError {
        case badResponse
        case noAsset
        case noAppInZip
        case signatureMismatch
        case toolFailed(String)

        var errorDescription: String? {
            switch self {
            case .badResponse: return "GitHub's release feed returned an unexpected response."
            case .noAsset: return "The latest release has no app zip attached."
            case .noAppInZip: return "The downloaded zip didn't contain an app bundle."
            case .signatureMismatch: return "The downloaded app failed code-signature verification — not installing it."
            case .toolFailed(let detail): return detail
            }
        }
    }

    /// Only user-initiated traffic may use constrained (Low Data Mode) or
    /// expensive (hotspot) networks; on those, an automatic request fails
    /// like an offline one and the 6-hour timer simply tries again later.
    nonisolated static func request(for url: URL, userInitiated: Bool) -> URLRequest {
        var request = URLRequest(url: url)
        request.allowsConstrainedNetworkAccess = userInitiated
        request.allowsExpensiveNetworkAccess = userInitiated
        return request
    }

    nonisolated static func fetchLatestRelease(userInitiated: Bool) async throws -> Release {
        var request = Self.request(for: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!,
                                   userInitiated: userInitiated)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.badResponse
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// "v1.9.0" → "1.9.0"
    nonisolated static func normalized(_ tag: String) -> String {
        var tag = tag.trimmingCharacters(in: .whitespaces)
        while let first = tag.first, first == "v" || first == "V" {
            tag.removeFirst()
        }
        return tag
    }

    /// Numeric dotted-version compare — "1.10.0" beats "1.9.0" (string
    /// compare wouldn't). Missing components count as 0.
    nonisolated static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            normalized(s).split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0
            let b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The app zip among the release assets — the release script names it
    /// Squelch-<version>.zip; prefer that shape over stray zips (dSYMs…).
    nonisolated static func zipAsset(in release: Release) -> Asset? {
        let zips = release.assets.filter { $0.name.hasSuffix(".zip") }
        return zips.first { $0.name.hasPrefix("Squelch-") } ?? zips.first
    }

    // MARK: - Staging

    nonisolated private static var stagingRoot: URL {
        squelchSupportDirectory().appendingPathComponent("Updates", isDirectory: true)
    }

    /// Download the zip, extract, and return the contained .app. Quarantine
    /// is stripped — we do our own (stricter) verification against the
    /// running app's Team ID, and the payload is notarized anyway.
    nonisolated static func downloadAndStage(asset: Asset, version: String, userInitiated: Bool) async throws -> URL {
        let (zip, _) = try await URLSession.shared.download(
            for: request(for: asset.browserDownloadURL, userInitiated: userInitiated))
        let fm = FileManager.default
        let dir = stagingRoot.appendingPathComponent(version, isDirectory: true)
        try? fm.removeItem(at: stagingRoot)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-xk", zip.path, dir.path])
        try? fm.removeItem(at: zip)
        guard let app = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noAppInZip
        }
        try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    nonisolated private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.toolFailed("\(URL(fileURLWithPath: tool).lastPathComponent) exited with status \(process.terminationStatus)")
        }
    }

    // MARK: - Code-signature trust

    /// Auto-install requires: a real (team-signed) build — dev builds are
    /// ad-hoc; not Gatekeeper-translocated; and a writable app directory.
    nonisolated static var canAutoInstall: Bool {
        guard teamIdentifier(ofCodeAt: Bundle.main.bundleURL) != nil else { return false }
        let url = Bundle.main.bundleURL
        guard !url.path.contains("/AppTranslocation/") else { return false }
        return FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path)
    }

    nonisolated static func teamIdentifier(ofCodeAt url: URL) -> String? {
        var codeQ: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &codeQ) == errSecSuccess,
              let code = codeQ else { return nil }
        var infoQ: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoQ) == errSecSuccess,
              let info = infoQ as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Valid signature AND signed by `teamID` under Apple's root — the
    /// designated-requirement check that makes swapping the bundle safe.
    nonisolated static func validate(appAt url: URL, teamID: String) -> Bool {
        var codeQ: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &codeQ) == errSecSuccess,
              let code = codeQ else { return false }
        let requirementString = "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\"" as CFString
        var requirementQ: SecRequirement?
        guard SecRequirementCreateWithString(requirementString, [], &requirementQ) == errSecSuccess,
              let requirement = requirementQ else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    // MARK: - Manual-check feedback

    private func offerRestart(version: String) {
        let alert = NSAlert()
        alert.messageText = "Squelch \(version) is ready"
        alert.informativeText = "It's downloaded and verified. Restart now to start using it?"
        alert.addButton(withTitle: "Restart Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            installAndRelaunch()
        }
    }

    private func offerReleasesPage(version: String) {
        let alert = NSAlert()
        alert.messageText = "Squelch \(version) is available"
        alert.informativeText = "This development build can't update itself — grab the release from GitHub."
        alert.addButton(withTitle: "Open Releases Page")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.releasesPage)
        }
    }

    private func alert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
