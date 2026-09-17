import AppKit
import Foundation

/// `Daisy --selftest` runs the checks that must hold for the conversion graph to
/// be coherent, then exits non-zero on any failure. XCTest isn't in the Command
/// Line Tools SDK, so tests ship in the binary and run anywhere, including CI
/// where no engines are installed.
enum SelfTest {
    private static var failures: [String] = []
    private static var passCount = 0

    private static func expect(_ cond: Bool, _ what: String) {
        if cond { passCount += 1; print("  ok   \(what)") }
        else { failures.append(what); print("  FAIL \(what)") }
    }

    private static func section(_ name: String) { print("\n\(name)") }

    static func run() -> Never {
        print("Daisy self-test\n")

        section("format resolution")
        expect(Formats.byExtension("jpeg")?.id == "jpg", "jpeg alias -> jpg")
        expect(Formats.byExtension(".PNG")?.id == "png", "case/dot-insensitive")
        expect(Formats.byExtension("tgz")?.id == "targz", "tgz alias -> targz")
        expect(Formats.byURL(URL(fileURLWithPath: "/x/a.tar.gz"))?.id == "targz", "double extension")
        expect(Formats.byURL(URL(fileURLWithPath: "/x/y.bogus")) == nil, "unknown extension -> nil")

        section("capability graph")
        let jpg = Formats.byID["jpg"]!, png = Formats.byID["png"]!
        let mp4 = Formats.byID["mp4"]!, mp3 = Formats.byID["mp3"]!, gif = Formats.byID["gif"]!
        let folder = Formats.byID["folder"]!, zip = Formats.byID["zip"]!
        expect(Engine.targets(for: jpg).contains(png), "jpg -> png offered")
        expect(!Engine.targets(for: jpg).contains(jpg), "no identity route")
        expect(Engine.targets(for: mp4).contains(mp3), "mp4 -> mp3 offered")
        expect(Engine.targets(for: mp4).contains(gif), "mp4 -> gif offered")
        expect(Engine.targets(for: folder).contains(zip), "folder -> zip offered")
        expect(Engine.targets(for: zip).contains(folder), "zip -> folder offered")
        expect(Engine.converter(from: mp4, to: mp3) is MediaConverter, "mp4->mp3 routes to MediaConverter")
        expect(Engine.converter(from: jpg, to: Formats.byID["pdf"]!) is PDFConverter, "jpg->pdf routes to PDFConverter")

        section("argument builders")
        let dummyIn = URL(fileURLWithPath: "/tmp/in.mp4")
        let dummyOut = URL(fileURLWithPath: "/tmp/out.mp3")
        if let inv = try? MediaConverter().plan(input: dummyIn, from: mp4, to: mp3,
                                                output: dummyOut, opts: ConvertOptions()) {
            expect(inv.args.contains("libmp3lame"), "mp3 plan uses libmp3lame")
            expect(inv.args.contains("-vn"), "mp3 plan drops video")
        } else { expect(false, "mp4->mp3 plan built") }

        if let inv = try? MediaConverter().plan(input: dummyIn, from: mp4, to: gif,
                                                output: URL(fileURLWithPath: "/tmp/o.gif"),
                                                opts: ConvertOptions(scale: "600x")) {
            expect(inv.args.joined().contains("palettegen"), "gif plan uses palette")
            expect(inv.args.joined().contains("scale=600"), "gif plan honors --scale")
        } else { expect(false, "mp4->gif plan built") }

        if let inv = try? ArchiveConverter().plan(input: URL(fileURLWithPath: "/tmp/dir"),
                                                  from: folder, to: zip,
                                                  output: URL(fileURLWithPath: "/tmp/dir.zip"),
                                                  opts: ConvertOptions()) {
            expect(inv.engine == .bsdtar && inv.args.contains("-a"), "folder->zip uses bsdtar -a")
        } else { expect(false, "folder->zip plan built") }

        expect((try? ArchiveConverter().plan(input: URL(fileURLWithPath: "/tmp/d"),
                                             from: folder, to: Formats.byID["rar"]!,
                                             output: URL(fileURLWithPath: "/tmp/d.rar"),
                                             opts: ConvertOptions())) == nil,
               "RAR creation is refused")

        section("output naming")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-selftest-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let srcA = tmp.appendingPathComponent("photo.png")
        FileManager.default.createFile(atPath: srcA.path, contents: Data("x".utf8))
        let o1 = Naming.output(for: srcA, target: jpg, into: nil, collision: .suffix)
        expect(o1?.lastPathComponent == "photo.jpg", "first output has no suffix")
        FileManager.default.createFile(atPath: o1!.path, contents: Data("x".utf8))
        let o2 = Naming.output(for: srcA, target: jpg, into: nil, collision: .suffix)
        expect(o2?.lastPathComponent == "photo 2.jpg", "collision bumps to ' 2'")
        expect(Naming.output(for: srcA, target: jpg, into: nil, collision: .skip) == nil, "skip returns nil when target exists")
        let srcB = tmp.appendingPathComponent("fresh.png")
        FileManager.default.createFile(atPath: srcB.path, contents: Data("x".utf8))
        expect(Naming.output(for: srcB, target: jpg, into: nil, collision: .skip) != nil, "skip returns a path when clear")
        expect(Naming.output(for: srcA, target: jpg, into: nil, collision: .overwrite)?.lastPathComponent == "photo.jpg",
               "overwrite reuses the existing name")

        section("tools & trace")
        let pdf = Formats.byID["pdf"]!, svg = Formats.byID["svg"]!
        expect(Tool.resize.applies(to: [jpg], count: 1), "resize applies to images")
        expect(!Tool.resize.applies(to: [mp3], count: 1), "resize skips audio")
        expect(Tool.trim.applies(to: [mp4], count: 1) && !Tool.trim.applies(to: [jpg], count: 1), "trim is av-only")
        expect(Tool.pdfMerge.applies(to: [pdf, pdf], count: 2) && !Tool.pdfMerge.applies(to: [pdf], count: 1),
               "pdfMerge needs 2+ pdfs")
        expect(Tool.pdfSplit.applies(to: [pdf], count: 1) && !Tool.pdfSplit.applies(to: [pdf, pdf], count: 2),
               "pdfSplit needs exactly one pdf")
        expect(Tool.compress.applies(to: [pdf], count: 1) && Tool.stripMetadata.applies(to: [pdf], count: 1),
               "pdf accepts compress + strip")
        expect(Tool.resize.presets.contains { $0.label == "½" } && Tool.compress.presets.count == 3,
               "presets populated")
        expect(Naming.toolOutput(for: URL(fileURLWithPath: "/tmp/x/a.jpg"), tag: "resized", ext: "jpg", into: nil)?
               .lastPathComponent == "a-resized.jpg", "tool output name")

        expect(Engine.targets(for: jpg).contains(svg), "jpg -> svg (trace) offered")
        if let inv = try? ImageConverter().plan(input: URL(fileURLWithPath: "/tmp/a.jpg"), from: jpg, to: svg,
                                                output: URL(fileURLWithPath: "/tmp/a.svg"), opts: ConvertOptions()) {
            expect(inv.engine == .potrace && inv.rasterizeInputToPGM && inv.args.contains("{PGM}"),
                   "trace plan feeds potrace a PGM")
        } else { expect(false, "jpg->svg plan built") }

        section("documents")
        expect(Formats.byID["pptx"] != nil && Formats.byID["xlsx"] != nil, "office formats registered")
        let md = Formats.byID["md"]!
        expect(Engine.targets(for: md).map(\.id).contains("docx"), "md -> docx offered")
        expect(Engine.targets(for: md).map(\.id).contains("pdf"), "md -> pdf offered")
        expect(Engine.targets(for: pdf).map(\.id).contains("txt"), "pdf -> txt offered")
        expect(Engine.converter(from: md, to: pdf) is DocConverter, "md->pdf routes to DocConverter")
        expect(Engine.converter(from: md, to: Formats.byID["html"]!) is DocConverter, "md->html routes to DocConverter")
        // `execute` is a protocol requirement so a call through the `Converter`
        // existential dispatches to DocConverter, not the no-op extension default.
        expect(Engine.converters.contains { type(of: $0) == DocConverter.self }, "DocConverter is registered")

        section("presets · recipes · tools")
        expect(Presets.named("web-jpg")?.target == "jpg", "preset lookup")
        expect(Presets.named("web-jpg")?.options.quality == 80 && Presets.named("web-jpg")?.options.stripMetadata == true,
               "preset -> options")
        expect(Presets.all().count >= Presets.builtins.count, "presets merge includes builtins")
        expect(Recipes.named("web-image")?.steps.count == 3, "recipe lookup")
        if let r = Recipes.named("square-jpg"),
           let data = try? JSONEncoder().encode(r),
           let back = try? JSONDecoder().decode(Recipe.self, from: data) {
            expect(back.steps.count == r.steps.count && back.steps.last?.to == "jpg", "recipe json round-trips")
        } else { expect(false, "recipe json round-trips") }
        expect(Tool.ocr.outputExt == "pdf" && Tool.removeBackground.outputExt == "png", "tool fixed output types")
        expect(Tool.ocr.applies(to: [png], count: 1) && !Tool.ocr.applies(to: [mp3], count: 1), "ocr applies to images")
        expect(Tool.removeBackground.applies(to: [jpg], count: 1) && !Tool.removeBackground.applies(to: [pdf], count: 1),
               "remove-bg is image-only")
        if let data = try? JSONEncoder().encode(WatchRule(folder: "/tmp/x", toFormat: "webp")),
           let back = try? JSONDecoder().decode(WatchRule.self, from: data) {
            expect(back.folder == "/tmp/x" && back.toFormat == "webp" && back.enabled, "watch rule json round-trips")
        } else { expect(false, "watch rule json round-trips") }

        section("architecture gate")
        // The running binary always matches the host, so this is the honest fixture.
        expect(EngineLocator.runnable(CommandLine.arguments[0]), "our own binary reads as runnable")
        expect(!EngineLocator.runnable("/nonexistent/engine"), "missing file isn't runnable")
        expect(EngineLocator.runnable("/usr/bin/bsdtar"), "a system Mach-O reads as runnable")
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("daisy-arch-\(UUID().uuidString).sh")
        try? "#!/bin/sh\necho hi\n".write(to: script, atomically: true, encoding: .utf8)
        expect(EngineLocator.runnable(script.path), "non-Mach-O script is left to the OS")
        try? FileManager.default.removeItem(at: script)

        section("folder drops")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("daisy-inputset-\(UUID().uuidString)")
        let photos = root.appendingPathComponent("photos")
        try? fm.createDirectory(at: photos.appendingPathComponent("nested"), withIntermediateDirectories: true)
        for n in ["b.png", "a.png", "c.jpg"] {
            fm.createFile(atPath: photos.appendingPathComponent(n).path, contents: Data("x".utf8))
        }
        fm.createFile(atPath: photos.appendingPathComponent(".hidden.png").path, contents: Data("x".utf8))
        fm.createFile(atPath: photos.appendingPathComponent("notes.qqq").path, contents: Data("x".utf8))
        fm.createFile(atPath: photos.appendingPathComponent("nested/deep.png").path, contents: Data("x".utf8))

        let expanded = InputSet.expand([photos])
        expect(expanded.folder == photos, "a folder of images remembers the folder")
        expect(expanded.files.count == 3, "only the convertible top-level files are taken")
        expect(expanded.files.map(\.lastPathComponent) == ["a.png", "b.png", "c.jpg"].sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }, "expanded files come back in name order")
        expect(!expanded.files.contains { $0.lastPathComponent.hasPrefix(".") }, "hidden files are skipped")
        expect(!expanded.files.contains { $0.pathExtension == "qqq" }, "unknown extensions are skipped")
        expect(!expanded.files.contains { $0.lastPathComponent == "nested" }, "subfolders never become inputs")

