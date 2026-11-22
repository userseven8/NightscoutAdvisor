import XCTest
@testable import NightscoutAdvisorKit

final class NightscoutAdvisorKitTests: XCTestCase {

    func testExponentialIOBCurveBoundariesAndMonotonicity() {
        let f0 = InsulinKineticsTimeline.iobFraction(minutes: 0, peakMinutes: 55, diaMinutes: 360)
        let fPeak = InsulinKineticsTimeline.iobFraction(minutes: 55, peakMinutes: 55, diaMinutes: 360)
        let fMid = InsulinKineticsTimeline.iobFraction(minutes: 180, peakMinutes: 55, diaMinutes: 360)
        let fEnd = InsulinKineticsTimeline.iobFraction(minutes: 360, peakMinutes: 55, diaMinutes: 360)

        XCTAssertEqual(f0, 1.0, accuracy: 1e-9)
        XCTAssertEqual(fEnd, 0.0, accuracy: 1e-9)
        XCTAssertTrue(f0 > fPeak && fPeak > fMid && fMid > fEnd)
    }

    func testExactPKMassBalanceConservation() {
        let t0: TimeInterval = 1_700_000_000
        let bolus = BolusEvent(timestamp: t0 + 3600, units: 2.0, isAutomatic: false)
        let pk = InsulinKineticsTimeline(
            startTimestamp: t0,
            endTimestamp: t0 + 10 * 3600,
            peakMinutes: 55,
            diaMinutes: 360,
            boluses: [bolus],
            tempBasals: [],
            scheduledBasalRateAt: { _ in 0.10 }
        )

        // Over full 8 hours after bolus (> 6h DIA), absorbed insulin equals 8h * 0.10 U/hr + 2.0 U = 2.80 U
        let absorbed = pk.absorbedInsulin(from: t0 + 1800, to: t0 + 1800 + 8 * 3600)
        XCTAssertEqual(absorbed, 2.80, accuracy: 0.01)
    }

    func testMmolProfileAndOverrideParsing() throws {
        let profileJSON = """
        [
          {
            "defaultProfile": "Default",
            "mills": 1700000000000,
            "store": {
              "Default": {
                "units": "mmol",
                "timezone": "Europe/London",
                "basal": [{"time": "00:00", "value": "0.40"}],
                "sens": [{"time": "00:00", "value": "3.5"}],
                "carbratio": [{"time": "00:00", "value": "10"}],
                "target_low": [{"time": "00:00", "value": "5.5"}],
                "target_high": [{"time": "00:00", "value": "6.5"}]
              }
            }
          }
        ]
        """.data(using: .utf8)!

        let profiles = try NightscoutClient.parseProfiles(from: profileJSON)
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].units, .mmolL)
        XCTAssertEqual(profiles[0].isfSchedule[0].value, 3.5 * BGUnit.mmolConversionFactor, accuracy: 0.1)
        XCTAssertEqual(profiles[0].targetSchedule[0].lowMgdL, 5.5 * BGUnit.mmolConversionFactor, accuracy: 0.1)

        let treatmentsJSON = """
        [
          {
            "eventType": "Temporary Override",
            "created_at": "2026-11-20T21:00:00Z",
            "duration": 480,
            "correctionRange": [6.0, 6.8],
            "reason": "Sleep Safety"
          }
        ]
        """.data(using: .utf8)!

        let (_, _, _, overrides) = try NightscoutClient.parseTreatments(from: treatmentsJSON, fallbackUnit: .mmolL)
        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(overrides[0].lowMgdL, 6.0 * BGUnit.mmolConversionFactor, accuracy: 0.1)
    }

    func testFullFourStageSolverOnSyntheticBundle() throws {
        let bundle = DemoTelemetryGenerator.makeSyntheticBundle(days: 30, units: .mgdL)
        let config = TherapySettingsConfig(
            insulinPreset: .lyumjevFiasp,
            pumpQuantum: .omnipod005,
            dosingMode: .automaticBolus,
            rollingDays: 30
        )

        let report = try TherapyAdvisorSolver.solve(bundle: bundle, config: config)
        XCTAssertEqual(report.basalSchedule.count, 4)
        XCTAssertEqual(report.carbRatioSchedule.count, 4)
        XCTAssertEqual(report.targetSchedule.count, 2)
        XCTAssertEqual(report.targetSchedule[0].timeString, "22:00")
        XCTAssertEqual(report.targetSchedule[1].timeString, "08:30")
        XCTAssertGreaterThan(report.statsRolling.tirPercent, 60.0)
        XCTAssertGreaterThan(report.globalISF.recommendedMgdLPerU, 20.0)
        XCTAssertNotNil(report.stability.omegaUltimate)
        XCTAssertNotNil(report.stability.oscillationPeriodHours)
        XCTAssertEqual(report.agpBins.count, 48)

        let watchSummary = report.makeWatchSummary()
        XCTAssertGreaterThan(watchSummary.tir7d, 50.0)
    }
}
