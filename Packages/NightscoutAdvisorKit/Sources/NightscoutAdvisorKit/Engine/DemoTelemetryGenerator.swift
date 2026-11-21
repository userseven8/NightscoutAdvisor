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
                ScheduleSegment(startMinutes: 0, timeString: "00:00", value: 0.45),
                ScheduleSegment(startMinutes: 240, timeString: "04:00", value: 0.65),
                ScheduleSegment(startMinutes: 510, timeString: "08:30", value: 0.55),
                ScheduleSegment(startMinutes: 1320, timeString: "22:00", value: 0.45)
            ],
            isfSchedule: [
                ScheduleSegment(startMinutes: 0, timeString: "00:00", value: 65.0)
            ],
            carbRatioSchedule: [
                ScheduleSegment(startMinutes: 0, timeString: "00:00", value: 11.0),
                ScheduleSegment(startMinutes: 450, timeString: "07:30", value: 8.5),
                ScheduleSegment(startMinutes: 720, timeString: "12:00", value: 10.5),
                ScheduleSegment(startMinutes: 1080, timeString: "18:00", value: 10.0)
            ],
            targetSchedule: [
                TargetScheduleSegment(startMinutes: 0, timeString: "00:00", lowMgdL: 100.0, highMgdL: 115.0),
                TargetScheduleSegment(startMinutes: 510, timeString: "08:30", lowMgdL: 95.0, highMgdL: 110.0),
                TargetScheduleSegment(startMinutes: 1320, timeString: "22:00", lowMgdL: 105.0, highMgdL: 120.0)
            ]
        )

        var rng = SplitMix64(seed: 20261121)
        func uniform(_ lo: Double, _ hi: Double) -> Double {
            let u = Double(rng.next() & 0x1FFFFFFFFFFFFF) / Double(0x1FFFFFFFFFFFFF)
            return lo + (hi - lo) * u
        }

        var cgm: [CGMSample] = []
        var boluses: [BolusEvent] = []
        var carbs: [CarbEvent] = []
        var tempBasals: [TempBasalEvent] = []

        let totalBins = Int((endTS - startTS) / 300.0)
        var bg = 108.0

        for b in 0...totalBins {
            let ts = startTS + Double(b) * 300.0
            let comps = cal.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ts))
            let mins = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)

            // Synthetic meals around 08:00, 13:00, 19:00
            if mins == 480 || mins == 780 || mins == 1140 {
                if uniform(0, 1) < 0.88 {
                    let mealG = round(uniform(22.0, 58.0))
                    let trueCR = mins == 480 ? 8.2 : (mins == 780 ? 10.4 : 9.8)
                    let mealBolus = ((mealG / trueCR) * 20.0).rounded() / 20.0
                    carbs.append(CarbEvent(timestamp: ts, grams: mealG, absorptionSeconds: 10800.0))
                    boluses.append(BolusEvent(timestamp: ts - 600.0, units: mealBolus, isAutomatic: false))
                    bg += uniform(14.0, 34.0)
                }
            }

            // Occasional isolated hyperglycemic correction at 16:00 or 23:00
            if (mins == 960 || mins == 1380) && uniform(0, 1) < 0.16 {
                bg = uniform(168.0, 205.0)
                boluses.append(BolusEvent(timestamp: ts, units: 0.90, isAutomatic: true))
            }

            // Mean-reverting closed-loop dynamics + realistic 5m CGM noise
            let target = (mins >= 510 && mins < 1320) ? 102.5 : 112.5
            bg += 0.11 * (target - bg) + uniform(-5.2, 5.2)
            bg = min(255.0, max(58.0, bg))
            cgm.append(CGMSample(timestamp: ts, sgvMgdL: bg.rounded()))

            // Periodic zero temp basals when bg < 92, automatic micro-boluses when bg > 135
            if b % 6 == 0 {
                if bg < 92.0 {
                    tempBasals.append(TempBasalEvent(startTimestamp: ts, endTimestamp: ts + 1800.0, rateUnitsPerHour: 0.0))
                } else if bg > 138.0 {
                    boluses.append(BolusEvent(timestamp: ts, units: 0.15, isAutomatic: true))
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
