import Foundation

/// A track to add to the iPod's database (the audio file has already been copied into
/// `iPod_Control/Music/…`; `location` is its iPod-style path, e.g. ":iPod_Control:Music:F00:AB12.m4a").
struct IPodNewTrack {
    var title: String
    var artist: String
    var album: String
    var genre: String
    var durationMs: Int
    var sizeBytes: Int
    var location: String
}

/// Appends tracks to an existing `iTunesDB` in memory — a faithful Swift port of a byte-for-byte
/// prototype validated against the real device DB. Reuses templates from the existing file (mhit
/// header + master-playlist mhip) so it matches whatever iTunes version wrote it, patches every
/// container length, updates both master playlists, and re-stamps the hash58 checksum.
///
/// It does NOT update the album-browse index (mhla); added tracks still appear under Songs and in
/// the master playlists. Always call on a backed-up copy.
enum IPodWriter {
    // little-endian helpers (bounds-checked — the DB comes off an untrusted device)
    private static func u32(_ d: [UInt8], _ o: Int) -> Int {
        guard o >= 0, o+4 <= d.count else { return 0 }
        return Int(d[o]) | Int(d[o+1])<<8 | Int(d[o+2])<<16 | Int(d[o+3])<<24
    }
    private static func setU32(_ d: inout [UInt8], _ o: Int, _ v: Int) {
        guard o >= 0, o+4 <= d.count else { return }
        d[o] = UInt8(v & 0xFF); d[o+1] = UInt8((v>>8) & 0xFF)
        d[o+2] = UInt8((v>>16) & 0xFF); d[o+3] = UInt8((v>>24) & 0xFF)
    }
    /// A safe copy of `d[o..<o+len]`, or nil if that range is out of bounds.
    private static func slice(_ d: [UInt8], _ o: Int, _ len: Int) -> [UInt8]? {
        guard o >= 0, len > 0, o+len <= d.count else { return nil }
        return Array(d[o..<o+len])
    }

    /// Offsets of the master playlists, found STRUCTURALLY (walk mhbd → playlist mhsd (index
    /// 2/3) → mhlp → its mhyp children) rather than scanning raw bytes for "mhyp" (which could
    /// match binary track data). A master has the master flag (@0x14 == 1) and holds every song.
    private static func masterPlaylists(in d: [UInt8], songCount: Int) -> [Int] {
        var result: [Int] = []
        let numChildren = u32(d, 0x14)
        var p = u32(d, 4)
        for _ in 0..<numChildren {
            guard tag(d, p) == "mhsd" else { break }
            let idx = u32(d, p+12)
            if idx == 2 || idx == 3 {
                let mhlp = p + u32(d, p+4)
                if tag(d, mhlp) == "mhlp" {
                    let numPl = u32(d, mhlp+8)
                    var y = mhlp + u32(d, mhlp+4)
                    for _ in 0..<numPl {
                        guard tag(d, y) == "mhyp" else { break }
                        if u32(d, y+16) == songCount && u32(d, y+20) == 1 { result.append(y) }
                        y += u32(d, y+8)
                    }
                }
            }
            p += u32(d, p+8)
        }
        return result
    }
    private static func tag(_ d: [UInt8], _ o: Int) -> String? {
        guard o+4 <= d.count else { return nil }
        return String(bytes: d[o..<o+4], encoding: .ascii)
    }
    private static let MHOD: [UInt8] = Array("mhod".utf8)

