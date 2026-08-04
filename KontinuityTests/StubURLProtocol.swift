//
//  StubURLProtocol.swift
//  KontinuityTests
//
//  A URLProtocol that answers from a queue of canned responses, so the Komga
//  client and the connect flow can be tested without a server.
//
//  Stubs are keyed by a per-instance token carried in a request header rather
//  than held in one global queue: Swift Testing runs suites — and the cases of a
//  parameterised test — in parallel, and a shared queue means tests silently
//  consume each other's responses.
//

import Foundation

struct Stub {
    var status: Int
    var body: Data
    var headers: [String: String]
    var error: URLError?

    static func json(_ raw: String, status: Int = 200) -> Stub {
        Stub(status: status, body: Data(raw.utf8), headers: ["Content-Type": "application/json"], error: nil)
    }

    static func status(_ status: Int, body: String = "") -> Stub {
        Stub(status: status, body: Data(body.utf8), headers: [:], error: nil)
    }

    static func failure(_ code: URLError.Code) -> Stub {
        Stub(status: 0, body: Data(), headers: [:], error: URLError(code))
    }
}

/// A request as the stub saw it. The body is captured eagerly because
/// `URLProtocol` receives an upload body as `httpBodyStream`, leaving
/// `httpBody` nil — asserting on `httpBody` directly silently always fails.
struct RecordedRequest {
    let request: URLRequest
    let body: Data?

    var path: String? {
        request.url?.path
    }

    var method: String? {
        request.httpMethod
    }

    func header(_ field: String) -> String? {
        request.value(forHTTPHeaderField: field)
    }

    /// Decodes a JSON object body into `[String: String]` for assertions.
    var jsonBody: [String: String]? {
        guard let body else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: String]
    }
}

/// Owns one isolated stub queue and the `URLSession` wired to it.
final class StubTransport {
    static let headerField = "X-Stub-Session"

    private let token = UUID().uuidString
    let session: URLSession

    init(_ stubs: [Stub] = []) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        // URLSession merges these into every request before the protocol sees
        // it, which is how a stub instance recognises its own traffic.
        configuration.httpAdditionalHeaders = [StubTransport.headerField: token]
        session = URLSession(configuration: configuration)
        StubRegistry.shared.register(token: token, stubs: stubs)
    }

    /// Requests seen, in order.
    var requests: [RecordedRequest] {
        StubRegistry.shared.requests(for: token)
    }

    // Deliberately no `deinit` cleanup: a test that writes
    // `let (client, _) = makeClient(...)` drops the transport immediately, and
    // deregistering there would pull the stubs out from under the request that
    // hasn't been made yet. The registry entries are small and the test process
    // is short-lived.
}

private final class StubRegistry: @unchecked Sendable {
    static let shared = StubRegistry()

    private let lock = NSLock()
    private var queues: [String: [Stub]] = [:]
    private var recorded: [String: [RecordedRequest]] = [:]

    func register(token: String, stubs: [Stub]) {
        lock.withLock {
            queues[token] = stubs
            recorded[token] = []
        }
    }

    func requests(for token: String) -> [RecordedRequest] {
        lock.withLock { recorded[token] ?? [] }
    }

    func take(for request: URLRequest) -> Stub? {
        guard let token = request.value(forHTTPHeaderField: StubTransport.headerField) else { return nil }
        let recordedRequest = RecordedRequest(request: request, body: request.resolvedBody)
        return lock.withLock {
            recorded[token, default: []].append(recordedRequest)
            guard var queue = queues[token], !queue.isEmpty else { return nil }
            let stub = queue.removeFirst()
            queues[token] = queue
            return stub
        }
    }
}

private extension URLRequest {
    /// `httpBody` for a request built by hand, `httpBodyStream` once URLSession
    /// has handed it to a protocol.
    var resolvedBody: Data? {
        if let httpBody {
            return httpBody
        }
        guard let stream = httpBodyStream else { return nil }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data.isEmpty ? nil : data
    }
}

class StubURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.value(forHTTPHeaderField: StubTransport.headerField) != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        // No stub left means the code under test made an unexpected extra
        // request — surface it as a distinctive error rather than hanging.
        guard let stub = StubRegistry.shared.take(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        if let error = stub.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }

        let response = HTTPURLResponse(
            url: request.url ?? URL(fileURLWithPath: "/"),
            statusCode: stub.status,
            httpVersion: "HTTP/1.1",
            headerFields: stub.headers
        )
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        if !stub.body.isEmpty {
            client?.urlProtocol(self, didLoad: stub.body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
