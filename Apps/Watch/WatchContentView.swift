import NightscoutAdvisorKit
import SwiftUI

struct WatchContentView: View {
    @ObservedObject var model: WatchAdvisorViewModel
    @ObservedObject private var bridge = WatchSyncBridge.shared

    private var activeSummary: WatchAdvisorSummary? {
        bridge.latestWatchSummary ?? model.summary
    }

    var body: some View {
        TabView {
            // Page 1: Glanceable TIR & Stability Gauge
            ScrollView {
                if let sum = activeSummary {
                    VStack(spacing: 8) {
                        Gauge(value: min(100.0, max(0.0, sum.tir7d)), in: 0...100) {
                            Text("7d TIR")
                        } currentValueLabel: {
                            Text(String(format: "%.0f%%", sum.tir7d))
                                .font(.system(.headline, design: .rounded).weight(.bold))
                        }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(sum.tir7d >= 70.0 ? .green : .orange)
                        .scaleEffect(1.15)
                        .padding(.top, 4)

                        HStack(spacing: 10) {
                            VStack {
                                Text("24h TIR")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.0f%%", sum.tir24h))
                                    .font(.caption.monospacedDigit().weight(.bold))
                                    .foregroundStyle(.green)
                            }
                            VStack {
                                Text("TBR <70")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.1f%%", sum.tbr7d))
                                    .font(.caption.monospacedDigit().weight(.bold))
                                    .foregroundStyle(sum.tbr7d <= 4.0 ? .teal : .red)
                            }
                            VStack {
                                Text("ζ Stab")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                Text(String(format: "%.2f", sum.dampingZeta))
                                    .font(.caption.monospacedDigit().weight(.bold))
                            }
                        }

                        Text("\(sum.alignedSections)/4 Schedules In 95% CI")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(sum.alignedSections == 4 ? .green : .orange)
                    }
                    .padding(.horizontal, 4)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "applewatch.radiowaves.left.and.right")
                            .font(.title2)
                            .foregroundStyle(.teal)
                        Text("Sync via iPhone or Load Demo")
                            .font(.caption)
                            .multilineTextAlignment(.center)
                        Button("Load Demo") {
                            Task { await model.loadDemoOnWatch() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.teal)
                    }
                    .padding()
                }
            }

            // Page 2: 4-Stage Schedule Sync Checklist
            List {
                if let sum = activeSummary {
                    WatchSyncRow(title: "1. Sensitivity (ISF)", detail: sum.headlineISF, isAligned: sum.isfAligned)
                    WatchSyncRow(title: "2. Basal Quantile", detail: sum.basalAligned ? "In 95% CI" : "Review Block", isAligned: sum.basalAligned)
                    WatchSyncRow(title: "3. Carb Ratios", detail: sum.crAligned ? "In 95% CI" : "Review WLS", isAligned: sum.crAligned)
                    WatchSyncRow(title: "4. Target Range", detail: sum.headlineTarget, isAligned: sum.targetAligned)
                } else {
                    Text("No telemetry loaded yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Page 3: Standalone Watch Refresh & Nightscout URL
            ScrollView {
                VStack(spacing: 8) {
                    TextField("Nightscout URL", text: $model.urlString)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task { await model.refreshOnWatch() }
                    } label: {
                        if model.isLoading {
                            ProgressView()
                        } else {
                            Label("Sync Nightscout", systemImage: "arrow.clockwise")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(model.isLoading)

                    Button("Demo Data") {
                        Task { await model.loadDemoOnWatch() }
                    }
                    .font(.caption2)

                    if let status = model.statusText {
                        Text(status)
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .tabViewStyle(.verticalPage)
    }
}

private struct WatchSyncRow: View {
    let title: String
    let detail: String
    let isAligned: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: isAligned ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(isAligned ? .green : .orange)
        }
    }
}
