import NightscoutAdvisorKit
import SwiftUI

struct ScheduleDetailItem: Identifiable {
    let id = UUID()
    let category: String
    let timeWindow: String
    let currentValue: String
    let suggestedValue: String
    let confidenceRange: String
    let status: SyncStatus
    let details: String
}

struct SchedulesSectionGroup: View {
    let report: AdvisorReport
    let onSelectDetail: (ScheduleDetailItem) -> Void

    var body: some View {
        // 1. Sensitivity (ISF)
        Section("Sensitivity (ISF)") {
            ForEach(report.isfSchedule) { item in
                let cur = report.displayUnit.formatISF(item.currentMgdLPerU)
                let rec = report.displayUnit.formatISF(item.recommendedMgdLPerU)
                CleanScheduleRow(
                    timeText: item.timeString,
                    currentText: cur,
                    suggestedText: rec,
                    status: item.status
                ) {
                    onSelectDetail(
                        ScheduleDetailItem(
                            category: "Sensitivity (ISF)",
                            timeWindow: item.windowLabel,
                            currentValue: cur,
                            suggestedValue: rec,
                            confidenceRange: "\(report.displayUnit.formatISF(item.ciLowMgdLPerU, includeUnit: false)) – \(report.displayUnit.formatISF(item.ciHighMgdLPerU))",
                            status: item.status,
                            details: item.rationale
                        )
                    )
                }
            }
        }

        // 2. Basal Rates
        Section("Basal Rates") {
            ForEach(report.basalSchedule) { item in
                let cur = String(format: "%.2f U/hr", item.currentUnitsPerHour)
                let rec = String(format: "%.2f U/hr", item.recommendedUnitsPerHour)
                CleanScheduleRow(
                    timeText: item.timeString,
                    currentText: cur,
                    suggestedText: rec,
                    status: item.status
                ) {
                    onSelectDetail(
                        ScheduleDetailItem(
                            category: "Basal Rate",
                            timeWindow: item.windowLabel,
                            currentValue: cur,
                            suggestedValue: rec,
                            confidenceRange: String(format: "%.2f – %.2f U/hr", item.ciLowUnitsPerHour, item.ciHighUnitsPerHour),
                            status: item.status,
                            details: item.rationale
                        )
                    )
                }
            }
        }

        // 3. Carb Ratios
        Section("Carb Ratios") {
            ForEach(report.carbRatioSchedule) { item in
                let cur = String(format: "1:%.1f g/U", item.currentGramsPerUnit)
                let rec = String(format: "1:%.1f g/U", item.recommendedGramsPerUnit)
                CleanScheduleRow(
                    timeText: item.timeString,
                    currentText: cur,
                    suggestedText: rec,
                    status: item.status
                ) {
                    onSelectDetail(
                        ScheduleDetailItem(
                            category: "Carb Ratio",
                            timeWindow: item.windowLabel,
                            currentValue: cur,
                            suggestedValue: rec,
                            confidenceRange: String(format: "1:%.1f – 1:%.1f g/U", item.ciLowGramsPerUnit, item.ciHighGramsPerUnit),
                            status: item.status,
                            details: item.rationale
                        )
                    )
                }
            }
        }

        // 4. Target Range
        Section("Target Range") {
            ForEach(report.targetSchedule) { item in
                let cur = "\(report.displayUnit.formatBG(item.currentLowMgdL))–\(report.displayUnit.formatBG(item.currentHighMgdL, includeUnit: true))"
                let rec = "\(report.displayUnit.formatBG(item.recommendedLowMgdL))–\(report.displayUnit.formatBG(item.recommendedHighMgdL, includeUnit: true))"
                CleanScheduleRow(
                    timeText: item.timeString,
                    currentText: cur,
                    suggestedText: rec,
                    status: item.status
                ) {
                    onSelectDetail(
                        ScheduleDetailItem(
                            category: "Target Range",
                            timeWindow: item.windowLabel,
                            currentValue: cur,
                            suggestedValue: rec,
                            confidenceRange: "Midpoint \(report.displayUnit.formatBG(item.ciMidLowMgdL)) – \(report.displayUnit.formatBG(item.ciMidHighMgdL, includeUnit: true))",
                            status: item.status,
                            details: item.rationale
                        )
                    )
                }
            }
        }
    }
}

private struct CleanScheduleRow: View {
    let timeText: String
    let currentText: String
    let suggestedText: String
    let status: SyncStatus
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                Text(timeText)
                    .font(.body.monospacedDigit().weight(.medium))
                    .foregroundStyle(.primary)

                Spacer()

                if status.isAlignedOrInCI {
                    Text(currentText)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.green)
                } else {
                    Text(currentText)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .strikethrough()
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.orange)
                    Text(suggestedText)
                        .font(.body.monospacedDigit().weight(.bold))
                        .foregroundStyle(.orange)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ScheduleDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let detail: ScheduleDetailItem

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Window", value: detail.timeWindow)
                    LabeledContent("Active Profile", value: detail.currentValue)
                    LabeledContent("Empirical Estimate", value: detail.suggestedValue)
                    LabeledContent("95% Confidence Interval", value: detail.confidenceRange)
                    LabeledContent("Alignment", value: detail.status.badgeTitle)
                }

                Section {
                    Text(detail.details)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Statistical Derivation")
                } footer: {
                    Text("Informational retrospective telemetry summary (#WeAreNotWaiting). Never modify pump or closed-loop parameters without clinician review.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle(detail.category)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
