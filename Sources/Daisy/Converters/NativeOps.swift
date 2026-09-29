import Foundation
import AppKit
import PDFKit
import ImageIO
import UniformTypeIdentifiers
import Vision
import CoreImage
import CoreText

/// In-process conversions backed by macOS frameworks. No bundled binary.
enum NativeOps {
    static func perform(_ kind: NativeKind, input: URL, output: URL, opts: ConvertOptions) throws {
        switch kind {
        case .imageIO(let target):
            try writeImage(from: input, to: output, target: target, opts: opts)
        case .pdfFromImages:
            try pdfFromImages([input], to: output)
        case .pdfRasterize(let target):
            try rasterizePDF(input, into: output, target: target, opts: opts)
        }
    }

    // MARK: - Images

    private static func utType(for id: String) -> UTType? {
        switch id {
        case "jpg":  return .jpeg
        case "png":  return .png
        case "tiff": return .tiff
        case "heic": return .heic
        case "gif":  return .gif
        case "bmp":  return .bmp
        case "webp": return UTType("org.webmproject.webp")
        case "avif": return UTType("public.avif")
        default:     return nil
        }
    }

    /// `keep` is the source's property dictionary. Passing it through is what
    /// carries EXIF, GPS and the TIFF block into the new file; without it every
    /// ImageIO conversion silently drops the capture date, camera and location.
    private static func writeCGImage(_ image: CGImage, to output: URL, id: String,
                                     quality: Int?, keep: [CFString: Any]? = nil) throws {
        if id == "webp" {
            try writeWebP(image, to: output, quality: quality, keep: keep)
            return
        }
        guard let type = utType(for: id),
              let dest = CGImageDestinationCreateWithURL(output as CFURL, type.identifier as CFString, 1, nil) else {
            throw ConvertError.badInput("The built-in encoder can't write \(id.uppercased()).")
        }
        // JPEG and BMP have no alpha; handed a transparent PNG, ImageIO drops the
        // channel and the see-through parts come out black. Flatten onto white.
        let alpha = image.alphaInfo
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(alpha)
        let image = (hasAlpha && ["jpg", "bmp"].contains(id)) ? (flattened(image) ?? image) : image

        var props = keep ?? [:]
        // We always hand ImageIO upright pixels, and the stored dimensions would
        // be stale after a resize or crop.
        props[kCGImagePropertyOrientation] = 1
        props.removeValue(forKey: kCGImagePropertyPixelWidth)
        props.removeValue(forKey: kCGImagePropertyPixelHeight)
        if let q = quality, ["jpg", "heic", "webp", "avif"].contains(id) {
            props[kCGImageDestinationLossyCompressionQuality] = Double(q) / 100.0
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ConvertError.badInput("Failed to write \(output.lastPathComponent)")
        }
    }

    /// ImageIO decodes WebP but can't encode it, so a resize or crop of a WebP
    /// used to fail outright. Stage a PNG and hand it to cwebp.
    private static func writeWebP(_ image: CGImage, to output: URL, quality: Int?,
                                  keep: [CFString: Any]?) throws {
        guard let bin = EngineLocator.path(for: .cwebp) else { throw ConvertError.engineMissing(.cwebp) }
        let png = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        try writeCGImage(image, to: png, id: "png", quality: nil, keep: keep)
        var a = ["-quiet", "-q", String(quality ?? 82)]
        if keep != nil { a += ["-metadata", "all"] }
        let r = ProcessRun.run(bin, a + [png.path, "-o", output.path],
                               env: Engine.bundledEngineEnv(bin), timeout: 300)
        if r.code != 0 {
            throw ConvertError.processFailed(code: r.code, message: String((r.stderr.isEmpty ? r.stdout : r.stderr).suffix(500)))
        }
    }

