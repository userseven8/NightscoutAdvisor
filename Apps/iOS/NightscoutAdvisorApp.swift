import NightscoutAdvisorKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

@main
struct NightscoutAdvisorApp: App {
    @StateObject private var viewModel = AdvisorViewModel()

    var body: some Scene {
        #if os(macOS)
        WindowGroup("NS Advisor", id: "main") {
            RootContentView(viewModel: viewModel)
                .frame(minWidth: 640, minHeight: 680)
        }
        .defaultSize(width: 740, height: 840)

        MenuBarExtra {
            MacMenuBarPopoverView(viewModel: viewModel)
        } label: {
            if let report = viewModel.report {
                let count = report.totalAdjustmentsCount
                if count == 0 {
                    Image(systemName: "checkmark.circle")
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath.circle")
                        Text("\(count)")
                    }
                }
            } else {
                Image(systemName: "waveform.path.ecg")
            }
        }
        .menuBarExtraStyle(.window)
        #else
        WindowGroup {
            RootContentView(viewModel: viewModel)
        }
        #endif
    }
}

#if os(macOS)
private struct MacMenuBarPopoverView: View {
    @ObservedObject var viewModel: AdvisorViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let report = viewModel.report {
                let sum = report.makeWatchSummary()
                let count = sum.effectiveAdjustmentsCount

                HStack(spacing: 8) {
                    Image(systemName: count == 0 ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                        .font(.title3)
                        .foregroundStyle(count == 0 ? Color.green : Color.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(count == 0 ? "Within 95% CI" : "\(count) Window\(count == 1 ? "" : "s") Outside CI")
                            .font(.headline)
                        Text("Last \(report.rollingDays)d • TIR \(String(format: "%.1f%%", report.statsRolling.tirPercent)) • Low \(String(format: "%.1f%%", report.statsRolling.tbrPercent)) • GMI \(String(format: "%.1f%%", report.statsRolling.gmiPercent))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                Divider()

                VStack(spacing: 6) {
                    MacMenuRow(label: "Sensitivity (ISF)", value: sum.headlineISF, isAligned: sum.isfAligned)
                    MacMenuRow(label: "Basal Rates", value: sum.headlineBasal ?? "In Range", isAligned: sum.basalAligned)
                    MacMenuRow(label: "Carb Ratios", value: sum.headlineCR ?? "In Range", isAligned: sum.crAligned)
                    MacMenuRow(label: "Target Range", value: sum.headlineTarget, isAligned: sum.targetAligned)
                }

                Divider()
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "waveform.path.ecg")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(viewModel.hasAcceptedDIYDisclaimer ? "Connect Nightscout in the main window." : "Accept safety notice in the main window to begin.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Divider()
            }

            HStack {
                if viewModel.hasAcceptedDIYDisclaimer && viewModel.hasNightscoutURL {
                    Button {
                        Task { await viewModel.refreshFromNightscout() }
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.isLoading)
                }

                Button("Open Window") {
                    openWindow(id: "main")
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }

                Spacer()

                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
            .font(.caption)
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct MacMenuRow: View {
    let label: String
    let value: String
    let isAligned: Bool

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline.monospacedDigit().weight(isAligned ? .regular : .semibold))
                .foregroundStyle(isAligned ? Color.primary : Color.orange)
            Image(systemName: isAligned ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                .font(.caption)
                .foregroundStyle(isAligned ? Color.green : Color.orange)
        }
    }
}
#endif
