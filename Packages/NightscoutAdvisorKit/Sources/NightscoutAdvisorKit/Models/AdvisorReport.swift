import Foundation

public enum SyncStatus: String, Codable, Sendable {
    case inSync = "in_sync"
    case inConfidenceInterval = "in_ci"
    case adjustRecommended = "adjust"
    case insufficientData = "insufficient_data"

    public var badgeTitle: String {
        switch self {
        case .inSync: return "✓ In Sync"
        case .inConfidenceInterval: return "✓ In 95% CI"
        case .adjustRecommended: return "Adjust Recommended"
        case .insufficientData: return "Profile Anchor"
        }
    }

    public var isAlignedOrInCI: Bool {
        self == .inSync || self == .inConfidenceInterval || self == .insufficientData
    }
}

public struct GlycemicWindowStats: Codable, Equatable, Sendable {
    public let label: String
    public let sampleCount: Int
    public let meanMgdL: Double
    public let sdMgdL: Double
    public let cvPercent: Double
    public let gmiPercent: Double
    public let tirPercent: Double       // 70 - 180 mg/dL
    public let tbrPercent: Double       // < 70 mg/dL
    public let veryLowPercent: Double   // < 54 mg/dL
    public let tarPercent: Double       // > 180 mg/dL
    public let veryHighPercent: Double  // > 250 mg/dL

    public init(
        label: String,
        sampleCount: Int,
        meanMgdL: Double,
        sdMgdL: Double,
        cvPercent: Double,
        gmiPercent: Double,
        tirPercent: Double,
        tbrPercent: Double,
        veryLowPercent: Double,
        tarPercent: Double,
        veryHighPercent: Double
    ) {
        self.label = label
        self.sampleCount = sampleCount
        self.meanMgdL = meanMgdL
        self.sdMgdL = sdMgdL
        self.cvPercent = cvPercent
        self.gmiPercent = gmiPercent
        self.tirPercent = tirPercent
        self.tbrPercent = tbrPercent
        self.veryLowPercent = veryLowPercent
        self.tarPercent = tarPercent
        self.veryHighPercent = veryHighPercent
    }
}

public struct AGPBin: Codable, Equatable, Identifiable, Sendable {
    public var id: Int { minuteOfDay }
    public let minuteOfDay: Int
    public let hourLabel: String
    public let p10MgdL: Double
    public let p25MgdL: Double
    public let p50MgdL: Double
    public let p75MgdL: Double
    public let p90MgdL: Double

    public init(
        minuteOfDay: Int,
        hourLabel: String,
        p10MgdL: Double,
        p25MgdL: Double,
        p50MgdL: Double,
        p75MgdL: Double,
        p90MgdL: Double
    ) {
        self.minuteOfDay = minuteOfDay
        self.hourLabel = hourLabel
        self.p10MgdL = p10MgdL
        self.p25MgdL = p25MgdL
        self.p50MgdL = p50MgdL
        self.p75MgdL = p75MgdL
        self.p90MgdL = p90MgdL
    }
}

public struct ISFEpisodeDetail: Codable, Equatable, Sendable {
    public let timestamp: TimeInterval
    public let bgBolusMgdL: Double
    public let bgNadirMgdL: Double
    public let dropMgdL: Double
    public let absorbedInsulinU: Double
    public let egpOffsetU: Double
    public let netCorrectionU: Double
    public let impliedISFMgdLPerU: Double

    public init(
        timestamp: TimeInterval,
        bgBolusMgdL: Double,
        bgNadirMgdL: Double,
        dropMgdL: Double,
        absorbedInsulinU: Double,
        egpOffsetU: Double,
        netCorrectionU: Double,
        impliedISFMgdLPerU: Double
    ) {
        self.timestamp = timestamp
        self.bgBolusMgdL = bgBolusMgdL
        self.bgNadirMgdL = bgNadirMgdL
        self.dropMgdL = dropMgdL
        self.absorbedInsulinU = absorbedInsulinU
        self.egpOffsetU = egpOffsetU
        self.netCorrectionU = netCorrectionU
        self.impliedISFMgdLPerU = impliedISFMgdLPerU
    }
}

