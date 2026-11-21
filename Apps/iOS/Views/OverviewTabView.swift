import Charts
import NightscoutAdvisorKit
import SwiftUI

struct OverviewTabView: View {
    @ObservedObject var viewModel: AdvisorViewModel
    let report: AdvisorReport

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if viewModel.isDemoMode {
                        HStack {
                            Image(systemName: "sparkles")
                            Text("Synthetic Demo Telemetry — Add your Nightscout URL in the Nightscout tab.")
                                .font(.caption.weight(.medium))
                            Spacer()
                        }
                        .padding(10)
                        .background(Color.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
                    }

                    // Profile & Sync Summary Header
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(report.activeProfileName)
                                .font(.headline)
                            Text("\(report.timeZoneIdentifier) • \(report.displayUnit.rawValue) • \(report.rollingDays)d window")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(report.alignedSectionCount)/4 In CI")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                report.alignedSectionCount == 4 ? Color.green.opacity(0.18) : Color.orange.opacity(0.18),
                                in: Capsule()
                            )
                            .foregroundStyle(report.alignedSectionCount == 4 ? .green : .orange)
                    }
                    .padding()
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

                    // Rolling Glycemic Cards (24h, 7d, 30d)
                    VStack(spacing: 10) {
                        GlycemicStatsCard(stats: report.stats24h, unit: report.displayUnit)
                        GlycemicStatsCard(stats: report.stats7d, unit: report.displayUnit)
                        GlycemicStatsCard(stats: report.statsRolling, unit: report.displayUnit)
                    }

                    // 24-Hour Ambulatory Glucose Profile (AGP) Chart
                    AGPFanChartCard(bins: report.agpBins, unit: report.displayUnit)

                    // Closed-Loop Control Stability Audit Card
                    StabilityAuditCard(stability: report.stability, unit: report.displayUnit)

                    // Daily Metabolic Totals
                    HStack(spacing: 12) {
                        MetricTile(
                            title: "Avg Daily Insulin",
                            value: String(format: "%.1f U/d", report.averageDailyInsulinUnits),
                            subtitle: "Basal + AutoBolus"
                        )
                        MetricTile(
                            title: "Avg Daily Carbs",
                            value: String(format: "%.0f g/d", report.averageDailyCarbsGrams),
                            subtitle: "Logged Entries"
                        )
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Nightscout Advisor")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            if viewModel.isDemoMode && !viewModel.hasNightscoutURL {
                                await viewModel.loadDemoTelemetry(units: report.displayUnit)
                            } else {
                                await viewModel.refreshFromNightscout()
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }
}

private struct GlycemicStatsCard: View {
    let stats: GlycemicWindowStats
    let unit: BGUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(stats.label)
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("Mean \(unit.formatBG(stats.meanMgdL, includeUnit: true)) • GMI \(String(format: "%.1f%%", stats.gmiPercent)) • CV \(String(format: "%.0f%%", stats.cvPercent))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 14) {
                StatPill(title: "TIR", value: String(format: "%.1f%%", stats.tirPercent), color: .green)
                StatPill(title: "TBR <70", value: String(format: "%.1f%%", stats.tbrPercent), color: stats.tbrPercent <= 4.0 ? .teal : .red)
                StatPill(title: "<54", value: String(format: "%.1f%%", stats.veryLowPercent), color: stats.veryLowPercent <= 1.0 ? .secondary : .red)
                StatPill(title: "TAR >180", value: String(format: "%.1f%%", stats.tarPercent), color: .orange)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct StatPill: View {
    let title: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.monospacedDigit().weight(.bold))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AGPFanChartCard: View {
    let bins: [AGPBin]
    let unit: BGUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("24-Hour Ambulatory Glucose Profile (AGP)")
                    .font(.subheadline.weight(.bold))
                Spacer()
                Text("P10–P90 • IQR • Median")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Chart {
                RuleMark(y: .value("Low", unit.fromMgdL(70.0)))
                    .foregroundStyle(.red.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                RuleMark(y: .value("High", unit.fromMgdL(180.0)))
                    .foregroundStyle(.orange.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))

                ForEach(bins) { bin in
                    let hour = Double(bin.minuteOfDay) / 60.0
                    AreaMark(
                        x: .value("Hour", hour),
                        yStart: .value("P10", unit.fromMgdL(bin.p10MgdL)),
                        yEnd: .value("P90", unit.fromMgdL(bin.p90MgdL))
                    )
                    .foregroundStyle(.blue.opacity(0.12))

                    AreaMark(
                        x: .value("Hour", hour),
                        yStart: .value("P25", unit.fromMgdL(bin.p25MgdL)),
                        yEnd: .value("P75", unit.fromMgdL(bin.p75MgdL))
                    )
                    .foregroundStyle(.blue.opacity(0.26))

                    LineMark(
                        x: .value("Hour", hour),
                        y: .value("Median", unit.fromMgdL(bin.p50MgdL))
                    )
                    .foregroundStyle(.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2.2))
                }
            }
            .chartXScale(domain: 0...24)
            .frame(height: 190)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct StabilityAuditCard: View {
    let stability: ControlStabilityAudit
    let unit: BGUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Closed-Loop Control Stability", systemImage: "checkmark.shield.fill")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(stability.isOverdampedStable ? .green : .orange)
                Spacer()
                Text(String(format: "ζ = %.2f", stability.dampingRatioZeta))
                    .font(.subheadline.monospacedDigit().weight(.bold))
            }

            Text(stability.poleSummary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)

            HStack {
                Text("Crit ISF Bound: \(unit.formatISF(stability.criticalISFBoundMgdLPerU))")
                Spacer()
                Text(String(format: "Gain %.2fx • Phase %.0f°", stability.gainMarginMultiplier, stability.phaseMarginDegrees))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct MetricTile: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }
}
