import SwiftUI
import Charts
import MurmurKit

struct ChartPanel: View {
    @Bindable var session: MQTTSession

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Charts", systemImage: "chart.xyaxis.line").font(.headline)
                Spacer()
                if !session.charts.isEmpty {
                    Button("Remove All") { session.charts.removeAll() }
                        .controlSize(.small)
                }
                Button { session.showCharts = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Hide charts")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if session.charts.isEmpty {
                ContentUnavailableView("No Charts",
                                       systemImage: "chart.xyaxis.line",
                                       description: Text("Click the chart button next to a numeric value to plot it."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach($session.charts) { $series in
                            ChartCard(series: $series, onRemove: { session.removeChart(series.id) },
                                      onSelect: { session.reveal(series.topic) })
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ChartCard: View {
    @Binding var series: ChartSeries
    let onRemove: () -> Void
    let onSelect: () -> Void

    var body: some View {
        let points = series.visiblePoints
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Circle().fill(series.color).frame(width: 8, height: 8)
                Button(action: onSelect) {
                    Text(series.title).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
                .help("Show topic in tree")
                Spacer()
                if let last = series.points.last {
                    Text(last.value.formatted(.number.precision(.significantDigits(1...6))))
                        .font(.callout.monospacedDigit().weight(.semibold))
                }
                Menu {
                    Picker("Time range", selection: $series.timeRange) {
                        ForEach(ChartTimeRange.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Interpolation", selection: $series.interpolation) {
                        ForEach(ChartInterpolation.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Color", selection: $series.colorIndex) {
                        ForEach(ChartSeries.palette.indices, id: \.self) { i in
                            Text(colorName(i)).tag(i)
                        }
                    }
                    Toggle("Show points", isOn: $series.showPoints)
                    Divider()
                    Button("Clear Data") { series.points.removeAll() }
                    Button("Copy Data as CSV") { Pasteboard.copy(csv) }
                    Divider()
                    Button("Remove Chart", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if points.isEmpty {
                Text("Waiting for numeric values…")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                Chart(points) { p in
                    LineMark(x: .value("Time", p.date), y: .value("Value", p.value))
                        .interpolationMethod(method)
                        .foregroundStyle(series.color)
                    if series.showPoints || points.count < 3 {
                        PointMark(x: .value("Time", p.date), y: .value("Value", p.value))
                            .foregroundStyle(series.color)
                            .symbolSize(16)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) {
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute().second())
                    }
                }
                .frame(minHeight: 140)
                HStack {
                    Text("\(points.count) points")
                    Spacer()
                    if let min = points.map(\.value).min(), let max = points.map(\.value).max() {
                        Text("min \(min.formatted(.number.precision(.significantDigits(1...5)))) · max \(max.formatted(.number.precision(.significantDigits(1...5))))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    }

    private var method: InterpolationMethod {
        switch series.interpolation {
        case .linear: .linear
        case .stepped: .stepEnd
        case .smooth: .monotone
        }
    }

    private var csv: String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return "timestamp,value\n" + series.points.map { "\(f.string(from: $0.date)),\($0.value)" }.joined(separator: "\n")
    }

    private func colorName(_ i: Int) -> String {
        ["Blue", "Orange", "Green", "Pink", "Purple", "Teal", "Red", "Yellow", "Indigo", "Mint"][i % 10]
    }
}
