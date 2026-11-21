import Foundation
import NightscoutAdvisorKit
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif
#if canImport(WidgetKit)
import WidgetKit
#endif

public final class WatchSyncBridge: NSObject, ObservableObject, @unchecked Sendable {
    public static let shared = WatchSyncBridge()

    @Published public private(set) var latestWatchSummary: WatchAdvisorSummary?

    private let summaryContextKey = "watch_advisor_summary_json"
    private let credsContextKey = "nightscout_creds_json"
    private let configContextKey = "therapy_config_json"

    private override init() {
        super.init()
        self.latestWatchSummary = AdvisorStore.shared.loadWatchSummary()
    }

    public func activate() {
        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        #endif
    }

    public func pushToCompanion(
        summary: WatchAdvisorSummary,
        credentials: NightscoutCredentials,
        config: TherapySettingsConfig
    ) {
        AdvisorStore.shared.saveWatchSummary(summary)
        DispatchQueue.main.async {
            self.latestWatchSummary = summary
        }
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif

        #if canImport(WatchConnectivity)
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        #if os(iOS)
        guard session.isPaired && session.isWatchAppInstalled else { return }
        #endif

        let payload = encodePayload(summary: summary, credentials: credentials, config: config)
        try? session.updateApplicationContext(payload)
        #if os(iOS)
        if session.isComplicationEnabled {
            session.transferCurrentComplicationUserInfo(payload)
        } else {
            session.transferUserInfo(payload)
        }
        #endif
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        #endif
    }

    private func encodePayload(
        summary: WatchAdvisorSummary,
        credentials: NightscoutCredentials,
        config: TherapySettingsConfig
    ) -> [String: Any] {
        var payload: [String: Any] = ["ts": Date().timeIntervalSince1970]
        if let sData = try? JSONEncoder().encode(summary) {
            payload[summaryContextKey] = sData
        }
        if let cData = try? JSONEncoder().encode(credentials) {
            payload[credsContextKey] = cData
        }
        if let cfgData = try? JSONEncoder().encode(config) {
            payload[configContextKey] = cfgData
        }
        return payload
    }
}

#if canImport(WatchConnectivity)
extension WatchSyncBridge: WCSessionDelegate {
    public func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else { return }
        let existing = session.receivedApplicationContext
        if !existing.isEmpty {
            handleIncomingPayload(existing)
        }
        #if os(iOS)
        // Automatically push latest cached report to Watch whenever iOS session activates
        if session.isPaired && session.isWatchAppInstalled,
           let cachedReport = AdvisorStore.shared.loadCachedReport() {
            let freshSummary = cachedReport.makeWatchSummary()
            AdvisorStore.shared.saveWatchSummary(freshSummary)
            let creds = AdvisorStore.shared.loadCredentials()
            let cfg = AdvisorStore.shared.loadConfig()
            let payload = encodePayload(summary: freshSummary, credentials: creds, config: cfg)
            try? session.updateApplicationContext(payload)
            if session.isComplicationEnabled {
                session.transferCurrentComplicationUserInfo(payload)
            }
            if session.isReachable {
                session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
            }
        }
        #endif
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleIncomingPayload(applicationContext)
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handleIncomingPayload(userInfo)
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleIncomingPayload(message)
    }

    private func handleIncomingPayload(_ context: [String: Any]) {
        if let cData = context[credsContextKey] as? Data,
           let creds = try? JSONDecoder().decode(NightscoutCredentials.self, from: cData),
           !creds.baseURLString.isEmpty {
            AdvisorStore.shared.saveCredentials(creds)
        }
        if let cfgData = context[configContextKey] as? Data,
           let cfg = try? JSONDecoder().decode(TherapySettingsConfig.self, from: cfgData) {
            AdvisorStore.shared.saveConfig(cfg)
        }
        if let sData = context[summaryContextKey] as? Data,
           let summary = try? JSONDecoder().decode(WatchAdvisorSummary.self, from: sData) {
            AdvisorStore.shared.saveWatchSummary(summary)
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
            DispatchQueue.main.async {
                self.latestWatchSummary = summary
            }
        }
    }
}
#endif