    private static func flattened(_ image: CGImage) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(r)
        ctx.draw(image, in: r)
        return ctx.makeImage()
    }

    /// The image with its EXIF rotation baked into the pixels, plus the source
    /// properties. Everything downstream can then treat it as upright, which is
    /// what makes a centre crop land where the viewer sees it.
    private static func loadUpright(_ url: URL) throws -> (image: CGImage, props: [CFString: Any]) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let raw = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw ConvertError.badInput("Couldn't read image: \(url.lastPathComponent)")
        }
        let props = (CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]) ?? [:]
        let o = (props[kCGImagePropertyOrientation] as? Int32) ?? 1
        guard o > 1, o <= 8 else { return (raw, props) }
        let ci = CIImage(cgImage: raw).oriented(forExifOrientation: o)
        return (CIContext().createCGImage(ci, from: ci.extent) ?? raw, props)
    }

    private static func loadCGImage(_ url: URL) throws -> CGImage {
        try loadUpright(url).image
    }

    private static func writeImage(from input: URL, to output: URL, target: Format, opts: ConvertOptions) throws {
        var (image, props) = try loadUpright(input)
        if let w = opts.scaleWidth, w > 0, w < image.width {
            image = resized(image, toWidth: w) ?? image
        }
        try writeCGImage(image, to: output, id: target.id, quality: opts.quality,
                         keep: opts.stripMetadata ? nil : props)
    }

    /// Upright PNG of anything ImageIO can decode. cwebp only reads PNG/JPEG/TIFF,
    /// so this is how a HEIC or a BMP reaches it.
    static func stagePNG(_ input: URL, to output: URL, opts: ConvertOptions) throws {
        var (image, props) = try loadUpright(input)
        if let w = opts.scaleWidth, w > 0, w < image.width {
            image = resized(image, toWidth: w) ?? image
        }
        try writeCGImage(image, to: output, id: "png", quality: nil,
                         keep: opts.stripMetadata ? nil : props)
    }

    private static func resized(_ image: CGImage, toWidth w: Int) -> CGImage? {
        let h = Int((Double(image.height) * Double(w) / Double(image.width)).rounded())
        return redraw(image, width: w, height: max(1, h))
    }

    private static func redraw(_ image: CGImage, width w: Int, height h: Int) -> CGImage? {
        // An 8-bit premultiplied-alpha context only exists for RGB. Keeping a
        // grey, CMYK or indexed source's own space made CGContext return nil,
        // and every caller's `?? image` then skipped the resize silently.
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil }
            ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: - Same-format image tools (resize / crop / compress / strip)

    static func editImage(_ input: URL, to output: URL, tool: Tool, params: ToolRunner.Params) throws {
        let id = Formats.byURL(output)?.id ?? output.pathExtension.lowercased()
        var (image, props) = try loadUpright(input)

        switch tool {
        case .resize:
            let (w, h): (Int, Int)
            if let p = params.scalePercent {
                w = max(1, image.width * p / 100); h = max(1, image.height * p / 100)
            } else {
                let m = params.maxEdge ?? 1280
                let longest = max(image.width, image.height)
                let s = longest > m ? Double(m) / Double(longest) : 1.0
                w = Int(Double(image.width) * s); h = Int(Double(image.height) * s)
            }
            image = redraw(image, width: w, height: h) ?? image

        case .crop:
            let (an, ad) = aspectPair(params.aspect ?? "1:1")
            let iw = CGFloat(image.width), ih = CGFloat(image.height)
            var cw = iw, ch = iw * CGFloat(ad) / CGFloat(an)
            if ch > ih { ch = ih; cw = ih * CGFloat(an) / CGFloat(ad) }
            let rect = CGRect(x: ((iw - cw) / 2).rounded(), y: ((ih - ch) / 2).rounded(),
                              width: cw.rounded(.down), height: ch.rounded(.down))
            image = image.cropping(to: rect) ?? image

        case .compress, .stripMetadata:
            break   // re-encode below; AddImage drops source metadata on its own
        default:
            throw ConvertError.badInput("\(tool.label) doesn't apply to images.")
        }

        let q = tool == .compress ? (params.quality ?? 60) : (tool == .stripMetadata ? nil : params.quality)
        try writeCGImage(image, to: output, id: id, quality: q,
                         keep: tool == .stripMetadata ? nil : props)
    }

    private static func aspectPair(_ s: String) -> (Int, Int) {
        let p = s.split(separator: ":").compactMap { Int($0) }
        return p.count == 2 ? (p[0], p[1]) : (1, 1)
    }

    // MARK: - PDF

    static func pdfFromImages(_ images: [URL], to output: URL) throws {
        guard !images.isEmpty else { throw ConvertError.badInput("Nothing to make a PDF from.") }
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConvertError.badInput("Couldn't create \(output.lastPathComponent)")
        }
        for url in images {
            let img = try loadCGImage(url)
            var box = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(img, in: box)
            pdf.endPage()
        }
        pdf.closePDF()
    }

    /// Rasterize a PDF page to a CGImage. Pure Core Graphics — safe on any thread
    /// (unlike NSImage.lockFocus, which these run off the main one).
    private static func renderPage(_ page: PDFPage, scale: CGFloat) -> CGImage? {
        let box = page.bounds(for: .mediaBox)
        let w = Int((box.width * scale).rounded()), h = Int((box.height * scale).rounded())
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()
        return ctx.makeImage()
    }

    private static func rasterizePDF(_ input: URL, into dir: URL, target: Format, opts: ConvertOptions) throws {
        guard let doc = PDFDocument(url: input) else {
            throw ConvertError.badInput("Couldn't open PDF: \(input.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let scale = CGFloat(max(1, min(6, (opts.quality ?? 50) / 20 + 1)))   // ~2x by default
        let stem = Naming.strippedStem(of: input)

        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let cg = renderPage(page, scale: scale) else {
                throw ConvertError.badInput("Failed to render page \(i + 1)")
            }
            let out = dir.appendingPathComponent(String(format: "%@-%03d", stem, i + 1))
                         .appendingPathExtension(target.ext)
            try writeCGImage(cg, to: out, id: target.id, quality: opts.quality ?? 85)
        }
    }

    // MARK: - PDF tools

    static func pdfMerge(_ inputs: [URL], to output: URL) throws {
        let merged = PDFDocument()
        var page = 0
        for url in inputs {
            if url.pathExtension.lowercased() == "pdf" {
                guard let doc = PDFDocument(url: url) else {
                    throw ConvertError.badInput("Couldn't open PDF: \(url.lastPathComponent)")
                }
                for i in 0..<doc.pageCount {
                    if let p = doc.page(at: i) { merged.insert(p, at: page); page += 1 }
                }
            } else {
                guard let img = NSImage(contentsOf: url), let p = PDFPage(image: img) else {
                    throw ConvertError.badInput("Couldn't read image: \(url.lastPathComponent)")
                }
                merged.insert(p, at: page); page += 1
            }
        }
        guard page > 0, merged.write(to: output) else {
            throw ConvertError.badInput("Failed to write \(output.lastPathComponent)")
        }
    }

    static func pdfSplit(_ input: URL, into dir: URL) throws {
        guard let doc = PDFDocument(url: input) else {
            throw ConvertError.badInput("Couldn't open PDF: \(input.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stem = Naming.strippedStem(of: input)
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let one = PDFDocument()
            one.insert(page, at: 0)
            let out = dir.appendingPathComponent(String(format: "%@-%03d.pdf", stem, i + 1))
            guard one.write(to: out) else { throw ConvertError.badInput("Failed to write page \(i + 1)") }
        }
    }

    /// Flatten every page to a JPEG at reduced DPI and rebuild — the standard
    /// "shrink a PDF" move. All Core Graphics, no AppKit.
    static func pdfCompress(_ input: URL, to output: URL, quality: Int) throws {
        guard let doc = PDFDocument(url: input) else {
            throw ConvertError.badInput("Couldn't open PDF: \(input.lastPathComponent)")
        }
        let dpiScale: CGFloat = quality >= 75 ? 2.0 : (quality >= 50 ? 1.5 : 1.1)
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let pdf = CGContext(output as CFURL, mediaBox: &mediaBox, nil) else {
            throw ConvertError.badInput("Couldn't create \(output.lastPathComponent)")
        }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i),
                  let raster = renderPage(page, scale: dpiScale),
                  let jpeg = jpegEncoded(raster, quality: quality) else {
                throw ConvertError.badInput("Failed to compress page \(i + 1)")
            }
            var box = CGRect(origin: .zero, size: page.bounds(for: .mediaBox).size)
            pdf.beginPage(mediaBox: &box)
            pdf.draw(jpeg, in: box)
            pdf.endPage()
        }
        pdf.closePDF()
    }

    /// Round-trip a CGImage through a JPEG so it carries JPEG data, not raw
    /// pixels — a CGPDFContext then embeds the JPEG stream as-is.
    private static func jpegEncoded(_ image: CGImage, quality: Int) -> CGImage? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: Double(quality) / 100.0] as CFDictionary)
        guard CGImageDestinationFinalize(dest),
              let src = CGImageSourceCreateWithData(data, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    static func pdfStripMetadata(_ input: URL, to output: URL) throws {
        guard let doc = PDFDocument(url: input) else {
            throw ConvertError.badInput("Couldn't open PDF: \(input.lastPathComponent)")
        }
        doc.documentAttributes = [:]
        guard doc.write(to: output) else { throw ConvertError.badInput("Failed to write \(output.lastPathComponent)") }
    }

    // MARK: - Vision: OCR → searchable PDF, background removal

    private struct OCRPage { let size: CGSize; let draw: (CGContext) -> Void; let ocr: CGImage }

    static func ocrToSearchablePDF(_ input: URL, to output: URL) throws {
        var pages: [OCRPage] = []
        if input.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(url: input) else {
                throw ConvertError.badInput("Couldn't open PDF: \(input.lastPathComponent)")
            }
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let box = page.bounds(for: .mediaBox)
                let scale: CGFloat = 2
                let w = Int(box.width * scale), h = Int(box.height * scale)
                guard w > 0, h > 0,
                      let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.saveGState(); ctx.scaleBy(x: scale, y: scale); ctx.translateBy(x: -box.minX, y: -box.minY)
                page.draw(with: .mediaBox, to: ctx); ctx.restoreGState()
                guard let raster = ctx.makeImage() else { continue }
                pages.append(OCRPage(size: box.size, draw: { c in page.draw(with: .mediaBox, to: c) }, ocr: raster))
            }
        } else {
            let img = try loadCGImage(input)
            let size = CGSize(width: img.width, height: img.height)
            pages.append(OCRPage(size: size, draw: { c in c.draw(img, in: CGRect(origin: .zero, size: size)) }, ocr: img))
        }
        guard !pages.isEmpty else { throw ConvertError.badInput("Nothing to OCR.") }

        var media = CGRect(origin: .zero, size: pages[0].size)
        guard let pdf = CGContext(output as CFURL, mediaBox: &media, nil) else {
            throw ConvertError.badInput("Couldn't create \(output.lastPathComponent)")
        }
        for p in pages {
            var box = CGRect(origin: .zero, size: p.size)
            pdf.beginPage(mediaBox: &box)
            p.draw(pdf)

            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: p.ocr, options: [:]).perform([req])
            pdf.setTextDrawingMode(.invisible)
            for obs in (req.results ?? []) {
                guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { continue }
                let r = VNImageRectForNormalizedRect(obs.boundingBox, Int(p.size.width), Int(p.size.height))
                guard r.width > 1, r.height > 2 else { continue }
                let font = CTFontCreateWithName("Helvetica" as CFString, r.height, nil)
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: text, attributes: [.font: font]))
                let measured = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                pdf.textMatrix = CGAffineTransform(scaleX: measured > 1 ? r.width / measured : 1, y: 1)
                pdf.textPosition = CGPoint(x: r.minX, y: r.minY + r.height * 0.18)
                CTLineDraw(line, pdf)
            }
            pdf.endPage()
        }
        pdf.closePDF()
    }

    static func removeBackground(_ input: URL, to output: URL) throws {
        let src = try loadCGImage(input)
        let handler = VNImageRequestHandler(cgImage: src, options: [:])
        let req = VNGenerateForegroundInstanceMaskRequest()
        // Vision's failures here are raw model-compiler dumps (seen on very
        // small images); nobody can act on those.
        do { try handler.perform([req]) }
        catch { throw ConvertError.badInput("Couldn't find a subject to cut out.") }
        guard let result = req.results?.first else {
            throw ConvertError.badInput("No clear subject to cut out.")
        }
        let maskBuffer = try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler)
        let base = CIImage(cgImage: src)
        let cut = base.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputMaskImageKey: CIImage(cvPixelBuffer: maskBuffer),
            kCIInputBackgroundImageKey: CIImage.empty(),
        ])
        guard let cg = CIContext().createCGImage(cut, from: base.extent) else {
            throw ConvertError.badInput("Failed to render cutout.")
        }
        try writeCGImage(cg, to: output, id: "png", quality: nil)
    }

    // MARK: - Grayscale PGM (feeds potrace for raster → SVG)

    static func writeGrayPGM(_ input: URL, to output: URL, maxEdge: Int = 1600) throws {
        var image = try loadCGImage(input)
        let longest = max(image.width, image.height)
        if longest > maxEdge {
            let s = Double(maxEdge) / Double(longest)
            image = redraw(image, width: Int(Double(image.width) * s), height: Int(Double(image.height) * s)) ?? image
        }
        let w = image.width, h = image.height
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(data: &gray, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
            throw ConvertError.badInput("Couldn't rasterize \(input.lastPathComponent)")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var data = Data("P5\n\(w) \(h)\n255\n".utf8)
        // PGM rows run top-to-bottom; CGContext buffer is bottom-up, so flip.
        for row in stride(from: h - 1, through: 0, by: -1) {
            data.append(contentsOf: gray[(row * w)..<(row * w + w)])
        }
        try data.write(to: output)
    }
}
