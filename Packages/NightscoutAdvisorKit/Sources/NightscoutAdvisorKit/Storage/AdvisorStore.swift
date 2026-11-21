import Foundation
import Security

public final class AdvisorStore: @unchecked Sendable {
    public static let shared = AdvisorStore()

    public static let defaultAppGroup = "group.org.nightscout.NightscoutAdvisor"
    private let defaults: UserDefaults
    private let containerURL: URL?

    private let settingsKey = "therapy_settings_config_v2"
    private let reportCacheKey = "cached_advisor_report_v2"
    private let watchSummaryKey = "cached_watch_summary_v2"
    private let sharedCredsKey = "shared_nightscout_creds_v2"

    private let watchSummaryFilename = "watch_summary_v2.json"
    private let sharedCredsFilename = "shared_creds_v2.json"

    private let keychainService = "org.nightscout.NightscoutAdvisor.credentials"
    private let keychainAccount = "nightscout_primary"

    public init(appGroupIdentifier: String? = nil) {
        let resolvedGroup = appGroupIdentifier
            ?? (Bundle.main.object(forInfoDictionaryKey: "AppGroupIdentifier") as? String)
            ?? AdvisorStore.defaultAppGroup
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
        if let dir = containerURL,
           let data = try? Data(contentsOf: dir.appendingPathComponent(watchSummaryFilename)),
           let summary = try? JSONDecoder().decode(WatchAdvisorSummary.self, from: data) {
            return summary
        }
        guard let data = defaults.data(forKey: watchSummaryKey) else { return nil }
        return try? JSONDecoder().decode(WatchAdvisorSummary.self, from: data)
    }
}
