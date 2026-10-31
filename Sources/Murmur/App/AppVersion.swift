import Foundation

/// Version information written into Info.plist by Scripts/build-app.sh (derived from git, see Scripts/version.sh).
enum AppVersion {
    private static let info = Bundle.main.infoDictionary ?? [:]

    /// Marketing version from the latest release tag, e.g. "1.0.0". "dev" when running without a bundle.
    static let version = info["CFBundleShortVersionString"] as? String ?? "dev"
    /// Commit count, e.g. "42".
    static let build = info["CFBundleVersion"] as? String ?? "0"
    /// e.g. "1.0.0+3.g1a2b3c4.dirty"
    static let full = info["MurmurFullVersion"] as? String ?? "dev"
    static let commit = info["MurmurCommit"] as? String ?? "unknown"

    /// "1.0.0 (42)"
    static var display: String { version == "dev" ? "dev" : "\(version) (\(build))" }
}
