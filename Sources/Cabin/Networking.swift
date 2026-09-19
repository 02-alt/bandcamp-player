import Foundation

/// The one fact a networking module must know about transport: how to turn a request into bytes.
/// Keeping it a single-method seam means the deep clients (`BandcampClient`, and any others that
/// adopt it) can be driven from a fixture in tests without reaching the real internet — their
/// brittle response-parsing becomes exercisable through their own interface.
///
/// One adapter (`URLSessionHTTP`) plus a test fake makes this a real seam, not a hypothetical one.
protocol HTTP: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

/// The production adapter: a thin wrapper over `URLSession`. This is the default everywhere, so
/// introducing the seam changes no runtime behaviour.
struct URLSessionHTTP: HTTP {
    let session: URLSession
    init(_ session: URLSession = .shared) { self.session = session }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
