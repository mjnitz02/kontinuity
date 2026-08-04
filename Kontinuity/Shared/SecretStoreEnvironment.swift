//
//  SecretStoreEnvironment.swift
//  Kontinuity
//
//  Injecting the secret store rather than reaching for the Keychain directly
//  keeps previews working — the Keychain needs entitlements a preview process
//  doesn't reliably have.
//

import KontinuityCore
import SwiftUI

extension EnvironmentValues {
    @Entry var secretStore: SecretStoring = KeychainSecretStore()
}
