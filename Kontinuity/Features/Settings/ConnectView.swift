//
//  ConnectView.swift
//  Kontinuity
//
//  Point at a Komga server and prove auth works.
//

import KontinuityCore
import SwiftData
import SwiftUI

struct ConnectView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.secretStore) private var secrets
    @State private var model = ConnectModel()
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case address, email, password, apiKey
    }

    var body: some View {
        Form {
            Section {
                TextField("komga.local:25600", text: $model.addressText)
                    .textContentType(.URL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focusedField, equals: .address)
            } header: {
                Text("Server")
            } footer: {
                Text("Leave off the scheme and Kontinuity assumes http:// on a local network, https:// otherwise.")
            }

            Section {
                Picker("Sign in with", selection: $model.method) {
                    ForEach(ConnectModel.Method.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                .pickerStyle(.segmented)

                switch model.method {
                case .credentials:
                    TextField("Email", text: $model.email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .email)

                    SecureField("Password", text: $model.password)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)

                case .apiKey:
                    SecureField("API key", text: $model.apiKeyText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .apiKey)
                }
            } footer: {
                switch model.method {
                case .credentials:
                    Text("Your password is used once to create an API key for this device, then discarded. "
                        + "The key is stored in the Keychain and can be revoked from Komga at any time.")
                case .apiKey:
                    Text("Paste a key from Komga under Account Settings → API Keys.")
                }
            }

            if let message = model.errorMessage {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message)
                            if let suggestion = model.errorSuggestion {
                                Text(suggestion)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                Button(action: submit) {
                    if model.isConnecting {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Connecting…")
                        }
                    } else {
                        Text("Connect")
                    }
                }
                .disabled(!model.canSubmit)
                .accessibilityIdentifier(AID.connectSubmit)
            }
        }
        .formStyle(.grouped)
        // A grouped Form fills its container, which on a 13" iPad stretches
        // these fields across ~1300pt. Cap it and centre instead.
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Connect to Komga")
        .onSubmit(submit)
        .disabled(model.isConnecting)
    }

    private func submit() {
        focusedField = nil
        Task {
            await model.connect(
                context: context,
                secrets: secrets,
                deviceName: UIDevice.current.name
            )
        }
    }
}

#Preview {
    NavigationStack {
        ConnectView()
    }
    .modelContainer(for: Server.self, inMemory: true)
}