        let empty = root.appendingPathComponent("empty")
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let noRoutes = InputSet.expand([empty])
        expect(noRoutes.folder == nil && noRoutes.files == [empty],
               "a folder with nothing convertible stays a folder")

        let plain = photos.appendingPathComponent("a.png")
        expect(InputSet.expand([plain]).folder == nil, "a plain file expands to itself")
        expect(InputSet.expand([plain, photos]).files.count == 2, "a mixed multi-drop is left alone")
        try? fm.removeItem(at: root)

        section("combine")
        let cPng = Formats.byID["png"]!, cJpg = Formats.byID["jpg"]!
        let cPdf = Formats.byID["pdf"]!, cMp3 = Formats.byID["mp3"]!
        expect(Combine.offered(to: cPdf, from: [cPng, cJpg], count: 2),
               "two images offer one-PDF or separate")
        expect(Combine.offered(to: cPdf, from: [cPng, cPdf, cJpg], count: 3),
               "images mixed with PDFs still combine")
        expect(!Combine.offered(to: cPdf, from: [cPng], count: 1),
               "a single file has nothing to decide")
        expect(!Combine.offered(to: cPdf, from: [cPng, cMp3], count: 2),
               "an audio file in the set rules out one PDF")
        expect(!Combine.offered(to: cJpg, from: [cPng, cPng], count: 2),
               "only formats that can hold several inputs ask")
        expect(!Combine.offered(to: cPdf, from: [cPng], count: 2),
               "a set with an unrecognised file never combines")
        // Page order has to come from the names: a multi-file drop arrives in
        // the source app's order, which for Finder is invisible selection order.
        let mixed = ["img10.png", "img2.png", "img1.png"].map { URL(fileURLWithPath: "/tmp/\($0)") }
        expect(Combine.ordered(mixed).map(\.lastPathComponent) == ["img1.png", "img2.png", "img10.png"],
               "merge order is natural, so img2 precedes img10")

