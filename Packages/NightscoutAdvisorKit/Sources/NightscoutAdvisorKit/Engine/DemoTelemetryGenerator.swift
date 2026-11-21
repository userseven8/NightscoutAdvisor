import Foundation

/// Generates synthetic 30-day closed-loop telemetry containing zero personal data,
/// enabling instant onboarding demos, Xcode Previews, and automated unit tests.
public enum DemoTelemetryGenerator {

    public static func makeSyntheticBundle(
        days: Int = 30,
        units: BGUnit = .mgdL,
        now: Date = Date()
    ) -> NightscoutTelemetryBundle {
        let tz = TimeZone.current
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        let endTS = floor(now.timeIntervalSince1970 / 300.0) * 300.0
        let startTS = endTS - Double(days) * 86400.0

        let profile = HistoricalProfileVersion(
            effectiveTimestamp: startTS - 86400.0,
            profileName: "Demo Closed-Loop Profile",
            timeZoneIdentifier: tz.identifier,
            units: units,
            basalSchedule: [
                ScheduleSegment(startMinutes: 0, timeString: "00:00", value: 0.05),
                ScheduleSegment(startMinutes: 240, timeString: "04:00", value: 0.10), // Dawn block needing 0.20 U/hr
                ScheduleSegment(startMinutes: 510, timeString: "08:30", value: 0.05),
                ScheduleSegment(startMinutes: 1320, timeString: "22:00", value: 0.05)
            ],
            isfSchedule: [
                ScheduleSegment(startMinutes: 0, timeString: "00:00", value: 55.0)
            ],
            carbRatioSchedule: [
                ScheduleSegment(startMinutes: 0, timeString: "00:00", value: 11.0),
                ScheduleSegment(startMinutes: 450, timeString: "07:30", value: 11.0),
                ScheduleSegment(startMinutes: 720, timeString: "12:00", value: 8.5),
                ScheduleSegment(startMinutes: 1080, timeString: "18:00", value: 10.5)
            ],
            targetSchedule: [
                TargetScheduleSegment(startMinutes: 0, timeString: "00:00", lowMgdL: 95.0, highMgdL: 110.0),
                TargetScheduleSegment(startMinutes: 510, timeString: "08:30", lowMgdL: 95.0, highMgdL: 110.0),
                TargetScheduleSegment(startMinutes: 1320, timeString: "22:00", lowMgdL: 95.0, highMgdL: 110.0)
            ]
        )

        var rng = SplitMix64(seed: 20261122)
        func uniform(_ lo: Double, _ hi: Double) -> Double {
            let u = Double(rng.next() & 0x1FFFFFFFFFFFFF) / Double(0x1FFFFFFFFFFFFF)
            return lo + (hi - lo) * u
        }

        var cgm: [CGMSample] = []
        var boluses: [BolusEvent] = []
        var carbs: [CarbEvent] = []
        var tempBasals: [TempBasalEvent] = []

        let totalBins = Int((endTS - startTS) / 300.0)
        var bg = 115.0
        var mealImpulse = 0.0
        var corrImpulse = 0.0

        for b in 0...totalBins {
            let ts = startTS + Double(b) * 300.0
            let comps = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ts))
            let mins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

            // Dawn phenomenon hepatic push (04:00 - 08:00) requiring extra automatic boluses
            if mins >= 240 && mins < 480 {
                bg += uniform(0.8, 2.2)
                if b % 6 == 0 {
                    boluses.append(BolusEvent(timestamp: ts, units: 0.15, isAutomatic: true))
                }
            }

            // Realistic meals around 08:00, 13:00, 19:15
            if mins == 480 || mins == 780 || mins == 1155 {
                if uniform(0, 1) < 0.85 {
                    let mealG = round(uniform(25.0, 62.0))
                    let trueCR = mins == 480 ? 9.0 : (mins == 780 ? 11.0 : 10.5)
                    let mealBolus = ((mealG / trueCR) * 20.0).rounded() / 20.0
                    carbs.append(CarbEvent(timestamp: ts, grams: mealG, absorptionSeconds: 10800.0))
                    boluses.append(BolusEvent(timestamp: ts - 600.0, units: mealBolus, isAutomatic: false))
                    mealImpulse = uniform(38.0, 88.0)
                }
            }

            // Isolated carb-free correction episodes (~55 mg/dL per 1U)
            if (mins == 990 || mins == 1410) && uniform(0, 1) < 0.18 && mealImpulse < 5.0 {
                bg = uniform(172.0, 212.0)
                boluses.append(BolusEvent(timestamp: ts, units: 1.05, isAutomatic: true))
                corrImpulse = -58.0
            }

            if mealImpulse > 0.5 {
                bg += 0.14 * mealImpulse
                mealImpulse *= 0.84
            }
            if corrImpulse < -0.5 {
                bg += 0.11 * corrImpulse
                corrImpulse *= 0.88
            }

            // Mean-reverting closed-loop trajectory with realistic day-to-day variability (~85% TIR, ~1.5% <70)
            let dayWave = 24.0 * sin(Double(b) * 0.017)
            let target = (mins >= 510 && mins < 1320) ? 115.0 : 118.0
            bg += 0.055 * ((target + dayWave) - bg) + uniform(-12.5, 12.5)
            bg = min(265.0, max(56.0, bg))
            cgm.append(CGMSample(timestamp: ts, sgvMgdL: bg.rounded()))

            if b % 6 == 0 {
                if bg < 92.0 {
                    tempBasals.append(TempBasalEvent(startTimestamp: ts, endTimestamp: ts + 1800.0, rateUnitsPerHour: 0.0))
                } else if bg > 158.0 && mins < 240 {
                    boluses.append(BolusEvent(timestamp: ts, units: 0.10, isAutomatic: true))
                }
            }
        }

        return NightscoutTelemetryBundle(
            fetchedAt: now,
            sourceURL: "demo://synthetic-closed-loop",
            profiles: [profile],
            cgmSamples: cgm,
            boluses: boluses,
            carbs: carbs,
            tempBasals: tempBasals,
            targetOverrides: [],
            detectedDosingMode: .automaticBolus
        )
    }
}
