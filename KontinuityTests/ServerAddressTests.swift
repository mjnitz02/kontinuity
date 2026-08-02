//
//  ServerAddressTests.swift
//  KontinuityTests
//
//  Address normalisation is the most likely thing to be wrong on the connect
//  screen and the cheapest thing to pin down, so it gets the most cases.
//

import Foundation
import Testing
@testable import KontinuityCore

@Suite("ServerAddress")
struct ServerAddressTests {
    @Test("keeps an explicit scheme, port and host")
    func explicitScheme() throws {
        let address = try ServerAddress(normalizing: "http://10.0.0.5:25600")
        #expect(address.baseURL.absoluteString == "http://10.0.0.5:25600")
    }

    @Test("assumes http for private and link-local hosts", arguments: [
        "10.0.0.5:25600",
        "192.168.1.20:25600",
        "172.16.4.4",
        "172.31.255.1",
        "127.0.0.1:25600",
        "169.254.10.1",
        "localhost:25600",
        "nas.local:25600",
        "komga.lan"
    ])
    func assumesHTTPForLocalHosts(input: String) throws {
        let address = try ServerAddress(normalizing: input)
        #expect(address.baseURL.scheme == "http", "expected http for \(input)")
    }

    @Test("assumes https for routable hosts", arguments: [
        "komga.example.com",
        "books.example.org:8443",
        "172.32.0.1",
        "11.0.0.1",
        "192.169.1.1"
    ])
    func assumesHTTPSForPublicHosts(input: String) throws {
        let address = try ServerAddress(normalizing: input)
        #expect(address.baseURL.scheme == "https", "expected https for \(input)")
    }

    @Test("trims whitespace and trailing slashes")
    func trimsNoise() throws {
        let address = try ServerAddress(normalizing: "  http://nas.local:25600///  ")
        #expect(address.baseURL.absoluteString == "http://nas.local:25600")
    }

    @Test("strips a pasted API or OPDS suffix", arguments: [
        "http://nas.local:25600/api/v1",
        "http://nas.local:25600/api/v2/",
        "http://nas.local:25600/api",
        "http://nas.local:25600/opds/v2",
        "http://nas.local:25600/opds"
    ])
    func stripsAPISuffix(input: String) throws {
        let address = try ServerAddress(normalizing: input)
        #expect(address.baseURL.absoluteString == "http://nas.local:25600")
    }

    @Test("preserves a reverse-proxy subpath while stripping the API suffix")
    func preservesSubpath() throws {
        let address = try ServerAddress(normalizing: "https://example.com/komga/api/v1")
        #expect(address.baseURL.absoluteString == "https://example.com/komga")
        #expect(address.url(path: "/api/v2/users/me").absoluteString
            == "https://example.com/komga/api/v2/users/me")
    }

    @Test("appends paths correctly with no subpath")
    func appendsToBareHost() throws {
        let address = try ServerAddress(normalizing: "10.0.0.5:25600")
        #expect(address.url(path: "/actuator/health").absoluteString
            == "http://10.0.0.5:25600/actuator/health")
    }

    @Test("drops embedded credentials, query and fragment")
    func dropsSensitiveParts() throws {
        let address = try ServerAddress(normalizing: "http://matt:hunter2@nas.local:25600/?a=b#frag")
        #expect(address.baseURL.absoluteString == "http://nas.local:25600")
    }

    @Test("rejects empty input")
    func rejectsEmpty() {
        #expect(throws: KomgaError.self) { try ServerAddress(normalizing: "   ") }
    }

    @Test("rejects a non-http scheme")
    func rejectsBadScheme() {
        #expect(throws: KomgaError.self) { try ServerAddress(normalizing: "ftp://nas.local") }
    }

    @Test("rejects a scheme with no host")
    func rejectsMissingHost() {
        #expect(throws: KomgaError.self) { try ServerAddress(normalizing: "http://") }
    }
}
