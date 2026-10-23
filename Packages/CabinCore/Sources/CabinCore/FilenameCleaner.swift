import Foundation

public enum FilenameCleaner {
    /// Best-effort artist/title guess from a messy downloaded filename.
    /// Handles leading track numbers, underscores, and "(Official Audio)"-style junk.
    public static func parse(_ raw: String) -> (artist: String?, title: String) {
        var s = raw

        // Underscores/dots → spaces.
        s = s.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: ".", with: " ")

        // Strip bracketed / parenthesised junk: (Official Video), [HQ], {Audio}…
        s = s.replacingOccurrences(of: #"[\(\[\{][^\)\]\}]*[\)\]\}]"#, with: " ",
                                   options: .regularExpression)

        // Strip common quality/junk tokens.
        for junk in ["official video", "official audio", "lyric video", "audio", "hd", "hq",
                     "320kbps", "320 kbps", "128kbps", "free download", "youtube"] {
            s = s.replacingOccurrences(of: junk, with: " ",
                                       options: [.regularExpression, .caseInsensitive])
        }

        // Leading track number: "01 - ", "01. ", "1) ", "01 "
        s = s.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-.\)]?\s+"#, with: "",
                                   options: .regularExpression)

        // Collapse whitespace.
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // "Artist - Title" split (first dash wins).
        if let dash = s.range(of: " - ") {
            let artist = String(s[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces)
            let title = String(s[dash.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !artist.isEmpty && !title.isEmpty { return (artist, title) }
        }
        return (nil, s.isEmpty ? raw : s)
    }

    /// Clean a per-track title taken from a filename: strip a leading track
    /// number ("01 ", "1. ", "03 - ") and tidy separators, but keep the rest of
    /// the title intact (no artist split, no junk-token removal). Used for the
    /// track list of multi-file albums, e.g. Apple Music exports named "01 …".
    public static func trackTitle(_ raw: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        s = s.replacingOccurrences(of: #"^\s*\d{1,3}\s*[-.\)]?\s+"#, with: "",
                                   options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? raw : s
    }

    /// Like `trackTitle`, but first strips a known "Artist - " and/or "Album - " prefix that
    /// Bandcamp bakes into its downloaded filenames ("Artist - Album - 01 Title.flac"), so the
    /// track list shows just "Title" instead of the whole filename.
    public static func trackTitle(_ raw: String, artist: String, album: String) -> String {
        var s = raw.replacingOccurrences(of: "_", with: " ")
        // Peel a leading "Artist - " then "Album - " (case-insensitive, common dash variants).
        for prefix in [artist, album] {
            let p = prefix.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            for sep in [" - ", " – ", " — "] {
                let cand = p + sep
                if s.count > cand.count, s.lowercased().hasPrefix(cand.lowercased()) {
                    s = String(s.dropFirst(cand.count))
                    break
                }
            }
        }
        return trackTitle(s)
    }
}
