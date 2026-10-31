import SwiftUI
import MurmurKit

/// The saved connection profiles, shared by all windows.
@MainActor
@Observable
final class ProfilesModel {
    static let shared = ProfilesModel()

    var profiles: [ConnectionProfile] {
        didSet { scheduleSave() }
    }
    var lastError: String?

    @ObservationIgnored private let store = ProfileStore()
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        profiles = store.load()
        lastError = store.credentialErrors.first
    }

    func add() -> ConnectionProfile {
        let p = ConnectionProfile(name: "New Connection", host: "localhost")
        profiles.append(p)
        return p
    }

    func duplicate(_ id: UUID) -> ConnectionProfile? {
        guard let original = profiles.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name += " Copy"
        copy.clientID = ConnectionProfile.randomClientID()
        profiles.append(copy)
        return copy
    }

    func delete(_ id: UUID) {
        profiles.removeAll { $0.id == id }
    }

    func binding(for id: UUID) -> Binding<ConnectionProfile>? {
        guard profiles.contains(where: { $0.id == id }) else { return nil }
        return Binding(
            get: { [weak self] in self?.profiles.first(where: { $0.id == id }) ?? ConnectionProfile() },
            set: { [weak self] newValue in
                guard let self, let i = self.profiles.firstIndex(where: { $0.id == id }) else { return }
                self.profiles[i] = newValue
            }
        )
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        do {
            try store.save(profiles)
            lastError = store.credentialErrors.first
        } catch {
            lastError = "Could not save connections: \(error.localizedDescription)"
        }
    }
}
