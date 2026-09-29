import Foundation
import CoreServices

/// Auto-converts whatever lands in a watched folder, then moves the original to
/// `<folder>/_processed/`. In-process; rules persist in `watch.json`.
struct WatchRule: Codable {
    var folder: String
    var toFormat: String?      // convert target id — mutually exclusive with recipe
    var recipe: String?        // recipe name
    var quality: Int?
    var enabled: Bool = true
}

final class WatchFolders {
    static let shared = WatchFolders()

    private let lock = NSLock()
    private var _rules: [WatchRule] = []
    private var stream: FSEventStreamRef?
    private let workQueue = DispatchQueue(label: "daisy.watch", qos: .utility)
    private var inFlight = Set<String>()
    /// Files Daisy itself just wrote into a watched folder. Without this the
    /// output of a rule is a new file in the folder and gets processed again —
    /// a recipe like web-image re-ran on its own result forever.
    private var produced = Set<String>()

    /// A snapshot; the FSEvents callback and the Settings UI both touch this.
    var rules: [WatchRule] {
        lock.lock(); defer { lock.unlock() }
        return _rules
    }
    private func setRules(_ r: [WatchRule]) {
        lock.lock(); _rules = r; lock.unlock()
    }

    func load() { setRules(Support.loadJSON([WatchRule].self, from: "watch.json") ?? []) }
    func save() { Support.saveJSON(rules, to: "watch.json") }

    func add(_ r: WatchRule) { setRules(rules + [r]); save(); restart() }
    func remove(at i: Int) {
        var r = rules; guard r.indices.contains(i) else { return }
        r.remove(at: i); setRules(r); save(); restart()
    }
    func setEnabled(_ on: Bool, at i: Int) {
        var r = rules; guard r.indices.contains(i) else { return }
        r[i].enabled = on; setRules(r); save(); restart()
    }

    func restart() { stop(); start() }

    func start() {
        let dirs = rules.filter(\.enabled).map(\.folder)
        guard !dirs.isEmpty else { return }
        for d in dirs {
            try? FileManager.default.createDirectory(atPath: (d as NSString).appendingPathComponent("_processed"),
                                                     withIntermediateDirectories: true)
        }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<WatchFolders>.fromOpaque(info).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.workQueue.async { arr.forEach(me.handle) }
        }
        stream = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx, dirs as CFArray,
                                     FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                     // UseCFTypes is what makes `paths` a CFArray. Without it
                                     // it is a char**, and the cast above crashed the app on
                                     // the first file to land in a watched folder.
                                     UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                                            | kFSEventStreamCreateFlagUseCFTypes))
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, workQueue)
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    /// One-shot: handle whatever is already sitting in the watched folders.
    func sweepAll() {
        for rule in rules where rule.enabled {
            let dir = URL(fileURLWithPath: rule.folder)
            let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in items where f.lastPathComponent != "_processed" && !f.hasDirectoryPath {
                process(f, rule: rule)
            }
        }
    }

    // MARK: internals

    /// FSEvents reports resolved paths (/private/tmp, not /tmp), so rules are
    /// compared in that form too.
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
            .resolvingSymlinksInPath().standardizedFileURL.path
    }

    private func handle(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        var isDir: ObjCBool = false
        guard !path.contains("/_processed/"),
              FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              name.first != ".",
              Formats.byURL(url) != nil   // skips .part, .crdownload, save-in-progress temps
        else { return }
        let parent = Self.canonical((path as NSString).deletingLastPathComponent)
        guard let rule = rules.first(where: { $0.enabled && Self.canonical($0.folder) == parent }) else { return }
        lock.lock(); let ours = produced.remove(path) != nil; lock.unlock()
        if ours { return }
        waitUntilSettled(url) { [weak self] in self?.process(url, rule: rule) }
    }

    /// A second's grace isn't enough for a large copy. Wait until the size
    /// stops changing across two checks, giving up after a minute.
    private func waitUntilSettled(_ url: URL, last: Int64 = -1, tries: Int = 0, then go: @escaping () -> Void) {
        workQueue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? -1
            if size < 0 { return }                          // gone
            if size == last || tries >= 60 { go(); return }
            self?.waitUntilSettled(url, last: size, tries: tries + 1, then: go)
        }
    }

    private func claim(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return inFlight.insert(key).inserted
    }
    private func release(_ key: String) {
        lock.lock(); inFlight.remove(key); lock.unlock()
    }

    private func process(_ file: URL, rule: WatchRule) {
        let key = file.path
        guard FileManager.default.fileExists(atPath: key), claim(key) else { return }
        defer { release(key) }

        do {
            let written: URL
            if let recipeName = rule.recipe, let recipe = Recipes.named(recipeName) {
                written = try RecipeRunner.run(recipe, input: file, into: nil)
            } else if let id = rule.toFormat, let target = Formats.byID[id] {
                // Already the target format: nothing to do, and no route exists.
                if Formats.byURL(file)?.id == target.id { return }
                guard let out = Naming.output(for: file, target: target, into: nil, collision: .suffix) else { return }
                written = try Engine.run(input: file, to: target, output: out,
                                         opts: ConvertOptions(quality: rule.quality))
            } else { return }
            lock.lock(); produced.insert(Self.canonical(written.path)); lock.unlock()

            // Never overwrite an earlier original of the same name — bump it.
            let bin = URL(fileURLWithPath: rule.folder).appendingPathComponent("_processed", isDirectory: true)
            try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            var processed = bin.appendingPathComponent(file.lastPathComponent)
            var n = 2
            while FileManager.default.fileExists(atPath: processed.path) {
                let stem = file.deletingPathExtension().lastPathComponent, ext = file.pathExtension
                processed = bin.appendingPathComponent(ext.isEmpty ? "\(stem) \(n)" : "\(stem) \(n).\(ext)")
                n += 1
            }
            try? FileManager.default.moveItem(at: file, to: processed)
        } catch {
            NSLog("Daisy watch: \(file.lastPathComponent) — \(error.localizedDescription)")
        }
    }
}
