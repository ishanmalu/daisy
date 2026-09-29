import Foundation

/// `Daisy convert …`, `Daisy formats`, `Daisy info <file>`. Shares the exact
/// conversion path the GUI uses, so anything the app can do is scriptable.
enum CLI {
    static func run(_ args: [String]) -> Int32 {
        guard let cmd = args.first else { usage(); return 2 }
        switch cmd {
        case "formats":            return formats()
        case "info":               return info(Array(args.dropFirst()))
        case "convert":            return convert(Array(args.dropFirst()))
        case "tool":               return tool(Array(args.dropFirst()))
        case "merge":              return tool(["pdfMerge"] + args.dropFirst())
        case "split":              return tool(["pdfSplit"] + args.dropFirst())
        case "recipe":             return recipe(Array(args.dropFirst()))
        case "watch":              return watch(Array(args.dropFirst()))
        case "presets":            return listNamed(Presets.all().map { "\($0.name)  → \($0.target.uppercased())" })
        case "recipes":            return listNamed(Recipes.all().map { "\($0.name)  (\($0.steps.count) steps)" })
        case "-h", "--help", "help": usage(); return 0
        default:
            err("unknown command: \(cmd)")
            usage()
            return 2
        }
    }

    // MARK: convert

    private static func convert(_ args: [String]) -> Int32 {
        var inputs: [URL] = []
        var toID: String?
        var outDir: URL?
        var explicitOut: URL?
        var opts = ConvertOptions()
        var collision = Collision.suffix

        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "--to", "-t":
                i += 1; toID = i < args.count ? args[i] : nil
            case "--out", "-o":
                i += 1
                if i < args.count { outDir = URL(fileURLWithPath: args[i], isDirectory: true) }
            case "--quality", "-q":
                i += 1; opts.quality = i < args.count ? Int(args[i]) : nil
            case "--scale", "-s":
                i += 1; opts.scale = i < args.count ? args[i] : nil
            case "--strip":       opts.stripMetadata = true
            case "--overwrite":   collision = .overwrite
            case "--skip-existing": collision = .skip
            case "--preset", "-p":
                i += 1
                guard i < args.count, let preset = Presets.named(args[i]) else {
                    err("unknown preset: \(i < args.count ? args[i] : "")"); return 2
                }
                toID = toID ?? preset.target
                opts.quality = opts.quality ?? preset.quality
                opts.scale = opts.scale ?? preset.scale
                if preset.strip { opts.stripMetadata = true }
            default:
                inputs.append(URL(fileURLWithPath: a))
            }
            i += 1
        }

        // Two-positional form with no --to: `daisy convert in.png out.webp`
        if toID == nil, inputs.count == 2,
           let outFmt = Formats.byURL(inputs[1]) ?? Formats.byExtension(inputs[1].pathExtension),
           !FileManager.default.fileExists(atPath: inputs[1].path) {
            explicitOut = inputs.removeLast()
            toID = outFmt.id
        }

        guard !inputs.isEmpty else { err("no input files"); return 2 }
        guard let toID, let target = Formats.byExtension(toID) ?? Formats.byID[toID] else {
            err("missing or unknown --to format"); return 2
        }

        var failures = 0
        for input in inputs {
            guard FileManager.default.fileExists(atPath: input.path) else {
                err("not found: \(input.path)"); failures += 1; continue
            }
            let output = explicitOut
                ?? Naming.output(for: input, target: target, into: outDir, collision: collision)
            guard let output else {
                print("skip  \(input.lastPathComponent) (exists)"); continue
            }
            do {
                let written = try Engine.run(input: input, to: target, output: output, opts: opts)
                print("ok    \(input.lastPathComponent)  ->  \(written.path)")
            } catch {
                err("fail  \(input.lastPathComponent): \(error.localizedDescription)")
                failures += 1
            }
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: tool

    private static func tool(_ args: [String]) -> Int32 {
        guard let name = args.first,
              let t = Tool.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() || $0.label.lowercased() == name.lowercased() }) else {
            err("usage: daisy tool <\(Tool.allCases.map(\.rawValue).joined(separator: "|"))> <files…> [--preset L] [--quality N] [--scale PCT] [--max-edge N] [--aspect A:B] [--seconds S] [--out DIR]")
            return 2
        }
        var inputs: [URL] = []
        var p = ToolRunner.Params()
        var presetLabel: String?
        var i = 1
        while i < args.count {
            let a = args[i]
            func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
            switch a {
            case "--preset":    presetLabel = next()
            case "--quality":   p.quality = next().flatMap(Int.init)
            case "--scale":     p.scalePercent = next().flatMap(Int.init)
            case "--max-edge":  p.maxEdge = next().flatMap(Int.init)
            case "--aspect":    p.aspect = next()
            case "--seconds":   p.trimDuration = next().flatMap(Double.init)
            case "--out", "-o": p.into = next().map { URL(fileURLWithPath: $0, isDirectory: true) }
            case "--overwrite": p.collision = .overwrite
            default:            inputs.append(URL(fileURLWithPath: a))
            }
            i += 1
        }
        if let label = presetLabel, let pre = t.presets.first(where: { $0.label.lowercased() == label.lowercased() }) {
            let merged = ToolRunner.Params(preset: pre)
            p.quality = p.quality ?? merged.quality
            p.scalePercent = p.scalePercent ?? merged.scalePercent
            p.maxEdge = p.maxEdge ?? merged.maxEdge
            p.aspect = p.aspect ?? merged.aspect
            p.trimDuration = p.trimDuration ?? merged.trimDuration
        }
        guard !inputs.isEmpty else { err("no input files"); return 2 }
        for u in inputs where !FileManager.default.fileExists(atPath: u.path) {
            err("not found: \(u.path)"); return 2
        }
        do {
            let outs = try ToolRunner.run(t, inputs: inputs, params: p)
            outs.forEach { print("ok    \($0.path)") }
            return 0
        } catch {
            err("fail  \(error.localizedDescription)")
            return 1
        }
    }

    // MARK: recipe

    private static func recipe(_ args: [String]) -> Int32 {
        guard let name = args.first, let r = Recipes.named(name) else {
            err("usage: daisy recipe <name> <files…> [--out <dir>]   (see: daisy recipes)")
            return 2
        }
        var into: URL?
        var inputs: [URL] = []
        var i = 1
        while i < args.count {
            if args[i] == "--out" || args[i] == "-o" { i += 1; if i < args.count { into = URL(fileURLWithPath: args[i], isDirectory: true) } }
            else { inputs.append(URL(fileURLWithPath: args[i])) }
            i += 1
        }
        guard !inputs.isEmpty else { err("no input files"); return 2 }
        var failures = 0
        for input in inputs {
            guard FileManager.default.fileExists(atPath: input.path) else { err("not found: \(input.path)"); failures += 1; continue }
            do {
                let out = try RecipeRunner.run(r, input: input, into: into)
                print("ok    \(input.lastPathComponent)  ->  \(out.path)")
            } catch {
                err("fail  \(input.lastPathComponent): \(error.localizedDescription)"); failures += 1
            }
        }
        return failures == 0 ? 0 : 1
    }

    // MARK: watch

    private static func watch(_ args: [String]) -> Int32 {
        let w = WatchFolders.shared
        w.load()
        switch args.first {
        case "list", nil:
            if w.rules.isEmpty { print("no watch folders") }
            for (i, r) in w.rules.enumerated() {
                let action = r.recipe.map { "recipe \($0)" } ?? r.toFormat.map { "→ \($0.uppercased())" } ?? "?"
                print("\(i)  \(r.enabled ? "●" : "○")  \(r.folder)  \(action)")
            }
            return 0
        case "add":
            let rest = Array(args.dropFirst())
            var rule = WatchRule(folder: "")
            var i = 0
            while i < rest.count {
                switch rest[i] {
                case "--to":      i += 1; rule.toFormat = rest[safe: i]
                case "--recipe":  i += 1; rule.recipe = rest[safe: i]
                case "--quality": i += 1; rule.quality = rest[safe: i].flatMap(Int.init)
                default:          rule.folder = URL(fileURLWithPath: (rest[i] as NSString).expandingTildeInPath).standardizedFileURL.path
                }
                i += 1
            }
            guard !rule.folder.isEmpty, (rule.toFormat != nil || rule.recipe != nil) else {
                err("usage: daisy watch add <dir> (--to <fmt> | --recipe <name>) [--quality N]"); return 2
            }
            w.add(rule)
            print("watching \(rule.folder)")
            return 0
        case "remove", "rm":
            guard let n = args.dropFirst().first.flatMap(Int.init) else { err("usage: daisy watch remove <index>"); return 2 }
            w.remove(at: n); print("removed \(n)"); return 0
        case "run":
            w.sweepAll(); print("swept \(w.rules.count) folder(s)"); return 0
        default:
            err("usage: daisy watch [list | add <dir> --to <fmt> | remove <n> | run]"); return 2
        }
    }

    private static func listNamed(_ lines: [String]) -> Int32 {
        lines.forEach { print($0) }
        return 0
    }

    // MARK: formats / info

    private static func formats() -> Int32 {
        for cat in Category.allCases {
            let fs = Formats.list.filter { $0.category == cat && $0.id != "folder" }
            print("\n\(cat.rawValue.uppercased())")
            for f in fs {
                let outs = Engine.targets(for: f).map(\.label).joined(separator: " ")
                print("  \(f.label.padding(toLength: 8, withPad: " ", startingAt: 0)) -> \(outs)")
            }
        }
        return 0
    }

    private static func info(_ args: [String]) -> Int32 {
        guard let path = args.first else { err("usage: daisy info <file>"); return 2 }
        let url = URL(fileURLWithPath: path)
        guard let f = Formats.byURL(url) else { err("unrecognized: \(path)"); return 1 }
        print("\(url.lastPathComponent)")
        print("  format   \(f.label)  (\(f.category.rawValue))")
        print("  convert  \(Engine.targets(for: f).map(\.label).joined(separator: ", "))")
        return 0
    }

    private static func usage() {
        print("""
        Daisy — local file converter

          daisy convert <files…> --to <format> [--out <dir>] [--quality 1-100]
                       [--scale WxH] [--strip] [--overwrite | --skip-existing]
          daisy convert <in> <out>          two-file form, target inferred from <out>

          daisy tool <name> <files…>        same-format edits — name is one of:
                       resize | compress | crop | stripMetadata | trim | pdfMerge | pdfSplit
                       [--preset L] [--quality N] [--scale PCT] [--max-edge N]
                       [--aspect A:B] [--seconds S] [--out <dir>]
          daisy merge <pdfs/images…>        alias for: tool pdfMerge
          daisy split <file.pdf>            alias for: tool pdfSplit

          daisy recipe <name> <files…>      run a saved multi-step pipeline
          daisy recipes                     list recipes
          daisy convert … --preset <name>   apply a saved preset
          daisy presets                     list presets

          daisy watch add <dir> --to <fmt>  auto-convert new files in <dir>
          daisy watch [list | remove <n> | run]

          daisy formats                     what converts to what
          daisy info <file>                 identify a file and its routes
        """)
    }

    private static func err(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}
