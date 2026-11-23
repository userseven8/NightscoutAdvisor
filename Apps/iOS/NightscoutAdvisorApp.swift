import NightscoutAdvisorKit
import SwiftUI
#if os(macOS)
import AppKit
import ServiceManagement
#endif

@main
struct NightscoutAdvisorApp: App {
    @StateObject private var viewModel = AdvisorViewModel()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        #if os(macOS)
        Window("NS Advisor", id: "main") {
            RootContentView(viewModel: viewModel)
                .frame(minWidth: 640, minHeight: 680)
                .background(MacMainWindowLifecycleObserver())
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
@MainActor
final class MacStartupPreferences: ObservableObject {
    static let shared = MacStartupPreferences()

    private let menuBarOnlyKey = "mac_menu_bar_only_mode_v1"

    @Published var launchAtLogin: Bool {
        didSet {
            guard oldValue != launchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Revert toggle if macOS rejects Login Item registration (e.g. running outside /Applications)
                let actual = (SMAppService.mainApp.status == .enabled)
                if launchAtLogin != actual {
                    launchAtLogin = actual
                }
            }
        }
    }

    @Published var menuBarOnlyMode: Bool {
        didSet {
            UserDefaults.standard.set(menuBarOnlyMode, forKey: menuBarOnlyKey)
            applyActivationPolicy(mainWindowVisible: Self.isMainWindowVisible)
        }
    }

    private init() {
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        if UserDefaults.standard.object(forKey: menuBarOnlyKey) == nil {
            self.menuBarOnlyMode = false
        } else {
            self.menuBarOnlyMode = UserDefaults.standard.bool(forKey: menuBarOnlyKey)
        }
    }

    func refreshStatusFromSystem() {
        let actual = (SMAppService.mainApp.status == .enabled)
        if launchAtLogin != actual {
            launchAtLogin = actual
        }
    }

    static var didHandleInitialLaunch = false

    static var needsOnboarding: Bool {
        !AdvisorStore.shared.hasAcknowledgedDIYDisclaimer()
            || (AdvisorStore.shared.loadCredentials().normalizedBaseURL == nil
                && AdvisorStore.shared.loadCachedReport() == nil)
    }

    static var isMainWindowVisible: Bool {
        NSApplication.shared.windows.contains { win in
            win.isVisible && win.title == "NS Advisor"
        }
    }

    func applyActivationPolicy(mainWindowVisible: Bool) {
        if menuBarOnlyMode && !mainWindowVisible {
            NSApplication.shared.setActivationPolicy(.accessory)
        } else {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }
}

final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let menuOnly = UserDefaults.standard.bool(forKey: "mac_menu_bar_only_mode_v1")
        if menuOnly && !MacStartupPreferences.needsOnboarding {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Keep running in the top Menu Bar when the main window is closed
        false
    }
}

private struct MacMainWindowLifecycleObserver: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                context.coordinator.observe(window: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            if let window = nsView.window {
                context.coordinator.observe(window: window)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject {
        private weak var observedWindow: NSWindow?

        func observe(window: NSWindow) {
            guard observedWindow !== window else { return }
            observedWindow = window
            Task { @MainActor in
                let prefs = MacStartupPreferences.shared
                if !MacStartupPreferences.didHandleInitialLaunch {
                    MacStartupPreferences.didHandleInitialLaunch = true
                    if prefs.menuBarOnlyMode && !MacStartupPreferences.needsOnboarding {
                        window.orderOut(nil)
                        prefs.applyActivationPolicy(mainWindowVisible: false)
                        return
                    }
                }
                prefs.applyActivationPolicy(mainWindowVisible: true)
            }
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        @objc private func windowWillClose(_ notification: Notification) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                MacStartupPreferences.shared.applyActivationPolicy(mainWindowVisible: false)
            }
        }
    }
}

private struct MacMenuBarPopoverView: View {
    @ObservedObject var viewModel: AdvisorViewModel
    @ObservedObject private var macPrefs = MacStartupPreferences.shared
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

            VStack(alignment: .leading, spacing: 6) {
                Toggle("Launch at Login", isOn: $macPrefs.launchAtLogin)
                    .toggleStyle(.checkbox)
                Toggle("Menu Bar Only (Hide Dock & Startup Window)", isOn: $macPrefs.menuBarOnlyMode)
                    .toggleStyle(.checkbox)
            }
            .font(.caption)

            Divider()

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
                    NSApplication.shared.setActivationPolicy(.regular)
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
        .frame(width: 330)
        .onAppear {
            macPrefs.refreshStatusFromSystem()
        }
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
