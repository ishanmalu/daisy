import Foundation

/// Executes a `Tool` over one or more inputs, producing new files next to the
/// originals (or in `dir`). Blocking; call off the main thread.
enum ToolRunner {
    struct Params {
        var quality: Int? = nil
        var scalePercent: Int? = nil
        var maxEdge: Int? = nil
        var aspect: String? = nil          // "16:9"
        var trimDuration: Double? = nil
        var into: URL? = nil
        var collision: Collision = .suffix

        init(preset p: ToolPreset? = nil) {
            quality = p?.quality
            scalePercent = p?.scalePercent
            maxEdge = p?.maxEdge
            aspect = p?.aspect
            trimDuration = p?.trimDuration
        }
    }

    @discardableResult
    static func run(_ tool: Tool, inputs: [URL], params: Params) throws -> [URL] {
        switch tool {
        case .pdfMerge:
            let out = Naming.baseDir(for: inputs[0], into: params.into)
                .appendingPathComponent("merged.pdf")
            let dest = Naming.toolOutput(for: out, tag: "", ext: "pdf", into: params.into) ?? out
            try NativeOps.pdfMerge(inputs, to: dest)
            return [dest]

        case .pdfSplit:
            let base = Naming.baseDir(for: inputs[0], into: params.into)
            let dir = base.appendingPathComponent("\(Naming.strippedStem(of: inputs[0])) pages", isDirectory: true)
            try NativeOps.pdfSplit(inputs[0], into: dir)
            return [dir]

        default:
            var outputs: [URL] = []
            for input in inputs {
                guard let f = Formats.byURL(input) else {
                    throw ConvertError.badInput("Unrecognized: \(input.lastPathComponent)")
                }
                let ext = tool.outputExt ?? (input.pathExtension.isEmpty ? f.ext : input.pathExtension)
                guard let out = Naming.toolOutput(for: input, tag: tag(tool), ext: ext,
                                                  into: params.into, collision: params.collision) else { continue }
                try apply(tool, input: input, format: f, output: out, params: params)
                outputs.append(out)
            }
            return outputs
        }
    }

    private static func tag(_ t: Tool) -> String {
        switch t {
        case .resize: return "resized"
        case .compress: return "compressed"
        case .crop: return "cropped"
        case .stripMetadata: return "clean"
        case .trim: return "trimmed"
        case .ocr: return "ocr"
        case .removeBackground: return "nobg"
        default: return "out"
        }
    }

    /// Run one tool, input → explicit output. Also the entry point for recipe steps.
    static func apply(_ tool: Tool, input: URL, format f: Format, output: URL, params: Params) throws {
        try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)

        switch tool {
        case .ocr:
            try NativeOps.ocrToSearchablePDF(input, to: output)
            return
        case .removeBackground:
            guard f.category == .image else { throw ConvertError.badInput("Remove background needs an image.") }
            try NativeOps.removeBackground(input, to: output)
            return
        default:
            break
        }

        switch (tool, f.category) {

        case (.resize, .image), (.crop, .image), (.compress, .image), (.stripMetadata, .image):
            try NativeOps.editImage(input, to: output, tool: tool, params: params)

        case (.resize, .video), (.crop, .video), (.compress, .video), (.trim, .video),
             (.stripMetadata, .video), (.trim, .audio):
            try ffmpegEdit(tool, input: input, output: output, params: params, category: f.category)

        case (.stripMetadata, .audio):
            try ffmpegEdit(.stripMetadata, input: input, output: output, params: params, category: .audio)

        case (.compress, .document), (.stripMetadata, .document):
            guard f.id == "pdf" else { throw ConvertError.unsupported(from: f.id, to: f.id) }
            if tool == .compress {
                try NativeOps.pdfCompress(input, to: output, quality: params.quality ?? 60)
            } else {
                try NativeOps.pdfStripMetadata(input, to: output)
            }

        default:
            throw ConvertError.badInput("\(tool.label) doesn't apply to \(f.label).")
        }
    }

    // MARK: ffmpeg-backed edits

    private static func ffmpegEdit(_ tool: Tool, input: URL, output: URL,
                                   params: Params, category: Category) throws {
        guard let bin = EngineLocator.path(for: .ffmpeg) else { throw ConvertError.engineMissing(.ffmpeg) }
        var a = ["-hide_banner", "-loglevel", "error", "-y"]

        if tool == .trim {
            a += ["-i", input.path, "-t", String(params.trimDuration ?? 10),
                  "-avoid_negative_ts", "make_zero", "-c", "copy", output.path]
            try runFF(bin, a); return
        }
        if tool == .stripMetadata {
            a += ["-i", input.path, "-map_metadata", "-1", "-c", "copy", output.path]
            try runFF(bin, a); return
        }

        a += ["-i", input.path]
        var vf: String
        switch tool {
        case .resize:
            if let p = params.scalePercent {
                let s = Double(p) / 100.0
                vf = "scale=trunc(iw*\(s)/2)*2:trunc(ih*\(s)/2)*2"
            } else {
                let m = params.maxEdge ?? 1280
                vf = "scale=\(m):\(m):force_original_aspect_ratio=decrease"
            }
        case .crop:
            let (an, ad) = aspectPair(params.aspect ?? "1:1")
            vf = "crop='min(iw,ih*\(an)/\(ad))':'min(ih,iw*\(ad)/\(an))'"
        case .compress:
            vf = "scale=iw:ih"   // no geometry change; quality handled below
        default:
            vf = "scale=iw:ih"
        }
        // yuv420p needs even dimensions; a 9:16 crop of 1080p is 607 wide and
        // libx264 refuses it. Round every geometry down to even.
        vf += ",scale=trunc(iw/2)*2:trunc(ih/2)*2"
        let q = crf(params.quality, base: tool == .compress ? 30 : 23)
        a += ["-vf", vf]
        if output.pathExtension.lowercased() == "webm" {
            // WebM only carries VP8/VP9/AV1 and Vorbis/Opus.
            a += ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", String(q + 8),
                  "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "128k", output.path]
        } else {
            a += ["-c:v", "libx264", "-crf", String(q),
                  "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k",
                  "-movflags", "+faststart", output.path]
        }
        try runFF(bin, a)
    }

    private static func crf(_ q: Int?, base: Int) -> Int {
        guard let q else { return base }
        return max(16, min(34, 40 - Int(Double(q) / 100.0 * 24)))
    }

    private static func aspectPair(_ s: String) -> (Int, Int) {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : (1, 1)
    }

    private static func runFF(_ bin: String, _ args: [String]) throws {
        let r = ProcessRun.run(bin, args, env: Engine.bundledEngineEnv(bin), timeout: 600)
        if r.code != 0 {
            throw ConvertError.processFailed(code: r.code, message: String((r.stderr.isEmpty ? r.stdout : r.stderr).suffix(500)))
        }
    }
}