        section("updates")
        expect(Updater.isNewer("0.8.0", than: "0.7.1"), "0.8.0 is newer than 0.7.1")
        expect(Updater.isNewer("0.10.0", than: "0.9.0"), "0.10.0 is newer than 0.9.0 (numeric, not lexical)")
        expect(!Updater.isNewer("0.7.1", than: "0.7.1"), "the same version is not an update")
        expect(!Updater.isNewer("0.7.0", than: "0.7.1"), "an older version is not an update")
        expect(Updater.isNewer("1.0", than: "0.9.9"), "a shorter version still compares correctly")
        // The release JSON is attacker-controlled if GitHub is ever
        // compromised, so every URL taken from it is checked, not trusted.
        expect(Updater.isTrusted(URL(string: "https://github.com/ishanmalu/daisy/releases")!),
               "github.com over https is trusted")
        expect(Updater.isTrusted(URL(string: "https://objects.githubusercontent.com/x.dmg")!),
               "the release asset host is trusted")
        expect(!Updater.isTrusted(URL(string: "http://github.com/x.dmg")!), "plain http is refused")
        expect(!Updater.isTrusted(URL(string: "https://evil.example.com/x.dmg")!),
               "an unknown host is refused")
        expect(!Updater.isTrusted(URL(string: "https://github.com.evil.example/x.dmg")!),
               "a lookalike host is refused")
        // Ad-hoc builds pin their own code hash, so they can never accept an
        // update in place. That is the right answer, and worth asserting.
        expect(!UpdateInstaller.probeRequirement(Bundle.main.bundleURL)
               || UpdateInstaller.canInstallInPlace,
               "in-place install is only ever offered when the signature matches")

        section("menu bar")
        let delegate = AppDelegate()
        let menu = delegate.makeMenu()
        expect(menu.items.contains { $0.title.hasPrefix("Quit") }, "the menu offers a way to quit")
        for item in menu.items where item.action != nil {
            // AppKit silently greys out an item whose target cannot perform its
            // action, which is exactly how Quit broke: it was wired straight to
            // NSApplication.terminate and then re-targeted at the delegate.
            let ok = (item.target as? NSObject)?.responds(to: item.action!) ?? false
            expect(ok, "menu item \(item.title.trimmingCharacters(in: .whitespaces)) can fire its action")
        }

        section("engine availability (informational)")
        for id in [EngineID.ffmpeg, .vips, .cwebp, .resvg, .potrace, .pandoc, .qpdf, .sevenzip, .unar, .bsdtar, .exiftool] {
            let where_ = EngineLocator.path(for: id) ?? "— not found (bundle or brew install)"
            print("  \(id.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(where_)")
        }

        print("")
        if failures.isEmpty {
            print("PASS — \(passCount) checks")
            exit(0)
        } else {
            print("FAIL — \(failures.count) of \(passCount + failures.count):")
            failures.forEach { print("  - \($0)") }
            exit(1)
        }
    }
}
