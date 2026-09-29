import Foundation

/// Raster images via libvips, with an ImageIO fallback when vips isn't present.
/// SVG rasterizing via resvg; raster → SVG traced with potrace (fed a PGM that
/// NativeOps rasterizes in-process, so vips isn't required for the trace).
struct ImageConverter: Converter {
    static let raster = ["jpg", "png", "webp", "heic", "avif", "tiff", "bmp", "gif"]
    static let imageIOWritable: Set<String> = ["jpg", "png", "tiff", "heic", "avif", "gif", "bmp"]
    /// The vips builds we bundle have no libheif module — HEIC/AVIF on either
    /// side goes through macOS ImageIO, which encodes and decodes both natively.
    static let heifish: Set<String> = ["heic", "avif"]

    func targets(for input: Format) -> [Format] {
        guard input.category == .image else { return [] }
        if input.id == "svg" {
            return Self.raster.compactMap { Formats.byID[$0] }
        }
        var ids = Set(Self.raster)
        ids.remove(input.id)
        ids.insert("svg")   // trace
        return ids.compactMap { Formats.byID[$0] }
    }

    /// resvg only ever writes PNG — asked for `out.jpg` it wrote PNG bytes under
    /// a JPEG name. Anything else goes SVG → temp PNG → target.
    func execute(input: URL, from: Format, to: Format, output: URL, opts: ConvertOptions) throws -> Bool {
        guard from.id == "svg", to.id != "png", let png = Formats.byID["png"] else { return false }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Engine.run(input: input, to: png, output: tmp, opts: opts)
        var rest = opts
        rest.scale = nil   // already applied by resvg
        try Engine.run(input: tmp, to: to, output: output, opts: rest)
        return true
    }

    func plan(input: URL, from: Format, to: Format, output: URL, opts: ConvertOptions) throws -> Invocation {
        if from.id == "svg" {
            // resvg takes `[options] <in> <out>` — there is no -o. Passing one
            // made it write a file literally named "-o" into the working
            // directory, which for the app is / (read-only), so every SVG
            // conversion died with "Read-only file system".
            var a: [String] = []
            if let w = opts.scaleWidth { a += ["--width", String(w)] }
            return Invocation(engine: .resvg, args: a + [input.path, output.path])
        }

        if to.id == "svg" {
            // potrace reads the PGM; {PGM} is swapped for a temp path by Engine.run.
            return Invocation(engine: .potrace,
                              args: ["-s", "--flat", "-o", output.path, "{PGM}"],
                              rasterizeInputToPGM: true)
        }

        // WebP is the one raster format ImageIO decodes but won't encode, so it
        // needs a binary. cwebp is the small BSD one we bundle; vips also works
        // if the user has it. Either way the input is decoded to a temp PNG
        // first — cwebp reads PNG/JPEG/TIFF only, and going through ImageIO is
        // what lets a HEIC or a BMP get here at all.
        if to.id == "webp", EngineLocator.path(for: .cwebp) != nil {
            var a = ["-q", String(opts.quality ?? 82)]
            if !opts.stripMetadata { a += ["-metadata", "all"] }
            return Invocation(engine: .cwebp, args: a + ["{PNG}", "-o", output.path],
                              stageInputAsPNG: true)
        }

        // ImageIO for HEIC/AVIF (bundled vips can't) and as the fallback when
        // vips isn't installed at all.
        if Self.heifish.contains(from.id) || Self.heifish.contains(to.id) || EngineLocator.path(for: .vips) == nil {
            guard Self.imageIOWritable.contains(to.id) else {
                throw ConvertError.engineMissing(to.id == "webp" ? .cwebp : .vips)
            }
            return Invocation(engine: .native, nativeKind: .imageIO(to))
        }

        // vips save options ride on the output filename: out.jpg[Q=80,strip]
        var saveOpts: [String] = []
        if let q = opts.quality, ["jpg", "webp", "heic", "avif", "tiff"].contains(to.id) {
            saveOpts.append("Q=\(q)")
        }
        if opts.stripMetadata { saveOpts.append("strip") }
        // No alpha in these; without a background vips flattens onto black.
        if ["jpg", "bmp"].contains(to.id) { saveOpts.append("background=255") }
        let outSpec = saveOpts.isEmpty ? output.path : "\(output.path)[\(saveOpts.joined(separator: ","))]"

        if let w = opts.scaleWidth {
            // --size down keeps it from upscaling small inputs, like the ImageIO path.
            return Invocation(engine: .vips, args: ["thumbnail", input.path, outSpec, String(w), "--size", "down"])
        }
        return Invocation(engine: .vips, args: ["copy", input.path, outSpec])
    }
}
