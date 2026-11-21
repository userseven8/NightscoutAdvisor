import Foundation
import NightscoutAdvisorKit
import SwiftUI

@MainActor
final class AdvisorViewModel: ObservableObject {
    @Published var credentials: NightscoutCredentials
    @Published var config: TherapySettingsConfig
    @Published var report: AdvisorReport?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var isDemoMode: Bool = false

    private let store = AdvisorStore.shared
    private let client = NightscoutClient()

    init() {
        let savedCreds = AdvisorStore.shared.loadCredentials()
        let savedConfig = AdvisorStore.shared.loadConfig()
        let cached = AdvisorStore.shared.loadCachedReport()
        self.credentials = savedCreds
        self.config = savedConfig
        self.report = cached
        self.isDemoMode = cached?.sourceURL.hasPrefix("demo://") == true
        WatchSyncBridge.shared.activate()
    }

    var hasNightscoutURL: Bool {
        credentials.normalizedBaseURL != nil
    }

    func saveSettingsAndRefresh() async {
        store.saveCredentials(credentials)
        store.saveConfig(config)
        await refreshFromNightscout()
    }

    func refreshFromNightscout() async {
        guard credentials.normalizedBaseURL != nil else {
            errorMessage = "Enter your Nightscout URL in Settings or load Demo Telemetry to preview."
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let bundle = try await client.fetchTelemetry(
                credentials: credentials,
                rollingDays: config.rollingDays
            )
            let cfgSnapshot = config
            let solved = try await Task.detached(priority: .userInitiated) {
                try TherapyAdvisorSolver.solve(bundle: bundle, config: cfgSnapshot)
            }.value

            self.report = solved
            self.isDemoMode = false
            store.saveReport(solved)
            WatchSyncBridge.shared.pushToCompanion(
                summary: solved.makeWatchSummary(),
                credentials: credentials,
                config: config
            )
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func loadDemoTelemetry(units: BGUnit = .mgdL) async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            var cfgSnapshot = config
            cfgSnapshot.preferredUnitOverride = units
            let solved = try await Task.detached(priority: .userInitiated) {
                let demoBundle = DemoTelemetryGenerator.makeSyntheticBundle(days: cfgSnapshot.rollingDays, units: units)
                return try TherapyAdvisorSolver.solve(bundle: demoBundle, config: cfgSnapshot)
            }.value

            self.report = solved
            self.isDemoMode = true
            store.saveReport(solved)
            WatchSyncBridge.shared.pushToCompanion(
                summary: solved.makeWatchSummary(),
                credentials: credentials,
                config: cfgSnapshot
            )
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }
}
