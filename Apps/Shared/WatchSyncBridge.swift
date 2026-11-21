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
    private let requestSyncKey = "request_sync_from_watch"

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

    public func requestImmediatePullFromPhone() {
        #if os(watchOS) && canImport(WatchConnectivity)
        let session = WCSession.default
        guard session.activationState == .activated else {
            session.activate()
            return
        }
        let existing = session.receivedApplicationContext
        if !existing.isEmpty {
            handleIncomingPayload(existing)
        }
        if session.isReachable {
            session.sendMessage([requestSyncKey: true]) { [weak self] reply in
                self?.handleIncomingPayload(reply)
            } errorHandler: { _ in }
        }
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
        guard session.isPaired else { return }
        #endif

        let payload = encodePayload(summary: summary, credentials: credentials, config: config)
        try? session.updateApplicationContext(payload)
        #if os(iOS)
        if session.isComplicationEnabled {
            session.transferCurrentComplicationUserInfo(payload)
        }
        session.transferUserInfo(payload)
        #endif
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        #endif
    }

    private func pushLatestFromPhoneIfAvailable(_ session: WCSession) {
        #if os(iOS) && canImport(WatchConnectivity)
        guard session.activationState == .activated, session.isPaired else { return }
        let creds = AdvisorStore.shared.loadCredentials()
        let cfg = AdvisorStore.shared.loadConfig()
        let summary = AdvisorStore.shared.loadCachedReport()?.makeWatchSummary() ?? AdvisorStore.shared.loadWatchSummary()
        if let summary {
            AdvisorStore.shared.saveWatchSummary(summary)
        }
        guard summary != nil || creds.normalizedBaseURL != nil else { return }
        let payload = encodePayload(summary: summary, credentials: creds, config: cfg)
        try? session.updateApplicationContext(payload)
        if session.isComplicationEnabled {
            session.transferCurrentComplicationUserInfo(payload)
        }
        session.transferUserInfo(payload)
        if session.isReachable {
            session.sendMessage(payload, replyHandler: nil, errorHandler: nil)
        }
        #endif
    }

    private func encodePayload(
        summary: WatchAdvisorSummary?,
        credentials: NightscoutCredentials,
        config: TherapySettingsConfig
    ) -> [String: Any] {
        var payload: [String: Any] = ["ts": Date().timeIntervalSince1970]
        if let summary, let sData = try? JSONEncoder().encode(summary) {
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
        pushLatestFromPhoneIfAvailable(session)
        #elseif os(watchOS)
        if session.isReachable {
            session.sendMessage([requestSyncKey: true]) { [weak self] reply in
                self?.handleIncomingPayload(reply)
            } errorHandler: { _ in }
        }
        #endif
    }

    public func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        #if os(iOS)
        pushLatestFromPhoneIfAvailable(session)
        #elseif os(watchOS)
        session.sendMessage([requestSyncKey: true]) { [weak self] reply in
            self?.handleIncomingPayload(reply)
        } errorHandler: { _ in }
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

    public func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        #if os(iOS)
        if message[requestSyncKey] as? Bool == true {
            let creds = AdvisorStore.shared.loadCredentials()
            let cfg = AdvisorStore.shared.loadConfig()
            let summary = AdvisorStore.shared.loadCachedReport()?.makeWatchSummary() ?? AdvisorStore.shared.loadWatchSummary()
            replyHandler(encodePayload(summary: summary, credentials: creds, config: cfg))
            return
        }
        #endif
        handleIncomingPayload(message)
        replyHandler([:])
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
