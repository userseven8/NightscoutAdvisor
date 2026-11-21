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
                ScrollView {
                    VStack(spacing: 10) {
                        // Top Glanceable TIR & Low (matches chosen rolling window)
                        HStack(alignment: .lastTextBaseline) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text("\(sum.effectiveDays)d In Range")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.0f%%", sum.effectiveTIR))
                                    .font(.system(.title2, design: .rounded).monospacedDigit().weight(.bold))
                                    .foregroundStyle(sum.effectiveTIR >= 70.0 ? Color.green : Color.primary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 0) {
                                Text("Low")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.1f%%", sum.effectiveTBR))
                                    .font(.callout.monospacedDigit().weight(.semibold))
                                    .foregroundStyle(sum.effectiveTBR <= 4.0 ? Color.secondary : Color.red)
                            }
                        }
                        .padding(.horizontal, 4)

                        Divider()

                        // 4 Clean Setting Rows
                        VStack(spacing: 6) {
                            SimpleWatchRow(
                                label: "ISF",
                                value: sum.headlineISF,
                                isAligned: sum.isfAligned
                            )
                            SimpleWatchRow(
                                label: "Basal",
                                value: sum.headlineBasal ?? (sum.basalAligned ? "OK" : "Adjust"),
                                isAligned: sum.basalAligned
                            )
                            SimpleWatchRow(
                                label: "Carbs",
                                value: sum.headlineCR ?? (sum.crAligned ? "OK" : "Adjust"),
                                isAligned: sum.crAligned
                            )
                            SimpleWatchRow(
                                label: "Target",
                                value: sum.headlineTarget,
                                isAligned: sum.targetAligned
                            )
                        }

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
                        .padding(.top, 4)
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
