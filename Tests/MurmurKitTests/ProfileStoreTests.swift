import Foundation
import Testing
@testable import MurmurKit

@Suite struct ProfileStoreTests {
    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("murmur-tests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func secretsGoToCredentialStoreNotJSON() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let creds = InMemoryCredentialStore()
        let store = ProfileStore(directory: dir, credentials: creds)
        var p = ConnectionProfile(name: "x", host: "h")
        p.password = "s3cret"
        p.clientCertificatePassword = "p12pass"
        try store.save([p])

        let json = try String(contentsOf: store.url, encoding: .utf8)
        #expect(!json.contains("s3cret"))
        #expect(!json.contains("p12pass"))
        #expect(creds.secrets[ProfileStore.passwordAccount(p.id)] == "s3cret")

        let loaded = ProfileStore(directory: dir, credentials: creds).load()
        #expect(loaded.first?.password == "s3cret")
        #expect(loaded.first?.clientCertificatePassword == "p12pass")
        #expect(loaded.first?.host == "h")
    }

    @Test func deletingProfileRemovesSecrets() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let creds = InMemoryCredentialStore()
        let store = ProfileStore(directory: dir, credentials: creds)
        var p = ConnectionProfile(name: "x", host: "h")
        p.password = "pw"
        try store.save([p])
        try store.save([])
        #expect(creds.secrets.isEmpty)
    }

    @Test func plaintextPasswordsAreMigrated() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let legacy = #"[{"id":"\#(id.uuidString)","name":"old","host":"h","port":1883,"password":"legacy-pw"}]"#
        let url = dir.appendingPathComponent("connections.json")
        try legacy.write(to: url, atomically: true, encoding: .utf8)

        let creds = InMemoryCredentialStore()
        let loaded = ProfileStore(directory: dir, credentials: creds).load()
        #expect(loaded.first?.password == "legacy-pw")
        #expect(creds.secrets[ProfileStore.passwordAccount(id)] == "legacy-pw")
        #expect(try !String(contentsOf: url, encoding: .utf8).contains("legacy-pw"))
    }

    @Test func keychainRoundTrip() throws {
        let store = KeychainCredentialStore(service: "app.murmur.tests.\(UUID().uuidString)")
        let account = "roundtrip"
        defer { try? store.setSecret(nil, for: account) }
        try store.setSecret("first", for: account)
        #expect(try store.secret(for: account) == "first")
        try store.setSecret("second", for: account)
        #expect(try store.secret(for: account) == "second")
        try store.setSecret(nil, for: account)
        #expect(try store.secret(for: account) == nil)
    }
}
