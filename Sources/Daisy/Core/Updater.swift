import AppKit
import CryptoKit
import Foundation

/// Checks GitHub Releases for a newer build.
///
/// This is the only part of Daisy that touches the network, and it only ever
/// talks to GitHub. Nothing is installed without two independent checks: the
/// download must match the checksum published alongside the release, and the
/// app inside it must satisfy the running app's own code-signing requirement
/// (see `UpdateInstaller`). If either fails — or the app cannot replace itself
/// where it is installed — the verified image is revealed in Finder instead.
@MainActor
final class Updater {
    static let shared = Updater()

    private let repo = "ishanmalu/daisy"

    struct Release {
        let version: String
        let notes: String
        let pageURL: URL
        let dmgURL: URL?
        let checksumURL: URL?
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String)
        case downloading(Double)
        case installing
        case revealed(String)
        case failed(String)

        var message: String {
            switch self {
            case .idle: return ""
            case .checking: return "Checking…"
            case .upToDate: return "Daisy is up to date."
            case .available(let v): return "Daisy \(v) is available."
            case .downloading(let p): return "Downloading… \(Int(p * 100))%"
            case .installing: return "Installing — Daisy will restart."
            case .revealed: return "Downloaded and revealed in Finder."
            case .failed(let why): return why
            }
        }
    }

    private(set) var state: State = .idle {
        didSet { onChange?(state) }
    }
    /// Set by whoever is showing the state — the Settings window.
    var onChange: ((State) -> Void)?
    private(set) var release: Release?

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var automatic: Bool {
        get { UserDefaults.standard.bool(forKey: "update.auto") }
        set { UserDefaults.standard.set(newValue, forKey: "update.auto") }
    }

    var lastChecked: Date? {
        get { UserDefaults.standard.object(forKey: "update.lastChecked") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "update.lastChecked") }
    }

    /// Everything fetched or opened has to live on one of these. The release
    /// JSON is attacker-controlled if GitHub is ever compromised, so URLs taken
    /// from it are checked rather than trusted.
    nonisolated private static let allowedHosts: Set<String> = [
        "github.com", "www.github.com", "api.github.com",
        "objects.githubusercontent.com", "release-assets.githubusercontent.com",
    ]

    nonisolated static func isTrusted(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return allowedHosts.contains(host)
    }

    // MARK: checking

    func check() {
        guard state != .checking else { return }
        state = .checking
        Task {
            do {
                let found = try await fetchLatest()
                release = found
                lastChecked = Date()
                state = Self.isNewer(found.version, than: currentVersion)
                    ? .available(found.version) : .upToDate
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// At most once a day, and only if the user asked for it.
    func checkInBackgroundIfDue() {
        guard automatic else { return }
        if let last = lastChecked, Date().timeIntervalSince(last) < 86_400 { return }
        check()
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Daisy/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }
        if http.statusCode == 404 { throw Failure.noReleases }
        guard http.statusCode == 200 else { throw Failure.status(http.statusCode) }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)),
              Self.isTrusted(page)
        else { throw Failure.badResponse }

        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ test: (String) -> Bool) -> URL? {
            assets.first { test(($0["name"] as? String ?? "").lowercased()) }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
                .flatMap { Self.isTrusted($0) ? $0 : nil }
        }
        return Release(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            notes: (json["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            pageURL: page,
            dmgURL: asset { $0.hasSuffix(".dmg") },
            checksumURL: asset { $0.contains("sha256") }
        )
    }

    // MARK: downloading

    func downloadAndInstall() {
        guard let release, let dmgURL = release.dmgURL else { openReleasePage(); return }
        state = .downloading(0)

        Task {
            do {
                let (tempURL, response) = try await Self.download(dmgURL) { [weak self] p in
                    Task { @MainActor in
                        if case .downloading = self?.state { self?.state = .downloading(p) }
                    }
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw Failure.badResponse
                }
                // Hash off the main actor, streamed: a DMG is tens of MB and
                // reading it whole here froze the menu bar.
                let digest = try await Task.detached(priority: .userInitiated) {
                    try Self.sha256(of: tempURL)
                }.value

                // A release without a published checksum is refused rather than
                // trusted: it is the only thing standing between this download
                // and whatever a compromised CDN handed back.
                guard let checksumURL = release.checksumURL,
                      let expected = try await expectedChecksum(from: checksumURL,
                                                                named: dmgURL.lastPathComponent)
                else { throw Failure.checksumMissing }
                guard expected.caseInsensitiveCompare(digest) == .orderedSame else {
                    throw Failure.checksumMismatch
                }

                let staged = FileManager.default.temporaryDirectory
                    .appendingPathComponent(dmgURL.lastPathComponent)
                try? FileManager.default.removeItem(at: staged)
                try FileManager.default.moveItem(at: tempURL, to: staged)

                if UpdateInstaller.canInstallInPlace {
                    state = .installing
                    do {
                        try UpdateInstaller.install(from: staged)   // does not return
                    } catch {
                        // Anything that goes wrong leaves the working app alone,
                        // so fall back to handing the image over.
                        reveal(staged, named: dmgURL.lastPathComponent, note: error.localizedDescription)
                    }
                } else {
                    reveal(staged, named: dmgURL.lastPathComponent, note: nil)
                }
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    /// Put the verified image in Downloads and show it. Used whenever the app
    /// cannot replace itself — which includes every ad-hoc signed build, since
    /// those cannot prove a new copy came from the same hands as this one.
    private func reveal(_ source: URL, named name: String, note: String?) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let destination = downloads.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: destination)
        do { try FileManager.default.moveItem(at: source, to: destination) }
        catch { state = .failed(error.localizedDescription); return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
        state = .revealed(note ?? "Verified. Open it and drag Daisy to Applications.")
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// `URLSession.download(from:)` reports no progress, so the state sat at
    /// 0% for the whole download. Watch the task's own Progress instead.
    nonisolated private static func download(_ url: URL,
                                             progress: @escaping @Sendable (Double) -> Void) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            var watch: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                watch?.invalidate()
                guard let temp, let response else { cont.resume(throwing: error ?? Failure.badResponse); return }
                // The system deletes `temp` when this handler returns.
                let keep = FileManager.default.temporaryDirectory
                    .appendingPathComponent("daisy-dl-\(UUID().uuidString).dmg")
                do { try FileManager.default.moveItem(at: temp, to: keep); cont.resume(returning: (keep, response)) }
                catch { cont.resume(throwing: error) }
            }
            watch = task.progress.observe(\.fractionCompleted) { p, _ in progress(p.fractionCompleted) }
            task.resume()
        }
    }

    private func expectedChecksum(from url: URL, named dmg: String) async throws -> String? {
        let (data, _) = try await URLSession.shared.data(from: url)
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ").filter { !$0.isEmpty }
            guard parts.count >= 2 else { continue }
            if parts[1].hasSuffix(dmg) { return String(parts[0]) }
        }
        return nil
    }

    func openReleasePage() {
        let fallback = URL(string: "https://github.com/\(repo)/releases/latest")!
        let target = release?.pageURL ?? fallback
        NSWorkspace.shared.open(Self.isTrusted(target) ? target : fallback)
    }

    // MARK: version comparison

    /// Numeric and component-wise, so "0.10.0" is newer than "0.9.0".
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.split(whereSeparator: { $0 == "." || $0 == "-" })
                .compactMap { Int($0.prefix(while: \.isNumber)) }
        }
        let a = parts(candidate), b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    enum Failure: LocalizedError {
        case badResponse, noReleases, status(Int), checksumMissing, checksumMismatch

        var errorDescription: String? {
            switch self {
            case .badResponse: return "GitHub returned something unexpected."
            case .noReleases: return "No releases published yet."
            case .status(let c): return "GitHub returned HTTP \(c)."
            case .checksumMissing:
                return "That release publishes no checksum for the download, so it was refused."
            case .checksumMismatch:
                return "The download did not match its published checksum. It was discarded."
            }
        }
    }
}
