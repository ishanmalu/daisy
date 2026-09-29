import Foundation

/// `native` = done in-process with ImageIO / PDFKit / Vision, no binary needed.
enum EngineID: String {
    case ffmpeg, vips, cwebp, resvg, potrace, pandoc, libreoffice, qpdf
    case sevenzip = "7zz"
    case unar, bsdtar, exiftool
    case native
}

struct ConvertOptions {
    var quality: Int? = nil          // 1...100 where the target supports it
    var scale: String? = nil         // "WIDTHx" — target width, aspect kept
    var stripMetadata: Bool = false

    /// Target width from a "WIDTHx" string. "x400" (height only) yields nil.
    var scaleWidth: Int? {
        guard let s = scale?.split(separator: "x", omittingEmptySubsequences: false).first,
              let w = Int(s), w > 0 else { return nil }
        return w
    }
}

/// What kind of in-process operation a `native` plan should run.
enum NativeKind {
    case imageIO(Format)
    case pdfFromImages
    case pdfRasterize(Format)
}

struct Invocation {
    var engine: EngineID
    var args: [String] = []          // excludes the resolved binary path
    var producesDirectory = false    // the output path is a directory to create
    var nativeKind: NativeKind? = nil
    var rasterizeInputToPGM = false  // write a temp PGM first; "{PGM}" in args is the temp path
    var stageInputAsPNG = false      // decode to a temp PNG first; "{PNG}" in args is the temp path
}

protocol Converter {
    /// Formats reachable from `input` (never `input` itself).
    func targets(for input: Format) -> [Format]
    func plan(input: URL, from: Format, to: Format, output: URL, opts: ConvertOptions) throws -> Invocation
    /// Multi-step converters override this and return true once `output` exists.
    /// It has to be a protocol requirement, not just an extension member, or
    /// calls through the existential would pick the default.
    func execute(input: URL, from: Format, to: Format, output: URL, opts: ConvertOptions) throws -> Bool
    /// True when the output is a directory (PDF pages, an extracted archive) —
    /// Engine drops the extension the caller put on the path.
    func writesDirectory(from: Format, to: Format) -> Bool
}

extension Converter {
    func execute(input: URL, from: Format, to: Format, output: URL, opts: ConvertOptions) throws -> Bool { false }
    func writesDirectory(from: Format, to: Format) -> Bool { false }
}

enum ConvertError: LocalizedError {
    case badInput(String)
    case unsupported(from: String, to: String)
    case engineMissing(EngineID)
    case rarCreateUnsupported
    case processFailed(code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .badInput(let m): return m
        case .unsupported(let f, let t): return "No route from \(f.uppercased()) to \(t.uppercased())."
        case .engineMissing(let e):
            return "The \(e.rawValue) engine isn't installed. Run Scripts/bundle-engines.sh, "
                 + "or `brew install \(Self.formula(for: e))`."
        case .rarCreateUnsupported:
            return "Creating RAR archives isn't supported — there's no licensable RAR encoder. Use ZIP or 7z."
        case .processFailed(let c, let m): return "Engine exited \(c): \(m)"
        }
    }

    /// Homebrew's name for an engine, where it differs from the binary's.
    static func formula(for e: EngineID) -> String {
        switch e {
        case .sevenzip: return "sevenzip"
        case .cwebp: return "webp"
        default: return e.rawValue
        }
    }
}

enum Engine {
    static let converters: [Converter] = [
        ImageConverter(),
        MediaConverter(),
        ArchiveConverter(),
        PDFConverter(),
        DocConverter(),
    ]

    static func targets(for input: Format) -> [Format] {
        var seen: Set<String> = [input.id]
        var out: [Format] = []
        for c in converters {
            for t in c.targets(for: input) where !seen.contains(t.id) {
                seen.insert(t.id)
                out.append(t)
            }
        }
        return out.sorted { $0.label < $1.label }
    }

    static func converter(from: Format, to: Format) -> Converter? {
        converters.first { $0.targets(for: from).contains(to) }
    }

    /// A binary bundled in the app should not pick up Homebrew's GIO / pixbuf
    /// module dirs — vips would then load a second libgio and warn (or crash).
    /// Point them at nothing.
    static func bundledEngineEnv(_ binPath: String) -> [String: String]? {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("engine").path,
              binPath.hasPrefix(res) else { return nil }
        let none = "\(res)/nonexistent"
        return [
            "GIO_MODULE_DIR": none,
            "GDK_PIXBUF_MODULEDIR": none,
            "GSETTINGS_SCHEMA_DIR": none,
            "G_MESSAGES_DEBUG": "",
        ]
    }

    /// One file in, one file (or one folder) out. Blocking. Returns the path
    /// actually written, which differs from `output` when the result is a folder.
    @discardableResult
    static func run(input: URL, to target: Format, output: URL, opts: ConvertOptions) throws -> URL {
        guard let from = Formats.byURL(input) else {
            throw ConvertError.badInput("Unrecognized file type: \(input.lastPathComponent)")
        }
        guard let conv = converter(from: from, to: target) else {
            throw ConvertError.unsupported(from: from.id, to: target.id)
        }

        var dest = output
        if conv.writesDirectory(from: from, to: target), !dest.pathExtension.isEmpty {
            dest = dest.deletingPathExtension()
        }
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)

        if try conv.execute(input: input, from: from, to: target, output: dest, opts: opts) { return dest }

        let plan = try conv.plan(input: input, from: from, to: target, output: dest, opts: opts)
        if plan.producesDirectory {
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        }

        if let kind = plan.nativeKind {
            try NativeOps.perform(kind, input: input, output: dest, opts: opts)
            return dest
        }
        guard let bin = EngineLocator.path(for: plan.engine) else {
            throw ConvertError.engineMissing(plan.engine)
        }

        var args = plan.args
        var staged: URL?
        if plan.rasterizeInputToPGM {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("daisy-\(UUID().uuidString).pgm")
            try NativeOps.writeGrayPGM(input, to: tmp)
            staged = tmp
            args = args.map { $0 == "{PGM}" ? tmp.path : $0 }
        } else if plan.stageInputAsPNG {
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("daisy-\(UUID().uuidString).png")
            try NativeOps.stagePNG(input, to: tmp, opts: opts)
            staged = tmp
            args = args.map { $0 == "{PNG}" ? tmp.path : $0 }
        }
        defer { staged.map { try? FileManager.default.removeItem(at: $0) } }

        // A launched app's working directory is /, which is read-only; an engine
        // that writes anything relative should never land there.
        let r = ProcessRun.run(bin, args, cwd: FileManager.default.temporaryDirectory,
                               env: bundledEngineEnv(bin), timeout: 600)
        if r.code != 0 {
            let msg = r.stderr.isEmpty ? r.stdout : r.stderr
            throw ConvertError.processFailed(code: r.code, message: String(msg.suffix(600)))
        }
        // Exit 0 with nothing written is a failure, not a success — this is
        // how a bad resvg invocation used to pass silently.
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw ConvertError.processFailed(code: 0, message: "\(plan.engine.rawValue) wrote no output")
        }
        return dest
    }
}
