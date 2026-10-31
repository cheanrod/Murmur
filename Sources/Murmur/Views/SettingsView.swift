import SwiftUI
import MurmurKit

struct SettingsView: View {
    @AppStorage(SettingsKey.appearance) private var appearance: Appearance = .system
    @AppStorage(SettingsKey.topicOrder) private var topicOrder: TopicOrder = .none
    @AppStorage(SettingsKey.autoExpand) private var autoExpand: AutoExpand = .off
    @AppStorage(SettingsKey.highlightUpdates) private var highlightUpdates = true
    @AppStorage(SettingsKey.showValuePreview) private var showValuePreview = true
    @AppStorage(SettingsKey.historyLimit) private var historyLimit = SettingsDefault.historyLimit
    @AppStorage(SettingsKey.maxChartPoints) private var maxChartPoints = SettingsDefault.maxChartPoints
    @AppStorage(SettingsKey.timestampStyle) private var timestampStyle: TimestampStyle = .relative
    @AppStorage(SettingsKey.confirmDeletes) private var confirmDeletes = true

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Theme", selection: $appearance) {
                    ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Timestamps", selection: $timestampStyle) {
                    ForEach(TimestampStyle.allCases) { Text($0.label).tag($0) }
                }
            }

            Section("Topic Tree") {
                Picker("Order", selection: $topicOrder) {
                    ForEach(TopicOrder.allCases) { Text($0.label).tag($0) }
                }
                Picker("Auto expand", selection: $autoExpand) {
                    ForEach(AutoExpand.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Highlight topic updates", isOn: $highlightUpdates)
                Toggle("Show value preview", isOn: $showValuePreview)
                Toggle("Confirm before deleting topics", isOn: $confirmDeletes)
            }

            Section("History") {
                Picker("Messages kept per topic", selection: $historyLimit) {
                    ForEach([10, 25, 50, 100, 250, 500, 1000], id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Points kept per chart", selection: $maxChartPoints) {
                    ForEach([500, 1000, 5000, 10000, 50000], id: \.self) { Text(Formatters.number($0)).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 380, minHeight: 420)
    }
}
