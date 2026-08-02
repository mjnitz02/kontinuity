//
//  KomgaReaderDTOTests.swift
//  KontinuityTests
//
//  The DIVINA manifest shape (KOMGA-API §2) and the progression PUT body
//  (KOMGA-API §4), pinned against a stubbed transport the same way
//  KomgaClientTests pins status-code semantics.
//

import Foundation
import Testing
@testable import KontinuityCore

@Suite("Komga reader DTOs")
struct KomgaReaderDTOTests {
    private func makeClient(_ stubs: [Stub]) throws -> (KomgaClient, StubTransport) {
        let transport = StubTransport(stubs)
        let client = try KomgaClient(
            address: ServerAddress(normalizing: "http://nas.local:25600"),
            credential: .apiKey("secret-key"),
            session: transport.session
        )
        return (client, transport)
    }

    @Test("decodes a real-shaped manifest, including a page with no alternate")
    func decodesManifest() async throws {
        let json = """
        { "metadata": { "title": "Windrunner, Vol. 1", "numberOfPages": 2 },
          "readingOrder": [
            { "href": "/opds/v2/books/b1/pages/1?contentNegotiation=false", "type": "image/jpeg",
              "width": 800, "height": 1200 },
            { "href": "/opds/v2/books/b1/pages/2?contentNegotiation=false", "type": "image/webp",
              "width": 800, "height": 1200,
              "alternate": [ { "href": "/opds/v2/books/b1/pages/2?convert=jpeg", "type": "image/jpeg" } ] }
          ] }
        """
        let (client, transport) = try makeClient([.json(json)])
        let manifest = try await client.divinaManifest(forBook: "b1")

        #expect(manifest.metadata.title == "Windrunner, Vol. 1")
        #expect(manifest.readingOrder.count == 2)
        #expect(manifest.readingOrder[0].alternate.isEmpty)
        #expect(manifest.readingOrder[1].alternate.first?.href == "/opds/v2/books/b1/pages/2?convert=jpeg")
        #expect(transport.requests.first?.path == "/opds/v2/books/b1/manifest/divina")
    }

    @Test("width and height are optional — an unanalysed page must still decode")
    func decodesMissingDimensions() async throws {
        let json = """
        { "metadata": { "title": "Unanalysed" },
          "readingOrder": [ { "href": "/opds/v2/books/b1/pages/1", "type": "image/jpeg" } ] }
        """
        let (client, _) = try makeClient([.json(json)])
        let manifest = try await client.divinaManifest(forBook: "b1")

        let page = try #require(manifest.readingOrder.first)
        #expect(page.width == nil)
        #expect(page.height == nil)
        #expect(manifest.metadata.numberOfPages == nil)
    }

    @Test("PUTs the progression body KOMGA-API §4 describes")
    func putProgressionBodyShape() async throws {
        let (client, transport) = try makeClient([.status(204)])
        // A fixed, non-`.now` date — the outbox flushes an entry well after the
        // page turn it describes, so `modified` must be the turn's own
        // timestamp rather than whenever this call happens to run.
        let turnDate = Date(timeIntervalSince1970: 1_780_000_000)
        try await client.putProgression(
            bookID: "b1",
            write: ProgressionWrite(
                page: 42, pageHref: "/opds/v2/books/b1/pages/42", mediaType: "image/jpeg", readDate: turnDate
            ),
            device: KomgaDevice(
                id: #require(UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")),
                name: "Test iPad"
            )
        )

        let request = try #require(transport.requests.first)
        #expect(request.method == "PUT")
        #expect(request.path == "/api/v1/books/b1/progression")

        let body = try #require(request.body)
        let object = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let modified = try #require(object["modified"] as? String)
        #expect(KomgaDate.parse(modified) == turnDate)

        let device = try #require(object["device"] as? [String: String])
        #expect(device["id"] == "00000000-0000-0000-0000-0000000000AA")
        #expect(device["name"] == "Test iPad")

        let locator = try #require(object["locator"] as? [String: Any])
        #expect(locator["href"] as? String == "/opds/v2/books/b1/pages/42")
        #expect(locator["type"] as? String == "image/jpeg")
        let locations = try #require(locator["locations"] as? [String: Int])
        #expect(locations["position"] == 42)
    }
}
