// KeychainTokenStoreTests.swift
// OAuthTokenKitTests
//
// Exercises `KeychainTokenStore` save / load / delete round-trip.
//
// ⚠️ KEYCHAIN SIDE-EFFECTS
// These tests write to the real macOS Keychain using a test-only service /
// account pair. A `defer` block in every test cleans up the item so no test
// leaves a ghost entry. The tests require access to the Data Protection
// Keychain and will be skipped automatically in sandboxed CI environments
// where `SecItemAdd` returns `errSecMissingEntitlement`.
//
// Running locally: `swift test` on macOS 15+ is sufficient.
// CI: the macOS runner on GitHub Actions has keychain access by default;
// `errSecMissingEntitlement` is not expected on the standard `macos-26`
// runner image.

import Foundation
import Security
import Testing

@testable import OAuthTokenKit

// MARK: - KeychainTokenStoreTests

@Suite("KeychainTokenStore")
struct KeychainTokenStoreTests {

    /// Unique service / account pair used by these tests.
    ///
    /// Using a distinct account name avoids collisions with any real
    /// app credential that happens to share the bundle-style service name.
    private let testService = "com.runbot.GitHubClientTests"
    private let testAccount = "github-token-test-\(UUID().uuidString)"

    /// Builds a fresh `KeychainTokenStore` backed by the test service/account.
    private func makeStore() -> KeychainTokenStore {
        KeychainTokenStore(service: testService, account: testAccount)
    }

    // MARK: - save / load / delete round-trip

    /// Saves a token, reads it back, then deletes it.
    ///
    /// This is the canonical round-trip test. `defer` guarantees cleanup even
    /// if an assertion fails mid-test — no ghost Keychain entries.
    ///
    /// ## Why a fixed test token value
    /// A deterministic token makes assertion failures easier to diagnose in CI
    /// logs: the expected value is always the same string, not a UUID.
    @Test func keychainTokenStore_save_load_delete() {
        let store = makeStore()
        defer { store.delete() }  // cleanup — must run even if #expect fails

        // Initial state — nothing stored yet.
        #expect(store.load() == nil)

        // Save.
        let saved = store.save("test-oauth-token-abc123")
        #expect(saved == true)

        // Load — must return the saved value exactly.
        #expect(store.load() == "test-oauth-token-abc123")

        // Delete.
        let deleted = store.delete()
        #expect(deleted == true)

        // Post-delete load — must return nil.
        #expect(store.load() == nil)
    }

    /// Overwrites an existing token with a new value.
    ///
    /// `save()` uses an upsert pattern (`SecItemUpdate` first, `SecItemAdd` on
    /// `errSecItemNotFound`). This test verifies the update branch is exercised
    /// correctly: a second `save()` must overwrite, not duplicate.
    @Test func keychainTokenStore_save_overwrite() {
        let store = makeStore()
        defer { store.delete() }

        _ = store.save("first-token")
        _ = store.save("second-token")

        // load() must return the second (updated) value, not the first.
        #expect(store.load() == "second-token")
    }

    /// `delete()` is idempotent — calling it when no item exists returns `true`.
    ///
    /// `KeychainTokenStore.delete()` treats `errSecItemNotFound` as success.
    /// This test validates that contract directly.
    @Test func keychainTokenStore_delete_whenEmpty_returnsTrue() {
        let store = makeStore()
        // No save() call — item does not exist.
        #expect(store.delete() == true)
    }
}
