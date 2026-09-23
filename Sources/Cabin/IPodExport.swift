import Foundation

/// Phase-3 building block: prepare audio for copying onto a click-wheel iPod.
///
/// iPods can't play FLAC, so downloaded albums are transcoded to **Apple Lossless (ALAC)** —
/// full quality, and click-wheel iPods (incl. the Classic) play it natively. Uses macOS's
/// built-in `afconvert`, so there's no third-party dependency for the audio side.
///
/// NOTE: this only produces the file. Making a track *appear* on the iPod additionally requires
/// writing its checksum-protected `iTunesDB` — see the Phase-3 notes; that path is not wired yet.
enum IPodExport {
    /// Convert any afconvert-readable source (FLAC/WAV/AIFF/AAC/…) to an **iPod-safe** ALAC `.m4a`.
    ///
    /// The click-wheel iPod (incl. the Classic) only decodes ALAC up to **48 kHz / 16-bit**, but
    /// Bandcamp FLAC is often 24-bit or hi-res (88.2/96 kHz). A one-pass `-d alac` keeps the source's
    /// rate and depth, so a hi-res album becomes hi-res ALAC that the iPod *lists but can't play*.
    /// So we go through 16-bit / 44.1 kHz PCM first (dithered downsample), then encode that to ALAC —
    /// CD-quality lossless the Classic always plays. Blocking; run off the main actor.
    static func transcodeToALAC(source: URL, destination: URL) throws {
        // Intermediate 16-bit/44.1kHz WAV next to the destination; removed afterwards.
        let pcm = destination.deletingPathExtension().appendingPathExtension("cabinpcm.wav")
        defer { try? FileManager.default.removeItem(at: pcm) }
        // Pass 1: source → 16-bit little-endian PCM @ 44.1 kHz (afconvert resamples + dithers).
        try afconvert(["-f", "WAVE", "-d", "LEI16@44100", source.path, pcm.path])
        // Pass 2: that PCM → ALAC in an m4a container.
        try afconvert(["-f", "m4af", "-d", "alac", pcm.path, destination.path])
    }

    private static func afconvert(_ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        try p.run()
        // Drain stderr *before* waiting: afconvert can emit more than the pipe buffer (~64KB) of
        // warnings, and a full pipe would block the child while we block in waitUntilExit() — a
        // permanent deadlock. readDataToEndOfFile() reads until the child exits, so the wait then
        // returns immediately.
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "IPodExport", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't convert audio to ALAC: \(msg)"])
        }
    }
}
