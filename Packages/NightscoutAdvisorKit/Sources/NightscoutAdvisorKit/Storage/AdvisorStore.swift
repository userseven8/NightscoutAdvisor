import Foundation
import Security

public final class AdvisorStore: @unchecked Sendable {
    public static let shared = AdvisorStore()

    public static let defaultAppGroup = "group.org.nightscout.NightscoutAdvisor"
    private let defaults: UserDefaults
    private let containerURL: URL?

    private let settingsKey = "therapy_settings_config_v2"
    private let reportCacheKey = "cached_advisor_report_v4"
    private let watchSummaryKey = "cached_watch_summary_v4"
    private let sharedCredsKey = "shared_nightscout_creds_v2"
    private let diyDisclaimerAckKey = "diy_safety_disclaimer_ack_v1"

    private let watchSummaryFilename = "watch_summary_v4.json"
    private let sharedCredsFilename = "shared_creds_v2.json"

    private let keychainService = "org.nightscout.NightscoutAdvisor.credentials"
    private let keychainAccount = "nightscout_primary"

    public init(appGroupIdentifier: String? = nil) {
        let infoGroup = (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let bundleDerivedGroup: String? = {
            guard var bid = Bundle.main.bundleIdentifier, !bid.isEmpty else { return nil }
            if bid.hasSuffix(".watchkitapp.widgets") {
                bid = String(bid.dropLast(".watchkitapp.widgets".count))
            } else if bid.hasSuffix(".watchkitapp") {
                bid = String(bid.dropLast(".watchkitapp".count))
            }
            return "group.\(bid)"
        }()
        let resolvedGroup: String = {
            if let explicit = appGroupIdentifier, !explicit.isEmpty { return explicit }
            if let info = infoGroup, !info.isEmpty, !info.contains("$(") { return info }
            if let derived = bundleDerivedGroup { return derived }
            return AdvisorStore.defaultAppGroup
        }()
        if !resolvedGroup.isEmpty, let groupDefaults = UserDefaults(suiteName: resolvedGroup) {
            self.defaults = groupDefaults
        } else {
            self.defaults = .standard
        }
        if !resolvedGroup.isEmpty {
            self.containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: resolvedGroup)
        } else {
            self.containerURL = nil
        }
    }

    // MARK: - Credentials (Keychain + Shared App Group Container for Watch & Complications)

    public func saveCredentials(_ credentials: NightscoutCredentials) {
        guard let encoded = try? JSONEncoder().encode(credentials) else { return }
        defaults.set(encoded, forKey: sharedCredsKey)
        if let dir = containerURL {
            try? encoded.write(to: dir.appendingPathComponent(sharedCredsFilename), options: .atomic)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = encoded
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }

    public func loadCredentials() -> NightscoutCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess,
           let data = item as? Data,
           let creds = try? JSONDecoder().decode(NightscoutCredentials.self, from: data),
           !creds.baseURLString.isEmpty {
            return creds
        }
        if let dir = containerURL,
           let data = try? Data(contentsOf: dir.appendingPathComponent(sharedCredsFilename)),
           let creds = try? JSONDecoder().decode(NightscoutCredentials.self, from: data) {
            return creds
        }
        if let data = defaults.data(forKey: sharedCredsKey),
           let creds = try? JSONDecoder().decode(NightscoutCredentials.self, from: data) {
            return creds
        }
        return NightscoutCredentials()
    }

    // MARK: - DIY Safety & Responsibility Acknowledgment

    public func hasAcknowledgedDIYDisclaimer() -> Bool {
        defaults.bool(forKey: diyDisclaimerAckKey)
    }

    public func setDIYDisclaimerAcknowledged(_ acknowledged: Bool = true) {
        defaults.set(acknowledged, forKey: diyDisclaimerAckKey)
    }

    // MARK: - Therapy Settings Config

    public func saveConfig(_ config: TherapySettingsConfig) {
        if let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: settingsKey)
        }
    }

    public func loadConfig() -> TherapySettingsConfig {
        guard let data = defaults.data(forKey: settingsKey),
              let cfg = try? JSONDecoder().decode(TherapySettingsConfig.self, from: data) else {
            return TherapySettingsConfig()
        }
        return cfg
    }

    // MARK: - Cached Advisor Report & Watch Complication Summary

    public func saveReport(_ report: AdvisorReport) {
        if let data = try? JSONEncoder().encode(report) {
            defaults.set(data, forKey: reportCacheKey)
        }
        saveWatchSummary(report.makeWatchSummary())
    }

    public func loadCachedReport() -> AdvisorReport? {
        guard let data = defaults.data(forKey: reportCacheKey) else { return nil }
        return try? JSONDecoder().decode(AdvisorReport.self, from: data)
    }

    public func saveWatchSummary(_ summary: WatchAdvisorSummary) {
        guard let data = try? JSONEncoder().encode(summary) else { return }
        if let dir = containerURL {
            try? data.write(to: dir.appendingPathComponent(watchSummaryFilename), options: .atomic)
        }
        defaults.set(data, forKey: watchSummaryKey)
    }

    public func loadWatchSummary() -> WatchAdvisorSummary? {
        if let dir = containerURL {
            for fname in [watchSummaryFilename, "watch_summary_v3.json", "watch_summary_v2.json"] {
                if let data = try? Data(contentsOf: dir.appendingPathComponent(fname)),
                   let summary = try? JSONDecoder().decode(WatchAdvisorSummary.self, from: data) {
                    return summary
                }
            }
        }
        for key in [watchSummaryKey, "cached_watch_summary_v3", "cached_watch_summary_v2", "cached_watch_summary_v1"] {
            if let data = defaults.data(forKey: key),
               let summary = try? JSONDecoder().decode(WatchAdvisorSummary.self, from: data) {
                return summary
            }
        }
        return nil
    }
}
