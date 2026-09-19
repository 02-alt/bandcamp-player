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
    /// Convert any afconvert-readable source (FLAC/WAV/AIFF/AAC/…) to an ALAC `.m4a`.
    /// Blocking; run off the main actor. Throws with afconvert's stderr on failure.
    static func transcodeToALAC(source: URL, destination: URL) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", "m4af", "-d", "alac", source.path, destination.path]
        let err = Pipe()
        p.standardError = err
        try p.run()
        // Drain stderr *before* waiting: afconvert can emit more than the pipe buffer (~64KB)
        // of warnings, and a full pipe would block the child while we block in waitUntilExit()
        // — a permanent deadlock that hangs the Add-to-iPod task. readDataToEndOfFile() reads
        // until the child closes the pipe (i.e. exits), so the wait then returns immediately.
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "unknown error"
            throw NSError(domain: "IPodExport", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Couldn't convert audio to ALAC: \(msg)"])
        }
    }
}