public struct ISFRecommendation: Codable, Equatable, Identifiable, Sendable {
    public var id: String { timeString }
    public let timeString: String
    public let windowLabel: String
    public let currentMgdLPerU: Double
    public let recommendedMgdLPerU: Double
    public let geometricMeanMgdLPerU: Double
    public let medianMgdLPerU: Double?
    public let ciLowMgdLPerU: Double
    public let ciHighMgdLPerU: Double
    public let episodeCount: Int
    public let status: SyncStatus
    public let rationale: String
}

public struct BasalRecommendation: Codable, Equatable, Identifiable, Sendable {
    public var id: String { timeString }
    public let timeString: String
    public let windowLabel: String
    public let currentUnitsPerHour: Double
    public let recommendedUnitsPerHour: Double
    public let rawQuantileFlux: Double
    public let medianTotalFlux: Double
    public let ciLowUnitsPerHour: Double
    public let ciHighUnitsPerHour: Double
    public let fastingHourCount: Int
    public let status: SyncStatus
    public let rationale: String
}

public struct CarbRatioRecommendation: Codable, Equatable, Identifiable, Sendable {
    public var id: String { timeString }
    public let timeString: String
    public let windowLabel: String
    public let currentGramsPerUnit: Double
    public let recommendedGramsPerUnit: Double
    public let rawWLSGramsPerUnit: Double
    public let ciLowGramsPerUnit: Double
    public let ciHighGramsPerUnit: Double
    public let empiricalMinGramsPerUnit: Double?
    public let empiricalMaxGramsPerUnit: Double?
    public let relativeStandardError: Double?
    public let rescueWindowCount: Int?
    public let centeredRSquared: Double
    public let medianPostMealTargetDeltaMgdL: Double
    public let mealCount: Int
    public let status: SyncStatus
    public let rationale: String
}

public struct TargetRangeRecommendation: Codable, Equatable, Identifiable, Sendable {
    public var id: String { timeString }
    public let timeString: String
    public let windowLabel: String
    public let currentLowMgdL: Double
    public let currentHighMgdL: Double
    public let recommendedLowMgdL: Double
    public let recommendedHighMgdL: Double
    public let optimalMidMgdL: Double
    public let ciMidLowMgdL: Double
    public let ciMidHighMgdL: Double
    public let safetyFloorMidMgdL: Double
    public let q04ErrorMgdL: Double?
    public let q01ErrorMgdL: Double?
    public let sampleCount: Int?
    public let bgriScore: Double
    public let predictedTIRPercent: Double
    public let dayCount: Int
    public let status: SyncStatus
    public let rationale: String
}

public struct ControlStabilityAudit: Codable, Equatable, Sendable {
    public let dampingRatioZeta: Double
    public let poleSummary: String
    public let criticalISFBoundMgdLPerU: Double
    public let gainMarginMultiplier: Double
    public let phaseMarginDegrees: Double
    public let omegaUltimate: Double?
    public let oscillationPeriodHours: Double?
    public let sensorJitterMgdL: Double
    public let pumpStepImpactMgdL: Double
    public let isOverdampedStable: Bool
}

