import Foundation

public struct ScheduleSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { timeString }
    public let startMinutes: Int
    public let timeString: String
    /// Stored internally in canonical units: U/hr for basal, g/U for CR, mg/dL for ISF and Target.
    public let value: Double

    public init(startMinutes: Int, timeString: String, value: Double) {
        self.startMinutes = startMinutes
        self.timeString = timeString
        self.value = value
    }
}

public struct TargetScheduleSegment: Codable, Equatable, Identifiable, Sendable {
    public var id: String { timeString }
    public let startMinutes: Int
    public let timeString: String
    /// Stored internally in mg/dL.
    public let lowMgdL: Double
    public let highMgdL: Double

    public var midMgdL: Double { 0.5 * (lowMgdL + highMgdL) }

    public init(startMinutes: Int, timeString: String, lowMgdL: Double, highMgdL: Double) {
        self.startMinutes = startMinutes
        self.timeString = timeString
        self.lowMgdL = lowMgdL
        self.highMgdL = highMgdL
    }
}

public struct HistoricalProfileVersion: Codable, Equatable, Sendable {
    public let effectiveTimestamp: TimeInterval
    public let profileName: String
    public let timeZoneIdentifier: String
    public let units: BGUnit
    public let basalSchedule: [ScheduleSegment]
    public let isfSchedule: [ScheduleSegment]
    public let carbRatioSchedule: [ScheduleSegment]
    public let targetSchedule: [TargetScheduleSegment]

    public init(
        effectiveTimestamp: TimeInterval,
        profileName: String,
        timeZoneIdentifier: String,
        units: BGUnit,
        basalSchedule: [ScheduleSegment],
        isfSchedule: [ScheduleSegment],
        carbRatioSchedule: [ScheduleSegment],
        targetSchedule: [TargetScheduleSegment]
    ) {
        self.effectiveTimestamp = effectiveTimestamp
        self.profileName = profileName
        self.timeZoneIdentifier = timeZoneIdentifier
        self.units = units
        self.basalSchedule = basalSchedule
        self.isfSchedule = isfSchedule
        self.carbRatioSchedule = carbRatioSchedule
        self.targetSchedule = targetSchedule
    }
}

public struct CGMSample: Codable, Equatable, Sendable {
    public let timestamp: TimeInterval
    public let sgvMgdL: Double

    public init(timestamp: TimeInterval, sgvMgdL: Double) {
        self.timestamp = timestamp
        self.sgvMgdL = sgvMgdL
    }
}

public struct BolusEvent: Codable, Equatable, Sendable {
    public let timestamp: TimeInterval
    public let units: Double
    public let isAutomatic: Bool

    public init(timestamp: TimeInterval, units: Double, isAutomatic: Bool) {
        self.timestamp = timestamp
        self.units = units
        self.isAutomatic = isAutomatic
    }
}

public struct CarbEvent: Codable, Equatable, Sendable {
    public let timestamp: TimeInterval
    public let grams: Double
    public let absorptionSeconds: TimeInterval

    public init(timestamp: TimeInterval, grams: Double, absorptionSeconds: TimeInterval) {
        self.timestamp = timestamp
        self.grams = grams
        self.absorptionSeconds = absorptionSeconds
    }
}

public struct TempBasalEvent: Codable, Equatable, Sendable {
    public let startTimestamp: TimeInterval
    public let endTimestamp: TimeInterval
    public let rateUnitsPerHour: Double

    public init(startTimestamp: TimeInterval, endTimestamp: TimeInterval, rateUnitsPerHour: Double) {
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.rateUnitsPerHour = rateUnitsPerHour
    }
}

public struct TargetOverrideEvent: Codable, Equatable, Sendable {
    public let startTimestamp: TimeInterval
    public let endTimestamp: TimeInterval
    public let lowMgdL: Double
    public let highMgdL: Double
    public let reason: String

    public var midMgdL: Double { 0.5 * (lowMgdL + highMgdL) }

    public init(
        startTimestamp: TimeInterval,
        endTimestamp: TimeInterval,
        lowMgdL: Double,
        highMgdL: Double,
        reason: String = ""
    ) {
        self.startTimestamp = startTimestamp
        self.endTimestamp = endTimestamp
        self.lowMgdL = lowMgdL
        self.highMgdL = highMgdL
        self.reason = reason
    }
}

public struct NightscoutTelemetryBundle: Codable, Sendable {
    public let fetchedAt: Date
    public let sourceURL: String
    public let profiles: [HistoricalProfileVersion]
    public let cgmSamples: [CGMSample]
    public let boluses: [BolusEvent]
    public let carbs: [CarbEvent]
    public let tempBasals: [TempBasalEvent]
    public let targetOverrides: [TargetOverrideEvent]
    public let detectedDosingMode: ClosedLoopDosingMode?

    public init(
        fetchedAt: Date,
        sourceURL: String,
        profiles: [HistoricalProfileVersion],
        cgmSamples: [CGMSample],
        boluses: [BolusEvent],
        carbs: [CarbEvent],
        tempBasals: [TempBasalEvent],
        targetOverrides: [TargetOverrideEvent],
        detectedDosingMode: ClosedLoopDosingMode? = nil
    ) {
        self.fetchedAt = fetchedAt
        self.sourceURL = sourceURL
        self.profiles = profiles
        self.cgmSamples = cgmSamples
        self.boluses = boluses
        self.carbs = carbs
        self.tempBasals = tempBasalSorted(tempBasals)
        self.targetOverrides = targetOverrides
        self.detectedDosingMode = detectedDosingMode
    }
}

private func tempBasalSorted(_ items: [TempBasalEvent]) -> [TempBasalEvent] {
    items.sorted { $0.startTimestamp < $1.startTimestamp }
}
