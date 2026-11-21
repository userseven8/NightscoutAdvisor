import Charts
import NightscoutAdvisorKit
import SwiftUI

struct OverviewTabView: View {
    @ObservedObject var viewModel: AdvisorViewModel
    let report: AdvisorReport
    let onOpenSettings: () -> Void

    @State private var selectedDetail: ScheduleDetailItem?

    private var stats: GlycemicWindowStats {
        report.statsRolling
    }

    var body: some View {
        NavigationStack {
            List {
                // 1. Unified History Window Statistics + 24-Hour AGP Together
                Section("Last \(report.rollingDays) Days") {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(spacing: 0) {
                            SimpleMetricColumn(
                                label: "In Range",
                                value: String(format: "%.1f%%", stats.tirPercent),
                                valueColor: stats.tirPercent >= 70.0 ? Color.green : Color.primary
                            )
                            SimpleMetricColumn(
                                label: "Low <70",
                                value: String(format: "%.1f%%", stats.tbrPercent),
                                valueColor: stats.tbrPercent <= 4.0 ? Color.primary : Color.red
                            )
                            SimpleMetricColumn(
                                label: "Average",
                                value: report.displayUnit.formatBG(stats.meanMgdL),
                                valueColor: Color.primary
                            )
                            SimpleMetricColumn(
                                label: "GMI",
                                value: String(format: "%.1f%%", stats.gmiPercent),
                                valueColor: Color.secondary
                            )
                        }

                        Divider()

                        MinimalAGPChart(bins: report.agpBins, unit: report.displayUnit)
                    }
                    .padding(.vertical, 6)
                }

                // 2. Therapy Settings Verdict Banner
                Section {
                    HStack(spacing: 10) {
                        let changes = report.totalAdjustmentsCount
                        Image(systemName: changes == 0 ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                            .font(.title3)
                            .foregroundStyle(changes == 0 ? Color.green : Color.orange)
                        Text(changes == 0 ? "All Settings Look Good" : "\(changes) Adjustment\(changes == 1 ? "" : "s") Suggested")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }

                // 3. Clean Single-Line Therapy Schedules
                SchedulesSectionGroup(
                    report: report,
                    onSelectDetail: { selectedDetail = $0 }
                )
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
        .frame(height: 150)
    }
}