public struct AdvisorReport: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let sourceURL: String
    public let activeProfileName: String
    public let profileUpdatedTimestamp: TimeInterval?
    public let latestCGMTimestamp: TimeInterval?
    public let timeZoneIdentifier: String
    public let displayUnit: BGUnit
    public let rollingDays: Int
    public let settingsUsed: TherapySettingsConfig
    public let stats24h: GlycemicWindowStats
    public let stats7d: GlycemicWindowStats
    public let statsRolling: GlycemicWindowStats
    public let agpBins: [AGPBin]
    public let globalISF: ISFRecommendation
    public let isfEpisodes: [ISFEpisodeDetail]?
    public let isfSchedule: [ISFRecommendation]
    public let basalSchedule: [BasalRecommendation]
    public let carbRatioSchedule: [CarbRatioRecommendation]
    public let targetSchedule: [TargetRangeRecommendation]
    public let stability: ControlStabilityAudit
    public let averageDailyInsulinUnits: Double
    public let averageDailyCarbsGrams: Double

    public var alignedSectionCount: Int {
        var count = 0
        if isfSchedule.allSatisfy(\.status.isAlignedOrInCI) { count += 1 }
        if basalSchedule.allSatisfy(\.status.isAlignedOrInCI) { count += 1 }
        if carbRatioSchedule.allSatisfy(\.status.isAlignedOrInCI) { count += 1 }
        if targetSchedule.allSatisfy(\.status.isAlignedOrInCI) { count += 1 }
        return count
    }

    public var totalAdjustmentsCount: Int {
        let a1 = isfSchedule.filter { !$0.status.isAlignedOrInCI }.count
        let a2 = basalSchedule.filter { !$0.status.isAlignedOrInCI }.count
        let a3 = carbRatioSchedule.filter { !$0.status.isAlignedOrInCI }.count
        let a4 = targetSchedule.filter { !$0.status.isAlignedOrInCI }.count
        return a1 + a2 + a3 + a4
    }

    public func makeWatchSummary() -> WatchAdvisorSummary {
        var actions: [String] = []
        for s in isfSchedule where !s.status.isAlignedOrInCI {
            actions.append("\(s.timeString) ISF → \(displayUnit.formatISF(s.recommendedMgdLPerU, includeUnit: false))")
        }
        for b in basalSchedule where !b.status.isAlignedOrInCI {
            actions.append(String(format: "%@ Basal → %.2f", b.timeString, b.recommendedUnitsPerHour))
        }
        for c in carbRatioSchedule where !c.status.isAlignedOrInCI {
            actions.append(String(format: "%@ Carbs → 1:%.1f", c.timeString, c.recommendedGramsPerUnit))
        }
        for t in targetSchedule where !t.status.isAlignedOrInCI {
            actions.append("\(t.timeString) Target → \(displayUnit.formatBG(t.recommendedLowMgdL))–\(displayUnit.formatBG(t.recommendedHighMgdL))")
        }

        let firstBasalChange = basalSchedule.first { !$0.status.isAlignedOrInCI }
        let firstCRChange = carbRatioSchedule.first { !$0.status.isAlignedOrInCI }

        let basalText: String
        if let b = firstBasalChange {
            basalText = String(format: "%@ → %.2f", b.timeString, b.recommendedUnitsPerHour)
        } else {
            basalText = "In Range"
        }

        let crText: String
        if let c = firstCRChange {
            crText = String(format: "%@ → 1:%.1f", c.timeString, c.recommendedGramsPerUnit)
        } else {
            crText = "In Range"
        }

        let isfIsOK = isfSchedule.allSatisfy(\.status.isAlignedOrInCI)
        let targetIsOK = targetSchedule.allSatisfy(\.status.isAlignedOrInCI)

        let isfText: String = {
            let cur = displayUnit.formatISF(globalISF.currentMgdLPerU, includeUnit: false)
            let rec = displayUnit.formatISF(globalISF.recommendedMgdLPerU, includeUnit: false)
            return isfIsOK ? cur : "\(cur) → \(rec)"
        }()

        let targetText: String = {
            guard let t = targetSchedule.first else { return "—" }
            let cur = "\(displayUnit.formatBG(t.currentLowMgdL))–\(displayUnit.formatBG(t.currentHighMgdL))"
            let rec = "\(displayUnit.formatBG(t.recommendedLowMgdL))–\(displayUnit.formatBG(t.recommendedHighMgdL))"
            return targetIsOK ? cur : "→ \(rec)"
        }()

        return WatchAdvisorSummary(
            generatedAt: generatedAt,
            displayUnit: displayUnit,
            rollingDays: rollingDays,
            tirRolling: statsRolling.tirPercent,
            tbrRolling: statsRolling.tbrPercent,
            tir24h: stats24h.tirPercent,
            tir7d: stats7d.tirPercent,
            tbr7d: stats7d.tbrPercent,
            gmiRolling: statsRolling.gmiPercent,
            dampingZeta: stability.dampingRatioZeta,
            alignedSections: alignedSectionCount,
            adjustmentsCount: actions.count,
            actionItems: actions,
            isfAligned: isfIsOK,
            basalAligned: basalSchedule.allSatisfy(\.status.isAlignedOrInCI),
            crAligned: carbRatioSchedule.allSatisfy(\.status.isAlignedOrInCI),
            targetAligned: targetIsOK,
            headlineISF: isfText,
            headlineBasal: basalText,
            headlineCR: crText,
            headlineTarget: targetText
        )
    }
}

