//
//  ServerSettingsView.swift
//  Kontinuity
//
//  Connected state: what we're talking to, as whom, and how to undo it.
//

import KontinuityCore
import SwiftData
import SwiftUI

struct ServerSettingsView: View {
    let server: Server

    @Environment(\.modelContext) private var context
    @Environment(\.secretStore) private var secrets
    @State private var status: Status = .idle
    @State private var isDisconnecting = false
    @State private var showDisconnectConfirmation = false

    private enum Status: Equatable {
        case idle
        case checking
        case ok(email: String, roles: [String])
        case failed(String)
    }

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Address", value: server.baseURLString)
                LabeledContent("Device", value: server.deviceName)
                if let email = server.userEmail {
                    LabeledContent("Account", value: email)
                }
                if let last = server.lastConnectedDate {
                    LabeledContent("Last connected", value: last.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section {
                switch status {
                case .idle:
                    Button("Check connection") { Task { await check() } }
                case .checking:
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Checking…")
                    }
                case let .ok(email, roles):
                    Label("Connected as \(email)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    LabeledContent("Roles", value: roles.isEmpty ? "—" : roles.joined(separator: ", "))
                    Button("Check again") { Task { await check() } }
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("Try again") { Task { await check() } }
                }
            } header: {
                Text("Status")
            }

            Section {
                Button("Disconnect", role: .destructive) { showDisconnectConfirmation = true }
                    .disabled(isDisconnecting)
            } footer: {
                Text(server.apiKeyID == nil
                    ? "Removes the server and the stored key from this device. The key you pasted stays valid in Komga."
                    : "Removes the server from this device and revokes the API key Kontinuity created in Komga.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Server")
        .task { await check() }
        .confirmationDialog(
            "Disconnect from this server?",
            isPresented: $showDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) { Task { await disconnect() } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func check() async {
        status = .checking
        do {
            guard let client = try server.client(secrets: secrets) else {
                status = .failed("The stored API key is missing. Disconnect and connect again.")
                return
            }
            let user = try await client.currentUser()
            server.userEmail = user.email
            server.lastConnectedDate = .now
            try? context.save()
            status = .ok(email: user.email, roles: user.roles.sorted())
        } catch {
            let komga = error as? KomgaError
            status = .failed(komga?.errorDescription ?? error.localizedDescription)
        }
    }

    private func disconnect() async {
        isDisconnecting = true
        defer { isDisconnecting = false }

        // Best-effort revoke: if the server is unreachable we still remove the
        // local record, otherwise a broken server would trap the user here.
        if let keyID = server.apiKeyID, let client = try? server.client(secrets: secrets) {
            try? await client.deleteAPIKey(id: keyID)
        }
        try? secrets.removeSecret(for: server.apiKeyRef)
        context.delete(server)
        try? context.save()
    }
}
