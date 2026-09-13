import Foundation
@testable import Yoin

/// A fixture-backed `HTTP` adapter. Give it canned responses (in order, or keyed by URL substring)
/// and it answers `data(for:)` without touching the network — so `BandcampClient`'s parsing can be
/// tested through its own interface.
final class HTTPFake: HTTP, @unchecked Sendable {
    struct Canned {
        let data: Data; let status: Int
        static func html(_ s: String, status: Int = 200) -> Canned { .init(data: Data(s.utf8), status: status) }
        static func json(_ obj: Any, status: Int = 200) -> Canned {
            .init(data: try! JSONSerialization.data(withJSONObject: obj), status: status)
        }
    }

    private var queue: [Canned]
    private var byURL: [(needle: String, canned: Canned)]
    /// Records every request the client made, for asserting cookies / methods / bodies.
    private(set) var requests: [URLRequest] = []

    init(queue: [Canned] = [], byURL: [(String, Canned)] = []) {
        self.queue = queue
        self.byURL = byURL.map { ($0.0, $0.1) }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let urlString = request.url?.absoluteString ?? ""
        let canned: Canned
        if let match = byURL.first(where: { urlString.contains($0.needle) }) {
            canned = match.canned
        } else if !queue.isEmpty {
            canned = queue.removeFirst()
        } else {
            canned = Canned.html("", status: 500)
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: canned.status,
                                   httpVersion: nil, headerFields: nil)!
        return (canned.data, resp)
    }
}
