import AppKit
import Foundation
import Security

/// Replaces the running app with a newly downloaded one, then relaunches.
///
/// Replacing your own bundle from the network is a capability worth being
/// careful with, so the check that matters is not the checksum — that comes
/// from the same release over the same connection, and proves only that the
/// download arrived intact. The real control is the code signature: the new
/// bundle must satisfy the *running* app's own designated requirement, which
/// pins the signing certificate. Whoever swapped the download cannot produce a
/// bundle signed with that key, so a substituted app fails before anything is
/// moved.
///
/// Everything is staged first and the old bundle is kept until the new one is
/// in place, so a failure at any step leaves the working app where it was.
///
/// Note that an ad-hoc signed build can never satisfy this: its designated
/// requirement pins the code hash of that exact build, so every new version
/// fails the check by construction. That is the correct answer rather than a
/// limitation to work around — without a stable signing identity there is no
/// way to tell a genuine update from a substituted one — so those builds fall
/// back to downloading and revealing the image for the user to install.
enum UpdateInstaller {
    enum Failure: LocalizedError {
        case notWritable(String)
        case mountFailed
        case noAppInImage
        case signatureMismatch
        case swapFailed(String)

        var errorDescription: String? {
            switch self {
            case .notWritable(let path):
                return "Daisy cannot write to \(path). Install it by hand this time."
            case .mountFailed:
                return "The disk image could not be opened."
            case .noAppInImage:
                return "The disk image did not contain Daisy."
            case .signatureMismatch:
                return "The downloaded app is not signed by the same key as this one. "
                     + "It was discarded and nothing was changed."
            case .swapFailed(let why):
                return "The update could not be put in place: \(why)"
            }
        }
    }

    /// True when the running bundle sits somewhere we can replace in place.
    /// A copy running from a disk image or a read-only folder cannot update
    /// itself, and should keep the download-and-reveal behaviour.
    static var canInstallInPlace: Bool {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app" else { return false }
        let parent = bundle.deletingLastPathComponent()
        return FileManager.default.isWritableFile(atPath: parent.path)
            && FileManager.default.isWritableFile(atPath: bundle.path)
    }

    /// Mounts `dmg`, verifies the app inside, swaps it in, and relaunches.
    /// Throws without touching the installed app if any step fails.
    static func install(from dmg: URL) throws -> Never {
        let bundle = Bundle.main.bundleURL
        guard canInstallInPlace else {
            throw Failure.notWritable(bundle.deletingLastPathComponent().path)
        }
        try swap(from: dmg, replacing: bundle)
        relaunch(at: bundle)
    }

    /// The whole update except the relaunch, so it can be exercised against a
    /// throwaway copy rather than the app you are running.
    static func swap(from dmg: URL, replacing bundle: URL) throws {
        let fm = FileManager.default
        let parent = bundle.deletingLastPathComponent()

        let mount = fm.temporaryDirectory
            .appendingPathComponent("daisy-update-\(UUID().uuidString)")
        try fm.createDirectory(at: mount, withIntermediateDirectories: true)
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet", "-force"])
            try? fm.removeItem(at: mount)
        }

        // -nobrowse keeps it out of Finder, -noautoopen stops the window.
        guard run("/usr/bin/hdiutil",
                  ["attach", dmg.path, "-nobrowse", "-noautoopen", "-quiet",
                   "-mountpoint", mount.path]) == 0 else {
            throw Failure.mountFailed
        }

        let incoming = mount.appendingPathComponent("Daisy.app")
        guard fm.fileExists(atPath: incoming.path) else { throw Failure.noAppInImage }
        guard satisfiesOurRequirement(incoming) else { throw Failure.signatureMismatch }

        // Stage beside the destination so the final move is on one volume.
        let staged = parent.appendingPathComponent("Daisy.app.incoming-\(UUID().uuidString)")
        // ditto rather than copyItem: it preserves the signature's extended
        // attributes, which a plain copy can drop and thereby invalidate.
        guard run("/usr/bin/ditto", [incoming.path, staged.path]) == 0 else {
            try? fm.removeItem(at: staged)
            throw Failure.swapFailed("the new copy could not be written")
        }
        // The download carries a quarantine flag. It has just been checked
        // against our own signing key, which is a stronger statement than
        // Gatekeeper's, and leaving the flag on would stop it relaunching.
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])

        guard satisfiesOurRequirement(staged) else {
            try? fm.removeItem(at: staged)
            throw Failure.signatureMismatch
        }

        // Keep the old bundle until the new one is in place.
        let retired = parent.appendingPathComponent("Daisy.app.old-\(UUID().uuidString)")
        do {
            try fm.moveItem(at: bundle, to: retired)
        } catch {
            try? fm.removeItem(at: staged)
            throw Failure.swapFailed(error.localizedDescription)
        }
        do {
            try fm.moveItem(at: staged, to: bundle)
        } catch {
            try? fm.moveItem(at: retired, to: bundle)   // put it back
            try? fm.removeItem(at: staged)
            throw Failure.swapFailed(error.localizedDescription)
        }
        try? fm.removeItem(at: retired)
    }

    /// Exposed so `--selftest` can exercise the check against a real bundle
    /// without running an update.
    static func probeRequirement(_ app: URL) -> Bool { satisfiesOurRequirement(app) }

    /// Checks a bundle against the requirement the running code was signed to.
    private static func satisfiesOurRequirement(_ app: URL) -> Bool {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return false }
        var selfStatic: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess,
              let selfStatic else { return false }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess,
              let requirement else { return false }

        var candidate: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &candidate) == errSecSuccess,
              let candidate else { return false }
        return SecStaticCodeCheckValidity(candidate, [], requirement) == errSecSuccess
    }

    /// Hands off to a detached shell that waits for this process to exit and
    /// then opens the new copy. Relaunching from inside the dying process is
    /// what makes updaters flaky.
    private static func relaunch(at app: URL) -> Never {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; "
                   + "/usr/bin/open \(shellQuoted(app.path))"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        try? task.run()
        NSApp.terminate(nil)
        exit(0)
    }

    private static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return -1 }
        task.waitUntilExit()
        return task.terminationStatus
    }
}
