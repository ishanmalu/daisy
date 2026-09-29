import Foundation

/// `~/Library/Application Support/Daisy` — config (presets, recipes, watch
/// folders) and on-demand engines live here.
enum Support {
    static var dir: URL {
        let u = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Daisy", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    static func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    static func loadJSON<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func saveJSON<T: Encodable>(_ value: T, to name: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(value) { try? data.write(to: file(name), options: .atomic) }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
