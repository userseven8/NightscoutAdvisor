import NightscoutAdvisorKit
import SwiftUI

struct SchedulesTabView: View {
    let report: AdvisorReport

    var body: some View {
        NavigationStack {
            List {
                // 1. Insulin Sensitivity Factor (ISF)
                Section {
                    ForEach(report.isfSchedule) { item in
                        ScheduleRowCard(
                            timeTitle: item.timeString,
                            windowSubtitle: item.windowLabel,
                            currentText: report.displayUnit.formatISF(item.currentMgdLPerU),
                            recommendedText: report.displayUnit.formatISF(item.recommendedMgdLPerU),
                            ciText: "95% CI: \(report.displayUnit.formatISF(item.ciLowMgdLPerU, includeUnit: false))–\(report.displayUnit.formatISF(item.ciHighMgdLPerU))",
                            status: item.status,
                            rationale: item.rationale,
                            accentColor: .teal
                        )
                    }
                } header: {
                    Text("1. Insulin Sensitivity Factor (ISF)")
                }

                // 2. Basal Schedule
                Section {
                    ForEach(report.basalSchedule) { item in
                        ScheduleRowCard(
                            timeTitle: item.timeString,
                            windowSubtitle: item.windowLabel,
                            currentText: String(format: "%.2f U/hr", item.currentUnitsPerHour),
                            recommendedText: String(format: "%.2f U/hr", item.recommendedUnitsPerHour),
                            ciText: String(format: "95%% CI: %.3f–%.3f U/hr", item.ciLowUnitsPerHour, item.ciHighUnitsPerHour),
                            status: item.status,
                            rationale: item.rationale,
                            accentColor: .blue
                        )
                    }
                } header: {
                    Text("2. Basal Rates (ATTD Closed-Loop Quantile)")
                }

                // 3. Carb Ratios
                Section {
                    ForEach(report.carbRatioSchedule) { item in
                        ScheduleRowCard(
                            timeTitle: item.timeString,
                            windowSubtitle: item.windowLabel,
                            currentText: String(format: "1:%.1f g/U", item.currentGramsPerUnit),
                            recommendedText: String(format: "1:%.1f g/U", item.recommendedGramsPerUnit),
                            ciText: String(format: "95%% CI: 1:%.1f–1:%.1f g/U", item.ciLowGramsPerUnit, item.ciHighGramsPerUnit),
                            status: item.status,
                            rationale: item.rationale,
                            accentColor: .purple
                        )
                    }
                } header: {
                    Text("3. Carb Ratios (Gauss-Markov WLS)")
                }

                // 4. Correction Range (Target)
                Section {
                    ForEach(report.targetSchedule) { item in
                        let curStr = "\(report.displayUnit.formatBG(item.currentLowMgdL))–\(report.displayUnit.formatBG(item.currentHighMgdL, includeUnit: true))"
                        let recStr = "\(report.displayUnit.formatBG(item.recommendedLowMgdL))–\(report.displayUnit.formatBG(item.recommendedHighMgdL, includeUnit: true))"
                        let ciStr = "Midpoint 95% CI: \(report.displayUnit.formatBG(item.ciMidLowMgdL))–\(report.displayUnit.formatBG(item.ciMidHighMgdL, includeUnit: true))"

                        ScheduleRowCard(
                            timeTitle: item.timeString,
                            windowSubtitle: item.windowLabel,
                            currentText: curStr,
                            recommendedText: recStr,
                            ciText: ciStr,
                            status: item.status,
                            rationale: item.rationale,
                            accentColor: .green
                        )
                    }
                } header: {
                    Text("4. Correction Range (ATTD + Kovatchev BGRI)")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Therapy Schedules")
        }
    }
}

private struct ScheduleRowCard: View {
    let timeTitle: String
    let windowSubtitle: String
    let currentText: String
    let recommendedText: String
    let ciText: String
    let status: SyncStatus
    let rationale: String
    let accentColor: Color

    @State private var isExpanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(timeTitle)
                        .font(.headline.monospacedDigit())
                    Text(windowSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                StatusBadgeView(status: status)
            }

            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Current Profile")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(currentText)
                        .font(.subheadline.monospacedDigit().weight(.medium))
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Recommended")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(recommendedText)
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(accentColor)
                }
            }

            HStack {
                Text(ciText)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(isExpanded ? "Hide Proof" : "Evidence")
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(accentColor)
            }

            if isExpanded {
                Text(rationale)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct StatusBadgeView: View {
    let status: SyncStatus

    var badgeColor: Color {
        switch status {
        case .inSync, .inConfidenceInterval: return .green
        case .adjustRecommended: return .orange
        case .insufficientData: return .secondary
        }
    }

    var body: some View {
        Text(status.badgeTitle)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(badgeColor.opacity(0.16), in: Capsule())
            .foregroundStyle(badgeColor)
    }
}
