import Foundation

/// Whether a set of inputs can be folded into a single file of some target
/// format, rather than converted one by one.
///
/// Dropping three photos and asking for PDF is genuinely ambiguous — three
/// PDFs, or one PDF of three pages? Daisy has always been able to do both (the
/// second lives under ⌥ as Merge PDF) but the Convert wheel quietly assumed
/// the first. This is the rule the wheel uses to decide when it has to ask.
enum Combine {
    /// Page order for a merge. Filenames sort naturally — `img2` before
    /// `img10` — because a multi-file drop arrives in whatever order the
    /// source app handed over, which for Finder is selection order and not
    /// something anyone can see or control.
    static func ordered(_ urls: [URL]) -> [URL] {
        urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// True when `target` can absorb every one of `formats` into one file.
    /// Needs at least two inputs — with one there is nothing to decide.
    static func offered(to target: Format, from formats: [Format], count: Int) -> Bool {
        guard count >= 2, formats.count == count else { return false }
        switch target.id {
        case "pdf":
            // PDFKit lays images out a page each and appends the pages of any
            // PDFs already in the set.
            return formats.allSatisfy { $0.category == .image || $0.id == "pdf" }
        default:
            return false
        }
    }
}
