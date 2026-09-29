import Foundation

/// Audio and video via ffmpeg. Also owns video→GIF (palettegen/paletteuse).
struct MediaConverter: Converter {
    static let video: Set<String> = ["mp4", "mov", "mkv", "webm", "avi", "m4v"]
    static let audio: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "ogg", "opus", "aiff"]

    func targets(for input: Format) -> [Format] {
        switch input.category {
        case .video:
            var t = Self.video.union(Self.audio)
            t.insert("gif")
            t.remove(input.id)
            return t.compactMap { Formats.byID[$0] }
        case .audio:
            var t = Self.audio
            t.remove(input.id)
            return t.compactMap { Formats.byID[$0] }
        default:
            return []
        }
    }

    func plan(input: URL, from: Format, to: Format, output: URL, opts: ConvertOptions) throws -> Invocation {
        var a = ["-hide_banner", "-loglevel", "error", "-y", "-i", input.path]

        if to.id == "gif" {
            let w = opts.scaleWidth ?? 480
            let fps = 12
            a += ["-vf",
                  "fps=\(fps),scale=\(w):-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse",
                  "-loop", "0", output.path]
            return Invocation(engine: .ffmpeg, args: a)
        }

        if Self.audio.contains(to.id) {
            a += ["-vn"]
            switch to.id {
            case "mp3":  a += ["-c:a", "libmp3lame", "-q:a", String(lameV(opts.quality))]
            case "m4a", "aac": a += ["-c:a", "aac", "-b:a", "\(kbps(opts.quality, default: 192))k"]
            case "wav":  a += ["-c:a", "pcm_s16le"]
            case "flac": a += ["-c:a", "flac"]
            case "ogg":  a += ["-c:a", "libvorbis", "-q:a", "5"]
            case "opus": a += ["-c:a", "libopus", "-b:a", "\(kbps(opts.quality, default: 128))k"]
            case "aiff": a += ["-c:a", "pcm_s16be"]
            default: break
            }
            a += [output.path]
            return Invocation(engine: .ffmpeg, args: a)
        }

        // video → video
        switch to.id {
        case "webm":
            a += ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", String(vp9CRF(opts.quality)),
                  "-c:a", "libopus", "-b:a", "128k"]
        default:
            a += ["-c:v", "libx264", "-crf", String(x264CRF(opts.quality)),
                  "-preset", "medium", "-pix_fmt", "yuv420p",
                  "-c:a", "aac", "-b:a", "160k"]
        }
        // yuv420p needs even dimensions, and screen recordings are often odd.
        if let w = opts.scaleWidth {
            a += ["-vf", "scale=\(max(2, w - w % 2)):-2"]
        } else {
            a += ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2"]
        }
        a += ["-movflags", "+faststart", output.path]
        return Invocation(engine: .ffmpeg, args: a)
    }

    // quality 1...100 → codec-native knobs. nil == a sensible default.
    private func x264CRF(_ q: Int?) -> Int {
        guard let q else { return 23 }
        return max(14, min(34, 34 - Int((Double(q) / 100.0) * 20)))
    }
    private func vp9CRF(_ q: Int?) -> Int {
        guard let q else { return 32 }
        return max(15, min(46, 46 - Int((Double(q) / 100.0) * 31)))
    }
    private func lameV(_ q: Int?) -> Int {
        guard let q else { return 2 }
        return max(0, min(9, 9 - Int((Double(q) / 100.0) * 9)))
    }
    private func kbps(_ q: Int?, default def: Int) -> Int {
        guard let q else { return def }
        return max(64, min(320, Int((Double(q) / 100.0) * 320)))
    }
}