public struct WatchAdvisorSummary: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let displayUnit: BGUnit
    public let rollingDays: Int?
    public let tirRolling: Double?
    public let tbrRolling: Double?
    public let tir24h: Double
    public let tir7d: Double
    public let tbr7d: Double
    public let gmiRolling: Double
    public let dampingZeta: Double
    public let alignedSections: Int
    public let adjustmentsCount: Int?
    public let actionItems: [String]?
    public let isfAligned: Bool
    public let basalAligned: Bool
    public let crAligned: Bool
    public let targetAligned: Bool
    public let headlineISF: String
    public let headlineBasal: String?
    public let headlineCR: String?
    public let headlineTarget: String

    public var effectiveDays: Int { rollingDays ?? 30 }
    public var effectiveTIR: Double { tirRolling ?? tir7d }
    public var effectiveTBR: Double { tbrRolling ?? tbr7d }
    public var effectiveAdjustmentsCount: Int {
        adjustmentsCount ?? max(0, 4 - alignedSections)
    }
    public var effectiveActions: [String] {
        if let items = actionItems, !items.isEmpty { return items }
        var fallback: [String] = []
        if !isfAligned { fallback.append("ISF → \(headlineISF)") }
        if !basalAligned, let b = headlineBasal { fallback.append("Basal \(b)") }
        if !crAligned, let c = headlineCR { fallback.append("Carbs \(c)") }
        if !targetAligned { fallback.append("Target → \(headlineTarget)") }
        return fallback
    }

    public init(
        generatedAt: Date,
        displayUnit: BGUnit,
        rollingDays: Int? = 30,
        tirRolling: Double? = nil,
        tbrRolling: Double? = nil,
        tir24h: Double,
        tir7d: Double,
        tbr7d: Double,
        gmiRolling: Double,
        dampingZeta: Double,
        alignedSections: Int,
        adjustmentsCount: Int? = 0,
        actionItems: [String]? = [],
        isfAligned: Bool,
        basalAligned: Bool,
        crAligned: Bool,
        targetAligned: Bool,
        headlineISF: String,
        headlineBasal: String? = nil,
        headlineCR: String? = nil,
        headlineTarget: String
    ) {
        self.generatedAt = generatedAt
        self.displayUnit = displayUnit
        self.rollingDays = rollingDays
        self.tirRolling = tirRolling
        self.tbrRolling = tbrRolling
        self.tir24h = tir24h
        self.tir7d = tir7d
        self.tbr7d = tbr7d
        self.gmiRolling = gmiRolling
        self.dampingZeta = dampingZeta
        self.alignedSections = alignedSections
        self.adjustmentsCount = adjustmentsCount
        self.actionItems = actionItems
        self.isfAligned = isfAligned
        self.basalAligned = basalAligned
        self.crAligned = crAligned
        self.targetAligned = targetAligned
        self.headlineISF = headlineISF
        self.headlineBasal = headlineBasal
        self.headlineCR = headlineCR
        self.headlineTarget = headlineTarget
    }

    public static var placeholder: WatchAdvisorSummary {
        WatchAdvisorSummary(
            generatedAt: Date(),
            displayUnit: .mgdL,
            rollingDays: 30,
            tirRolling: 86.6,
            tbrRolling: 1.8,
            tir24h: 91.2,
            tir7d: 86.6,
            tbr7d: 1.8,
            gmiRolling: 6.4,
            dampingZeta: 1.04,
            alignedSections: 4,
            adjustmentsCount: 0,
            actionItems: [],
            isfAligned: true,
            basalAligned: true,
            crAligned: true,
            targetAligned: true,
            headlineISF: "125",
            headlineBasal: "In Range",
            headlineCR: "In Range",
            headlineTarget: "105–120"
        )
    }
}
