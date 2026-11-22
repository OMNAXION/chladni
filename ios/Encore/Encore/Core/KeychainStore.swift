// The core's secret store on iOS (`encore_core::secrets`): YouTube sign-in cookies sealed into the
// iOS Keychain through the Security framework instead of the SQLite file. Generic-password items
// under the desktop's service name, readable after the first unlock (background refreshes run with
// the screen locked) and never synced to other devices.
import Foundation
import Security
import EncoreCore

final class KeychainStore: SecretStore, @unchecked Sendable {
    let service: String
    /// The older Encore service retained for legacy imports: an item missing under `service`
    /// is read from here once and saved under `service`. Only reachable when the keychain access
    /// group carries over; otherwise it simply finds nothing.
    let legacyService: String?
    init(service: String = "studio.chladni.ios", legacyService: String? = "app.encore.ios") {
        self.service = service
        self.legacyService = legacyService
    }

    private func query(_ name: String, service: String? = nil) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service ?? self.service,
         kSecAttrAccount as String: name]
    }

    private func fail(_ what: String, _ status: OSStatus) -> CoreError {
        let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return .Failed(message: "Keychain \(what): \(msg)")
    }

    func get(name: String) throws -> String? {
        if let v = try read(name, service: service) { return v }
        guard let legacy = legacyService, legacy != service, let v = try? read(name, service: legacy) else { return nil }
        try? set(name: name, value: v)
        return v
    }

    private func read(_ name: String, service: String) throws -> String? {
        var q = query(name, service: service)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = out as? Data else { throw fail("read", status) }
        return String(data: data, encoding: .utf8)
    }

    func set(name: String, value: String) throws {
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query(name) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(name)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw fail("write", status) }
    }

    func delete(name: String) throws {
        if let legacy = legacyService, legacy != service { SecItemDelete(query(name, service: legacy) as CFDictionary) }
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw fail("delete", status) }
    }
}
