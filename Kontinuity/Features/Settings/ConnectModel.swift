//
//  ConnectModel.swift
//  Kontinuity
//
//  Drives the connect screen. The network flow itself lives in
//  KontinuityCore's ServerConnector; this holds only the form state and the
//  persistence side-effects (Keychain write + SwiftData insert).
//

import KontinuityCore
import SwiftData
import SwiftUI

@MainActor
@Observable
final class ConnectModel {
    enum Method: String, CaseIterable, Identifiable {
        case credentials
        case apiKey

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .credentials: "Email & password"
            case .apiKey: "API key"
            }
        }
    }

    var addressText = ""
    var email = ""
    var password = ""
    var apiKeyText = ""
    var method: Method = .credentials

    private(set) var isConnecting = false
    private(set) var errorMessage: String?
    private(set) var errorSuggestion: String?
    /// Set when the connection succeeded but the account can't actually read —
    /// worth saying out loud rather than failing later in the reader.
    private(set) var roleWarning: String?

    var canSubmit: Bool {
        guard !isConnecting, !addressText.trimmed.isEmpty else { return false }
        switch method {
        case .credentials: return !email.trimmed.isEmpty && !password.isEmpty
        case .apiKey: return !apiKeyText.trimmed.isEmpty
        }
    }

    func connect(context: ModelContext, secrets: SecretStoring, deviceName: String) async {
        guard canSubmit else { return }

        isConnecting = true
        errorMessage = nil
        errorSuggestion = nil
        roleWarning = nil
        defer { isConnecting = false }

        let method: ServerConnector.Method = switch self.method {
        case .credentials: .credentials(email: email.trimmed, password: password)
        case .apiKey: .existingAPIKey(apiKeyText.trimmed)
        }

        do {
            let connection = try await ServerConnector().connect(
                to: addressText.trimmed,
                using: method,
                deviceName: deviceName
            )

            let server = Server(
                baseURLString: connection.address.baseURL.absoluteString,
                deviceName: deviceName,
                apiKeyID: connection.apiKeyID,
                userEmail: connection.user.email,
                lastConnectedDate: .now
            )

            // Keychain first: a Server row whose key is missing is a broken
            // state the UI would have to special-case on every launch.
            try secrets.store(connection.apiKey, for: server.apiKeyRef)
            context.insert(server)
            try context.save()

            password = ""
            apiKeyText = ""
            roleWarning = Self.roleWarning(for: connection.user)
        } catch {
            let komga = error as? KomgaError
            errorMessage = komga?.errorDescription ?? error.localizedDescription
            errorSuggestion = komga?.recoverySuggestion
        }
    }

    private static func roleWarning(for user: KomgaUser) -> String? {
        if !user.canStreamPages {
            return "This account lacks the PAGE_STREAMING role, so pages can't be loaded. "
                + "Grant it in Komga under Users."
        }
        if !user.canDownloadFiles {
            return "This account lacks the FILE_DOWNLOAD role. Reading works, but downloads "
                + "will fall back to slower per-page fetching."
        }
        return nil
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
