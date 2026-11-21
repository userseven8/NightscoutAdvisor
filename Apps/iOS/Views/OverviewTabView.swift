import Charts
import NightscoutAdvisorKit
import SwiftUI

struct OverviewTabView: View {
    @ObservedObject var viewModel: AdvisorViewModel
    let report: AdvisorReport
    let onOpenSettings: () -> Void

    @State private var selectedRangeIndex: Int = 1 // Default: 7d
    @State private var selectedDetail: ScheduleDetailItem?

    private var activeStats: GlycemicWindowStats {
        switch selectedRangeIndex {
        case 0: return report.stats24h
        case 1: return report.stats7d
        default: return report.statsRolling
        }
    }

    var body: some View {
        NavigationStack {
            List {
                // 1. Calm Top Summary & Time-in-Range Card
                Section {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack {
                            let changes = report.totalAdjustmentsCount
                            Image(systemName: changes == 0 ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                                .font(.title3)
                                .foregroundStyle(changes == 0 ? .green : .orange)
                            Text(changes == 0 ? "All Settings Look Good" : "\(changes) Adjustment\(changes == 1 ? "" : "s") Suggested")
                                .font(.headline)
                            Spacer()
                        }

                        Picker("Window", selection: $selectedRangeIndex) {
                            Text("24h").tag(0)
                            Text("7 Days").tag(1)
                            Text("\(report.rollingDays) Days").tag(2)
                        }
                        .pickerStyle(.segmented)

                        HStack(spacing: 0) {
                            SimpleMetricColumn(
                                label: "In Range",
                                value: String(format: "%.0f%%", activeStats.tirPercent),
                                valueColor: activeStats.tirPercent >= 70.0 ? Color.green : Color.primary
                            )
                            SimpleMetricColumn(
                                label: "Low <70",
                                value: String(format: "%.1f%%", activeStats.tbrPercent),
                                valueColor: activeStats.tbrPercent <= 4.0 ? Color.primary : Color.red
                            )
                            SimpleMetricColumn(
                                label: "Average",
                                value: report.displayUnit.formatBG(activeStats.meanMgdL),
                                valueColor: Color.primary
                            )
                            SimpleMetricColumn(
                                label: "GMI",
                                value: String(format: "%.1f%%", activeStats.gmiPercent),
                                valueColor: Color.secondary
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }

                // 2. Clean, Single-Line Therapy Schedules
                SchedulesSectionGroup(
                    report: report,
                    onSelectDetail: { selectedDetail = $0 }
                )

                // 3. Calm 24-Hour Glucose Profile
                Section("24-Hour Glucose Pattern") {
                    MinimalAGPChart(bins: report.agpBins, unit: report.displayUnit)
                        .padding(.vertical, 6)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("NS Advisor")
            .refreshable {
                if viewModel.isDemoMode && !viewModel.hasNightscoutURL {
                    await viewModel.loadDemoTelemetry(units: report.displayUnit)
                } else {
                    await viewModel.refreshFromNightscout()
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(item: $selectedDetail) { detail in
                ScheduleDetailSheet(detail: detail)
                    .presentationDetents([.medium])
            }
        }
    }
}

private struct SimpleMetricColumn: View {
    let label: String
    let value: String
    let valueColor: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit().weight(.bold))
                .foregroundStyle(valueColor)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MinimalAGPChart: View {
    let bins: [AGPBin]
    let unit: BGUnit

    var body: some View {
        Chart {
            RuleMark(y: .value("Low", unit.fromMgdL(70.0)))
                .foregroundStyle(.red.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            RuleMark(y: .value("High", unit.fromMgdL(180.0)))
                .foregroundStyle(.orange.opacity(0.35))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

            ForEach(bins) { bin in
                let hour = Double(bin.minuteOfDay) / 60.0
                AreaMark(
                    x: .value("Hour", hour),
                    yStart: .value("P25", unit.fromMgdL(bin.p25MgdL)),
                    yEnd: .value("P75", unit.fromMgdL(bin.p75MgdL))
                )
                .foregroundStyle(.blue.opacity(0.20))

                LineMark(
                    x: .value("Hour", hour),
                    y: .value("Median", unit.fromMgdL(bin.p50MgdL))
                )
                .foregroundStyle(.blue)
                .lineStyle(StrokeStyle(lineWidth: 2.2))
            }
        }
        .chartXScale(domain: 0...24)
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { val in
                AxisGridLine()
                AxisValueLabel {
                    if let h = val.as(Int.self) {
                        Text(String(format: "%02d:00", h % 24))
                    }
                }
            }
        }
        .frame(height: 155)
    }
}
