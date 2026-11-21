import NightscoutAdvisorKit
import SwiftUI

@main
struct NightscoutAdvisorWatchApp: App {
    @StateObject private var watchModel = WatchAdvisorViewModel()

    var body: some Scene {
        WindowGroup {
            WatchContentView(model: watchModel)
        }
    }
}

@MainActor
final class WatchAdvisorViewModel: ObservableObject {
    @Published var summary: WatchAdvisorSummary?
    @Published var urlString: String
    @Published var isLoading: Bool = false
    @Published var statusText: String?

    private let store = AdvisorStore.shared
    private let client = NightscoutClient()

    init() {
        WatchSyncBridge.shared.activate()
        self.summary = AdvisorStore.shared.loadWatchSummary()
        self.urlString = AdvisorStore.shared.loadCredentials().baseURLString
    }

    func refreshOnWatch() async {
        var creds = store.loadCredentials()
        if !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            creds.baseURLString = urlString
            store.saveCredentials(creds)
        }
        guard creds.normalizedBaseURL != nil else {
            statusText = "Pair with iPhone or enter Nightscout URL."
            return
        }

        isLoading = true
        statusText = nil
        defer { isLoading = false }

        do {
            let cfg = store.loadConfig()
            let bundle = try await client.fetchTelemetry(credentials: creds, rollingDays: cfg.rollingDays)
            let solvedSummary = try await Task.detached(priority: .userInitiated) {
                let rep = try TherapyAdvisorSolver.solve(bundle: bundle, config: cfg)
                return rep.makeWatchSummary()
            }.value

            self.summary = solvedSummary
            store.saveWatchSummary(solvedSummary)
            WatchSyncBridge.shared.pushToCompanion(summary: solvedSummary, credentials: creds, config: cfg)
        } catch {
            self.statusText = error.localizedDescription
        }
    }

    func loadDemoOnWatch() async {
        isLoading = true
        defer { isLoading = false }
        let cfg = store.loadConfig()
        if let rep = try? TherapyAdvisorSolver.solve(
            bundle: DemoTelemetryGenerator.makeSyntheticBundle(days: 14, units: .mgdL),
            config: cfg
        ) {
            let sum = rep.makeWatchSummary()
            self.summary = sum
            store.saveWatchSummary(sum)
        }
    }
}
