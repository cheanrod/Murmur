import SwiftUI
import MurmurKit

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum TimestampStyle: String, CaseIterable, Identifiable {
    case relative, absolute
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Keys and defaults for values stored with @AppStorage.
enum SettingsKey {
    static let appearance = "appearance"
    static let topicOrder = "topicOrder"
    static let autoExpand = "autoExpand"
    static let highlightUpdates = "highlightUpdates"
    static let historyLimit = "historyLimit"
    static let timestampStyle = "timestampStyle"
    static let maxChartPoints = "maxChartPoints"
    static let showValuePreview = "showValuePreview"
    static let confirmDeletes = "confirmDeletes"
}

enum SettingsDefault {
    static let historyLimit = 100
    static let maxChartPoints = 5000
}

extension UserDefaults {
    var murmurHistoryLimit: Int {
        let v = integer(forKey: SettingsKey.historyLimit)
        return v > 0 ? v : SettingsDefault.historyLimit
    }

    var murmurMaxChartPoints: Int {
        let v = integer(forKey: SettingsKey.maxChartPoints)
        return v > 0 ? v : SettingsDefault.maxChartPoints
    }

    var murmurTopicOrder: TopicOrder {
        string(forKey: SettingsKey.topicOrder).flatMap(TopicOrder.init(rawValue:)) ?? .none
    }

    var murmurAutoExpand: AutoExpand {
        string(forKey: SettingsKey.autoExpand).flatMap(AutoExpand.init(rawValue:)) ?? .off
    }
}

enum Formatters {
    static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static let dateTime: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .medium
        return f
    }()

    static func bytes(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }

    static func number(_ n: Int) -> String {
        n.formatted(.number)
    }
}
