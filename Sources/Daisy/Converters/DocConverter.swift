import Foundation
import PDFKit

/// Documents. pandoc covers the text formats and Office round-trips it knows;
/// LibreOffice (bring-your-own) does high-fidelity Office ↔ PDF. PDF → text is
/// native (PDFKit). Multi-step routes (e.g. Markdown → PDF = pandoc → odt →
/// soffice → pdf) run here rather than through a single `Invocation`.
struct DocConverter: Converter {
    static let pandocText = ["md", "html", "rtf", "txt", "epub", "docx", "odt"]
    static let office     = ["docx", "odt", "rtf", "pptx", "xlsx", "odp", "ods"]

    func targets(for input: Format) -> [Format] {
        guard input.category == .document else { return [] }
        switch input.id {
        case "md", "html", "rtf", "txt", "epub", "docx", "odt":
            var t = Set(Self.pandocText); t.insert("pdf"); t.remove(input.id)
            return t.compactMap { Formats.byID[$0] }
        case "pptx", "odp", "xlsx", "ods":
            return ["pdf"].compactMap { Formats.byID[$0] }
        case "pdf":
            return ["txt", "docx"].compactMap { Formats.byID[$0] }
        default:
            return []
        }
    }

    func plan(input: URL, from: Format, to: Format, output: URL, opts: ConvertOptions) throws -> Invocation {
        throw ConvertError.unsupported(from: from.id, to: to.id)   // handled by execute()
    }

    func execute(input: URL, from: Format, to: Format, output: URL, opts: ConvertOptions) throws -> Bool {
        // PDF → text: no engine needed.
        if from.id == "pdf", to.id == "txt" {
            guard let doc = PDFDocument(url: input) else {
                throw ConvertError.badInput("Couldn't open PDF: \(input.lastPathComponent)")
            }
            try (doc.string ?? "").write(to: output, atomically: true, encoding: .utf8)
            return true
        }

        // PDF → docx: LibreOffice's PDF import only.
        if from.id == "pdf", to.id == "docx" {
            try soffice(input, toExt: "docx", filter: "MS Word 2007 XML", finalOutput: output)
            return true
        }

        // Anything → PDF.
        if to.id == "pdf" {
            if Self.office.contains(from.id) || from.id == "html" || from.id == "txt" || from.id == "rtf" {
                try soffice(input, toExt: "pdf", filter: nil, finalOutput: output)
            } else {
                // md / epub → intermediate .odt via pandoc, then soffice → pdf
                let mid = tmp("odt")
                defer { try? FileManager.default.removeItem(at: mid) }
                try pandoc(input, to: mid)
                try soffice(mid, toExt: "pdf", filter: nil, finalOutput: output)
            }
            return true
        }

        // Text ↔ text / Office (pandoc's wheelhouse).
        try pandoc(input, to: output)
        return true
    }

    // MARK: engines

    private func tmp(_ ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("daisy-\(UUID().uuidString).\(ext)")
    }

    private func pandoc(_ input: URL, to output: URL) throws {
        guard let bin = EngineLocator.path(for: .pandoc) else { throw ConvertError.engineMissing(.pandoc) }
        // pandoc guesses the writer from the extension, and guesses badly for
        // two of ours: .txt means markdown to it, and .md means pandoc's own
        // dialect, full of ::: fenced divs. RTF and HTML without -s are
        // fragments — no {\rtf1 header, no <html> — that nothing else opens.
        var a = [input.path, "-o", output.path]
        switch output.pathExtension.lowercased() {
        case "txt":  a += ["-t", "plain"]
        case "md":   a += ["-t", "gfm"]
        case "rtf", "html": a += ["-s"]
        default: break
        }
        if output.pathExtension.lowercased() == "html" || output.pathExtension.lowercased() == "epub" {
            // Standalone HTML/EPUB warn and fall back without a title.
            a += ["--metadata", "pagetitle=\(Naming.strippedStem(of: input))"]
        }
        let r = ProcessRun.run(bin, a, cwd: FileManager.default.temporaryDirectory, timeout: 120)
        if r.code != 0 {
            throw ConvertError.processFailed(code: r.code, message: String((r.stderr.isEmpty ? r.stdout : r.stderr).suffix(500)))
        }
    }

    /// soffice writes `<inputStem>.<toExt>` into its --outdir; we move it to `finalOutput`.
    private func soffice(_ input: URL, toExt: String, filter: String?, finalOutput: URL) throws {
        guard let bin = EngineLocator.libreOffice() else { throw ConvertError.engineMissing(.libreoffice) }
        let outDir = FileManager.default.temporaryDirectory.appendingPathComponent("daisy-lo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outDir) }

        let convertTo = filter.map { "\(toExt):\($0)" } ?? toExt
        let profile = "-env:UserInstallation=file://" + outDir.appendingPathComponent("profile").path
        let r = ProcessRun.run(bin, ["--headless", "--norestore", profile,
                                     "--convert-to", convertTo, "--outdir", outDir.path, input.path],
                               timeout: 300)
        if r.code != 0 {
            throw ConvertError.processFailed(code: r.code, message: String((r.stderr.isEmpty ? r.stdout : r.stderr).suffix(500)))
        }
        let produced = outDir.appendingPathComponent(input.deletingPathExtension().lastPathComponent)
            .appendingPathExtension(toExt)
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw ConvertError.processFailed(code: 0, message: "LibreOffice produced no \(toExt) file")
        }
        try? FileManager.default.removeItem(at: finalOutput)
        try FileManager.default.moveItem(at: produced, to: finalOutput)
    }
}
