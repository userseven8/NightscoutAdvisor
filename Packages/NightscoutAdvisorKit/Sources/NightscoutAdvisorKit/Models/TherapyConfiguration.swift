import Foundation

public enum BGUnit: String, Codable, CaseIterable, Sendable {
    case mgdL = "mg/dL"
    case mmolL = "mmol/L"

    public static let mmolConversionFactor: Double = 18.0182

    public static func fromNightscout(_ raw: String?) -> BGUnit {
        guard let lower = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return .mgdL
        }
        return lower.contains("mmol") ? .mmolL : .mgdL
    }

    public func toMgdL(_ value: Double) -> Double {
        switch self {
        case .mgdL: return value
        case .mmolL: return value * Self.mmolConversionFactor
        }
    }

    public func fromMgdL(_ mgdL: Double) -> Double {
        switch self {
        case .mgdL: return mgdL
        case .mmolL: return mgdL / Self.mmolConversionFactor
        }
    }

    public func formatBG(_ mgdL: Double, includeUnit: Bool = false) -> String {
        let converted = fromMgdL(mgdL)
        let numStr = self == .mgdL
            ? String(format: "%.0f", converted)
            : String(format: "%.1f", converted)
        return includeUnit ? "\(numStr) \(rawValue)" : numStr
    }

    public func formatISF(_ mgdLPerU: Double, includeUnit: Bool = true) -> String {
        let converted = fromMgdL(mgdLPerU)
        let numStr = self == .mgdL
            ? String(format: "%.0f", converted)
            : String(format: "%.1f", converted)
        return includeUnit ? "\(numStr) \(rawValue)/U" : numStr
    }
}

public enum InsulinPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case lyumjevFiasp = "lyumjev_fiasp"
    case rapidPediatric = "rapid_pediatric"
    case humalogNovolog = "humalog_novolog"
    case custom = "custom"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .lyumjevFiasp: return "Ultra-Rapid (Lyumjev / Fiasp)"
        case .rapidPediatric: return "Rapid-Acting Child (Humalog / Novolog)"
        case .humalogNovolog: return "Rapid-Acting Adult (Humalog / Novolog / Apidra)"
        case .custom: return "Custom Peak & DIA"
        }
    }

    public var defaultPeakMinutes: Double {
        switch self {
        case .lyumjevFiasp: return 55.0
        case .rapidPediatric: return 65.0
        case .humalogNovolog: return 75.0
        case .custom: return 60.0
        }
    }

    public var defaultDIAMinutes: Double {
        360.0
    }
}

public enum PumpQuantum: Double, Codable, CaseIterable, Identifiable, Sendable {
    case omnipod005 = 0.05
    case tandem0025 = 0.025
    case micro001 = 0.01

    public var id: Double { rawValue }

    public var title: String {
        switch self {
        case .omnipod005: return "0.05 U (Omnipod Dash / Eros)"
        case .tandem0025: return "0.025 U (t:slim / Fine Step)"
        case .micro001: return "0.01 U (Dana / Medtronic)"
        }
    }

    public func roundBasal(_ value: Double) -> Double {
        let clamped = max(rawValue, value)
        return (clamped / rawValue).rounded() * rawValue
    }
}

public enum ClosedLoopDosingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case automaticBolus = "automatic_bolus"
    case tempBasalOnly = "temp_basal_only"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automaticBolus: return "Automatic Bolus / SMB (Trio, AAPS, iAPS, Loop)"
        case .tempBasalOnly: return "Temp Basal Only (OpenAPS / Classic AID)"
        }
    }

    /// Universal Koenker-Bassett / Newsvendor closed-loop basal quantile.
    /// In Automatic Bolus / SMB systems, upward actuation is unbounded while downward actuation is bounded at 0 U/hr,
    /// yielding the exact ATTD consensus ratio 4% / (4% + 25%) = 4/29 ≈ 13.79%.
    /// In Temp Basal Only systems where upward rate is slower/capped, actuator asymmetry is milder (~30%).
    public var basalQuantileTau: Double {
        switch self {
        case .automaticBolus: return 4.0 / 29.0
        case .tempBasalOnly: return 8.0 / 29.0
        }
    }
}

public struct TherapySettingsConfig: Codable, Equatable, Sendable {
    public var insulinPreset: InsulinPreset
    public var customPeakMinutes: Double
    public var customDIAMinutes: Double
    public var pumpQuantum: PumpQuantum
    public var dosingMode: ClosedLoopDosingMode
    public var rollingDays: Int
    public var preferredUnitOverride: BGUnit?

    public init(
        insulinPreset: InsulinPreset = .lyumjevFiasp,
        customPeakMinutes: Double = 55.0,
        customDIAMinutes: Double = 360.0,
        pumpQuantum: PumpQuantum = .omnipod005,
        dosingMode: ClosedLoopDosingMode = .automaticBolus,
        rollingDays: Int = 30,
        preferredUnitOverride: BGUnit? = nil
    ) {
        self.insulinPreset = insulinPreset
        self.customPeakMinutes = customPeakMinutes
        self.customDIAMinutes = customDIAMinutes
        self.pumpQuantum = pumpQuantum
        self.dosingMode = dosingMode
        self.rollingDays = rollingDays
        self.preferredUnitOverride = preferredUnitOverride
    }

    public var peakMinutes: Double {
        insulinPreset == .custom ? customPeakMinutes : insulinPreset.defaultPeakMinutes
    }

    public var diaMinutes: Double {
        insulinPreset == .custom ? customDIAMinutes : insulinPreset.defaultDIAMinutes
    }
}

public struct NightscoutCredentials: Codable, Equatable, Sendable {
    public var baseURLString: String
    public var apiToken: String
    public var apiSecretPlaintext: String

    public init(baseURLString: String = "", apiToken: String = "", apiSecretPlaintext: String = "") {
        self.baseURLString = baseURLString
        self.apiToken = apiToken
        self.apiSecretPlaintext = apiSecretPlaintext
    }

    public var normalizedBaseURL: URL? {
        var trimmed = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.lowercased().hasPrefix("http://") && !trimmed.lowercased().hasPrefix("https://") {
            trimmed = "https://\(trimmed)"
        }
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        return URL(string: trimmed)
    }
}
