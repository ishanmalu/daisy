import Foundation

/// Same-format edits (the ⌥ mode in the HUD, and `daisy tool …` on the CLI).
/// A conversion changes the container; a tool keeps it and rewrites the bytes.
enum Tool: String, CaseIterable {
    case resize, compress, crop, stripMetadata, trim
    case ocr, removeBackground
    case pdfMerge, pdfSplit

    var label: String {
        switch self {
        case .resize:           return "Resize"
        case .compress:         return "Compress"
        case .crop:             return "Crop"
        case .stripMetadata:    return "Strip metadata"
        case .trim:             return "Trim"
        case .ocr:              return "OCR → PDF"
        case .removeBackground: return "Remove bg"
        case .pdfMerge:         return "Merge PDF"
        case .pdfSplit:         return "Split PDF"
        }
    }

    /// Tools that always write a specific type regardless of input.
    var outputExt: String? {
        switch self {
        case .ocr:              return "pdf"
        case .removeBackground: return "png"
        default:                return nil
        }
    }

    /// Preset chips shown after a tool is picked. Empty == runs immediately.
    var presets: [ToolPreset] {
        switch self {
        case .resize:
            return [.init("¼", scale: 25), .init("½", scale: 50),
                    .init("≤1920", maxEdge: 1920), .init("≤1280", maxEdge: 1280), .init("≤640", maxEdge: 640)]
        case .compress:
            return [.init("Light", quality: 80), .init("Medium", quality: 60), .init("Strong", quality: 40)]
        case .crop:
            return [.init("1:1", aspect: "1:1"), .init("4:5", aspect: "4:5"),
                    .init("16:9", aspect: "16:9"), .init("9:16", aspect: "9:16")]
        case .trim:
            return [.init("first 5s", trim: 5), .init("first 10s", trim: 10),
                    .init("first 30s", trim: 30), .init("first 60s", trim: 60)]
        case .stripMetadata, .ocr, .removeBackground, .pdfMerge, .pdfSplit:
            return []
        }
    }

    /// Does this tool make sense for the current drop? `merge` needs 2+, the
    /// rest work per-file.
    func applies(to formats: [Format], count: Int) -> Bool {
        guard let first = formats.first else { return false }
        // Every image tool decodes through ImageIO, which can't read SVG.
        // Convert an SVG to a raster first.
        if formats.contains(where: { $0.id == "svg" }) && self != .pdfMerge { return false }
        let cats = Set(formats.map(\.category))
        switch self {
        case .resize, .crop:
            return cats.isSubset(of: [.image, .video])
        case .compress:
            return cats.isSubset(of: [.image, .video]) || formats.allSatisfy { $0.id == "pdf" }
        case .stripMetadata:
            return cats.isSubset(of: [.image, .video, .audio]) || formats.allSatisfy { $0.id == "pdf" }
        case .trim:
            return cats.isSubset(of: [.video, .audio])
        case .ocr:
            return formats.allSatisfy { $0.category == .image } || (first.id == "pdf" && count == 1)
        case .removeBackground:
            return cats == [.image]
        case .pdfMerge:
            return count >= 2 && formats.allSatisfy { $0.id == "pdf" || $0.category == .image }
        case .pdfSplit:
            return first.id == "pdf" && count == 1
        }
    }
}

struct ToolPreset {
    let label: String
    var quality: Int?
    var scalePercent: Int?
    var maxEdge: Int?
    var aspect: String?
    var trimDuration: Double?

    init(_ label: String, quality: Int? = nil, scale: Int? = nil, maxEdge: Int? = nil,
         aspect: String? = nil, trim: Double? = nil) {
        self.label = label
        self.quality = quality
        self.scalePercent = scale
        self.maxEdge = maxEdge
        self.aspect = aspect
        self.trimDuration = trim
    }
}