    /// Build a string mhod (type < 50): 24-byte header, 16-byte string sub-header, UTF-16LE bytes.
    private static func stringMhod(type: Int, _ s: String) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 40)
        b[0..<4] = MHOD[0..<4]
        setU32(&b, 4, 24)                       // header_len
        setU32(&b, 12, type)                    // type
        setU32(&b, 24, 1)                       // position
        let enc = Array(s.data(using: .utf16LittleEndian) ?? Data())
        setU32(&b, 28, enc.count)               // string byte length
        setU32(&b, 32, 1)                       // encoding flag
        setU32(&b, 8, 40 + enc.count)           // total_len
        return b + enc
    }

    /// Append `tracks`. Returns the new DB bytes, or nil if the DB couldn't be understood.
    static func append(tracks: [IPodNewTrack], to original: [UInt8], serial: String) -> [UInt8]? {
        guard !tracks.isEmpty, original.count > 0x6c, tag(original, 0) == "mhbd" else { return nil }
        var d = original

        // Walk mhbd → mhsd children; locate the track-list (type 1) mhsd + its mhlt.
        let mhbdHeader = u32(d, 4)
        let numChildren = u32(d, 0x14)
        var trackMhsd = -1
        var p = mhbdHeader
        for _ in 0..<numChildren {
            guard tag(d, p) == "mhsd" else { break }
            if u32(d, p+12) == 1 { trackMhsd = p; break }
            p += u32(d, p+8)
        }
        guard trackMhsd >= 0 else { return nil }
        let mhlt = trackMhsd + u32(d, trackMhsd+4)
        guard tag(d, mhlt) == "mhlt" else { return nil }
        let originalSongCount = u32(d, mhlt+8)

        // Template mhit header + max track id (walk the track list).
        var maxID = 0
        var mhitTemplate: [UInt8]? = nil
        var q = mhlt + u32(d, mhlt+4)
        for _ in 0..<originalSongCount {
            guard tag(d, q) == "mhit" else { break }
            maxID = max(maxID, u32(d, q+16))
            if mhitTemplate == nil { mhitTemplate = slice(d, q, u32(d, q+4)) }
            q += u32(d, q+8)
        }
        guard let mhitHeader = mhitTemplate, mhitHeader.count >= 48 else { return nil }
        let trackMhsdEnd = trackMhsd + u32(d, trackMhsd+8)
        guard trackMhsdEnd <= d.count else { return nil }

        // Build the concatenated mhit+mhod block for all new tracks.
        var newBlock: [UInt8] = []
        var newIDs: [Int] = []
        for (i, t) in tracks.enumerated() {
            let id = maxID + 1 + i
            newIDs.append(id)
            var mhit = mhitHeader
            let mhods = stringMhod(type: 1, t.title) + stringMhod(type: 2, t.location)
                      + stringMhod(type: 3, t.album) + stringMhod(type: 4, t.artist)
                      + (t.genre.isEmpty ? [] : stringMhod(type: 5, t.genre))
            let numMhod = t.genre.isEmpty ? 4 : 5
            setU32(&mhit, 12, numMhod)
            setU32(&mhit, 16, id)
            setU32(&mhit, 36, t.sizeBytes)
            setU32(&mhit, 40, t.durationMs)
            setU32(&mhit, 8, mhit.count + mhods.count)   // total_len
            newBlock += mhit + mhods
        }
        let addT = newBlock.count

        // Insert track block + patch track-list counts/lengths.
        d.insert(contentsOf: newBlock, at: trackMhsdEnd)
        setU32(&d, mhlt+8, originalSongCount + tracks.count)
        setU32(&d, trackMhsd+8, u32(d, trackMhsd+8) + addT)

        // Insert into each master playlist (high offset → low so earlier offsets stay valid).
        for m in masterPlaylists(in: d, songCount: originalSongCount).sorted(by: >) {
            // Template mhip (incl. its child mhod) = first playlist item.
            let hl = u32(d, m+4); let numMhod = u32(d, m+12); let numItems = u32(d, m+16)
            var c = m + hl
            for _ in 0..<numMhod { c += u32(d, c+8) }
            guard tag(d, c) == "mhip", let mhipTemplate = slice(d, c, u32(d, c+8)) else { continue }
            // Walk to the end of the item list.
            var end = c
            for _ in 0..<numItems { guard tag(d, end) == "mhip" else { break }; end += u32(d, end+8) }
            guard end <= d.count else { continue }
            // Build one mhip per new track.
            var block: [UInt8] = []
            for id in newIDs {
                var mhip = mhipTemplate
                setU32(&mhip, 24, id)   // track_id
                block += mhip
            }
            d.insert(contentsOf: block, at: end)
            setU32(&d, m+16, u32(d, m+16) + tracks.count)   // num_items
            setU32(&d, m+8, u32(d, m+8) + block.count)      // mhyp total_len
            // Enclosing mhsd total_len.
            var pp = mhbdHeader
            for _ in 0..<numChildren {
                guard tag(d, pp) == "mhsd" else { break }
                let stl = u32(d, pp+8)
                if pp < m && m < pp + stl { setU32(&d, pp+8, stl + block.count); break }
                pp += u32(d, pp+8)
            }
        }

        // Finalise: size field == actual length, then re-stamp the checksum.
        setU32(&d, 8, d.count)
        IPodHash.writeHash58(into: &d, serial: serial)

        // Refuse to hand back a structurally-inconsistent DB (guards the device against a bug).
        guard validate(d, expectedSongs: originalSongCount + tracks.count) else { return nil }
        return d
    }

    /// Remove tracks (by mhit track id) from the DB: deletes their mhit records and their entries
    /// in both master playlists, patches all lengths, re-stamps the checksum, and self-validates.
    /// Mirrors a prototype validated against the real device DB. Returns nil on any inconsistency.
    static func remove(trackIDs: Set<Int>, from original: [UInt8], serial: String) -> [UInt8]? {
        guard !trackIDs.isEmpty, original.count > 0x6c, tag(original, 0) == "mhbd" else { return nil }
        var d = original
        let mhbdHeader = u32(d, 4)
        let numChildren = u32(d, 0x14)
        var trackMhsd = -1
        var p = mhbdHeader
        for _ in 0..<numChildren {
            guard tag(d, p) == "mhsd" else { break }
            if u32(d, p+12) == 1 { trackMhsd = p; break }
            p += u32(d, p+8)
        }
        guard trackMhsd >= 0 else { return nil }
        let mhlt = trackMhsd + u32(d, trackMhsd+4)
        guard tag(d, mhlt) == "mhlt" else { return nil }
        let originalSongCount = u32(d, mhlt+8)

        // Collect deletions: (start, len, kind, containerHeaderOffset). kind 0 = mhit, 1 = mhip.
        var dels: [(start: Int, len: Int, isTrack: Bool, hdr: Int)] = []
        var removedTracks = 0
        var q = mhlt + u32(d, mhlt+4)
        for _ in 0..<originalSongCount {
            guard tag(d, q) == "mhit" else { break }
            let total = u32(d, q+8)
            if trackIDs.contains(u32(d, q+16)) { dels.append((q, total, true, trackMhsd)); removedTracks += 1 }
            q += total
        }
        guard removedTracks > 0 else { return nil }

        // Master playlists' mhip entries for those track ids.
        for j in masterPlaylists(in: d, songCount: originalSongCount) {
            let hl = u32(d, j+4); let nm = u32(d, j+12); let ni = u32(d, j+16)
            var c = j + hl
            for _ in 0..<nm { c += u32(d, c+8) }
            for _ in 0..<ni {
                guard tag(d, c) == "mhip" else { break }
                let total = u32(d, c+8)
                if trackIDs.contains(u32(d, c+24)) { dels.append((c, total, false, j)) }
                c += total
            }
        }

        // Apply deletions highest-offset → lowest so lower offsets (headers) stay valid.
        for del in dels.sorted(by: { $0.start > $1.start }) {
            guard del.start >= 0, del.len > 0, del.start + del.len <= d.count else { return nil }
            d.removeSubrange(del.start ..< del.start + del.len)
            if del.isTrack {
                setU32(&d, mhlt+8, u32(d, mhlt+8) - 1)
                setU32(&d, trackMhsd+8, u32(d, trackMhsd+8) - del.len)
            } else {
                setU32(&d, del.hdr+16, u32(d, del.hdr+16) - 1)      // num_items
                setU32(&d, del.hdr+8, u32(d, del.hdr+8) - del.len)  // mhyp total_len
                var pp = mhbdHeader
                for _ in 0..<numChildren {
                    guard tag(d, pp) == "mhsd" else { break }
                    let stl = u32(d, pp+8)
                    if pp < del.hdr && del.hdr < pp + stl { setU32(&d, pp+8, stl - del.len); break }
                    pp += u32(d, pp+8)
                }
            }
        }
        setU32(&d, 8, d.count)
        IPodHash.writeHash58(into: &d, serial: serial)
        guard validate(d, expectedSongs: originalSongCount - removedTracks) else { return nil }
        return d
    }

    /// Structural sanity check: the mhbd→mhsd chain must walk cleanly to exactly EOF, the size
    /// field must match, and the track count must equal `expectedSongs`. Guards against a
    /// length-patching bug corrupting the device DB — we refuse to write unless this passes.
    static func validate(_ d: [UInt8], expectedSongs: Int) -> Bool {
        guard d.count > 0x6c, tag(d, 0) == "mhbd", u32(d, 8) == d.count else { return false }
        var p = u32(d, 4)
        let n = u32(d, 0x14)
        var trackCount = -1
        for _ in 0..<n {
            guard p + 12 <= d.count, tag(d, p) == "mhsd" else { return false }
            if u32(d, p+12) == 1 {
                let mhlt = p + u32(d, p+4)
                if tag(d, mhlt) == "mhlt" { trackCount = u32(d, mhlt+8) }
            }
            p += u32(d, p+8)
        }
        return p == d.count && trackCount == expectedSongs
    }
}
