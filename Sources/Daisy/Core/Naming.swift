import Foundation

enum Collision: String {
    case suffix     // "name 2.ext", "name 3.ext", ...
    case overwrite
    case skip
}

enum Naming {
    /// The folder output for `input` lands in: `dir` if given, else beside the
    /// source — unless that folder can't be written (a mounted DMG, a network
    /// share, Photos' or a screenshot's read-only container), in which case
    /// ~/Downloads. Without this the engine fails with EROFS mid-conversion.
    static func baseDir(for input: URL, into dir: URL?) -> URL {
        let wanted = dir ?? input.deletingLastPathComponent()
        return isWritableDir(wanted) ? wanted : fallbackDir
    }

    static var fallbackDir: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// A folder that doesn't exist yet counts as writable when its nearest
    /// existing ancestor is — `createDirectory` will make the rest.
    static func isWritableDir(_ url: URL) -> Bool {
        let fm = FileManager.default
        var u = url.standardizedFileURL
        while !fm.fileExists(atPath: u.path) {
            let up = u.deletingLastPathComponent()
            if up.path == u.path { return false }
            u = up
        }
        return fm.isWritableFile(atPath: u.path)
    }

    /// Where a conversion of `input` to `target` should be written.
    /// `dir == nil` means "beside the source". Returns nil only when the policy
    /// is `.skip` and something is already there.
    static func output(for input: URL, target: Format, into dir: URL?, collision: Collision) -> URL? {
        let fm = FileManager.default
        let baseDir = baseDir(for: input, into: dir)
        let stem = strippedStem(of: input)

        func candidate(_ suffix: String) -> URL {
            let name = suffix.isEmpty ? stem : "\(stem) \(suffix)"
            return target.ext.isEmpty
                ? baseDir.appendingPathComponent(name, isDirectory: true)
                : baseDir.appendingPathComponent(name).appendingPathExtension(target.ext)
        }

        var url = candidate("")
        if url.path == input.path { url = candidate("converted") }

        guard fm.fileExists(atPath: url.path) else { return url }
        switch collision {
        case .overwrite: return url
        case .skip:      return nil
        case .suffix:
            var n = 2
            while fm.fileExists(atPath: candidate(String(n)).path) { n += 1 }
            return candidate(String(n))
        }
    }

    /// Output for a same-format tool: `photo-resized.jpg`, bumped on collision.
    static func toolOutput(for input: URL, tag: String, ext: String, into dir: URL?,
                           collision: Collision = .suffix) -> URL? {
        let fm = FileManager.default
        let baseDir = baseDir(for: input, into: dir)
        let stem = strippedStem(of: input)
        func candidate(_ n: Int) -> URL {
            let base = tag.isEmpty ? stem : "\(stem)-\(tag)"
            let name = n == 0 ? base : "\(base) \(n)"
            return baseDir.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var n = 0
        while fm.fileExists(atPath: candidate(n).path) {
            if collision == .overwrite { return candidate(n) }
            if collision == .skip { return nil }
            n += 1
        }
        return candidate(n)
    }

    /// Drop the extension, collapsing the `.tar.gz` / `.tgz` double extension.
    static func strippedStem(of url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") { return String(name.dropLast(7)) }
        return url.deletingPathExtension().lastPathComponent
    }
}
