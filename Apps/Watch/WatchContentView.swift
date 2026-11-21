import NightscoutAdvisorKit
import SwiftUI

struct WatchContentView: View {
    @ObservedObject var model: WatchAdvisorViewModel
    @ObservedObject private var bridge = WatchSyncBridge.shared

    private var activeSummary: WatchAdvisorSummary? {
        bridge.latestWatchSummary ?? model.summary
    }

    var body: some View {
        NavigationStack {
            if let sum = activeSummary {
                let count = sum.effectiveAdjustmentsCount
                ScrollView {
                    VStack(spacing: 8) {
                        // 1. Advisor Status Headline
                        HStack(spacing: 6) {
                            Image(systemName: count == 0 ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                                .font(.callout)
                                .foregroundStyle(count == 0 ? Color.green : Color.orange)
                            Text(count == 0 ? "All In Sync" : "\(count) Update\(count == 1 ? "" : "s")")
                                .font(.footnote.weight(.bold))
                            Spacer()
                        }
                        .padding(.horizontal, 4)

                        // Surface up to 2 top action lines above the 4-schedule overview
                        if !sum.effectiveActions.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(sum.effectiveActions.prefix(2)), id: \.self) { act in
                                    Text(act)
                                        .font(.caption2.monospacedDigit().weight(.semibold))
                                        .foregroundStyle(Color.orange)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(6)
                            .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                        }

                        Divider()

                        // 2. Clean 4-Schedule Overview
                        VStack(spacing: 6) {
                            SimpleWatchRow(label: "ISF", value: sum.headlineISF, isAligned: sum.isfAligned)
                            SimpleWatchRow(
                                label: "Basal",
                                value: sum.headlineBasal ?? (sum.basalAligned ? "OK" : "Review"),
                                isAligned: sum.basalAligned
                            )
                            SimpleWatchRow(
                                label: "Carbs",
                                value: sum.headlineCR ?? (sum.crAligned ? "OK" : "Review"),
                                isAligned: sum.crAligned
                            )
                            SimpleWatchRow(label: "Target", value: sum.headlineTarget, isAligned: sum.targetAligned)
                        }

                        Divider()

                        // Subtle Rolling Window Context
                        HStack {
                            Text("\(sum.effectiveDays)d TIR \(String(format: "%.0f%%", sum.effectiveTIR))")
                            Spacer()
                            Text("Low \(String(format: "%.1f%%", sum.effectiveTBR))")
                        }
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)

                        Button {
                            Task { await model.refreshOnWatch() }
                        } label: {
                            if model.isLoading {
                                ProgressView()
                            } else {
                                Label("Refresh", systemImage: "arrow.clockwise")
                                    .font(.caption)
                            }
                        }
                        .padding(.top, 2)
                    }
                    .padding(.horizontal, 2)
                }
                .navigationTitle("NS Advisor")
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.title3)
                        .foregroundStyle(.teal)
                    Text("Connect Nightscout on your iPhone first.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                    if !model.urlString.isEmpty {
                        Button("Sync Now") {
                            Task { await model.refreshOnWatch() }
                        }
                        .font(.caption)
                    }
                }
                .padding()
                .navigationTitle("NS Advisor")
            }
        }
    }
}

private struct SimpleWatchRow: View {
    let label: String
    let value: String
    let isAligned: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit().weight(isAligned ? .regular : .bold))
                .foregroundStyle(isAligned ? Color.primary : Color.orange)
            Image(systemName: isAligned ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                .font(.caption2)
                .foregroundStyle(isAligned ? Color.green : Color.orange)
        }
        .padding(.horizontal, 4)
    }
}
