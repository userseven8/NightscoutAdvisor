import Foundation
import NightscoutAdvisorKit

private func logStderr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

private func printUsage() {
    logStderr(
        """
        Usage: advisor-cli --url <https://nightscout.example.com> [options]
               advisor-cli --demo [options]

        Options:
          --url <url>           Nightscout base URL
          --demo                Synthesize deterministic 30-day demo telemetry
          --days <int>          Rolling window in days (default: 30)
          --multi-days <csv>    Solve multiple windows from one fetch (e.g. 14,30,45,60,90)
          --tz <iana_id>        Preferred IANA timezone override (e.g. Europe/Athens)
          --peak <minutes>      Insulin peak activity in minutes (default: 55)
          --dia <minutes>       Insulin duration of action in minutes (default: 360)
          --step <units>        Pump basal quantum: 0.05, 0.025, or 0.01 (default: 0.05)
          --token <token>       Nightscout read-only API token (optional)
          --secret <secret>     Nightscout API secret plaintext (optional)
          --output <path>       Write JSON report to file instead of stdout
        """
    )
}

@main
struct AdvisorCLIMain {
    static func main() async {
        let args = Array(CommandLine.arguments.dropFirst())
        var urlString = ""
        var useDemo = false
        var rollingDays = 30
        var multiDaysList: [Int] = []
        var tzOverride: String?
        var peakMinutes = 55.0
        var diaMinutes = 360.0
        var stepQuantum: PumpQuantum = .omnipod005
        var apiToken = ""
        var apiSecret = ""
        var outputPath: String?

        var i = 0
        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--help", "-h":
                printUsage()
                exit(0)
            case "--demo":
                useDemo = true
                i += 1
            case "--url":
                guard i + 1 < args.count else { printUsage(); exit(2) }
                urlString = args[i + 1]
                i += 2
            case "--days":
                guard i + 1 < args.count, let v = Int(args[i + 1]) else { printUsage(); exit(2) }
                rollingDays = max(7, v)
                i += 2
            case "--multi-days":
                guard i + 1 < args.count else { printUsage(); exit(2) }
                multiDaysList = args[i + 1]
                    .split(separator: ",")
                    .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    .map { max(7, $0) }
                guard !multiDaysList.isEmpty else { printUsage(); exit(2) }
                i += 2
            case "--tz":
                guard i + 1 < args.count else { printUsage(); exit(2) }
                tzOverride = args[i + 1]
                i += 2
            case "--peak":
                guard i + 1 < args.count, let v = Double(args[i + 1]) else { printUsage(); exit(2) }
                peakMinutes = v
                i += 2
            case "--dia":
                guard i + 1 < args.count, let v = Double(args[i + 1]) else { printUsage(); exit(2) }
                diaMinutes = v
                i += 2
            case "--step":
                guard i + 1 < args.count, let v = Double(args[i + 1]) else { printUsage(); exit(2) }
                if abs(v - 0.01) < 1e-4 {
                    stepQuantum = .micro001
                } else if abs(v - 0.025) < 1e-4 {
                    stepQuantum = .tandem0025
                } else {
                    stepQuantum = .omnipod005
                }
                i += 2
            case "--token":
                guard i + 1 < args.count else { printUsage(); exit(2) }
                apiToken = args[i + 1]
                i += 2
            case "--secret":
                guard i + 1 < args.count else { printUsage(); exit(2) }
                apiSecret = args[i + 1]
                i += 2
            case "--output", "-o":
                guard i + 1 < args.count else { printUsage(); exit(2) }
                outputPath = args[i + 1]
                i += 2
            default:
                logStderr("[ERROR] Unrecognized argument: \(arg)")
                printUsage()
                exit(2)
            }
        }

        if !useDemo && urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            printUsage()
            exit(2)
        }

        let preset: InsulinPreset = (abs(peakMinutes - 55.0) < 0.1 && abs(diaMinutes - 360.0) < 0.1)
            ? .lyumjevFiasp
            : .custom

        let fetchDays = multiDaysList.max() ?? rollingDays

        let config = TherapySettingsConfig(
            insulinPreset: preset,
            customPeakMinutes: peakMinutes,
            customDIAMinutes: diaMinutes,
            pumpQuantum: stepQuantum,
            dosingMode: .automaticBolus,
            rollingDays: fetchDays,
            preferredUnitOverride: nil,
            preferredTimeZoneIdentifier: tzOverride
        )

        do {
            let bundle: NightscoutTelemetryBundle
            if useDemo {
                logStderr("[advisor-cli] Generating deterministic \(fetchDays)-day demo telemetry...")
                bundle = DemoTelemetryGenerator.makeSyntheticBundle(days: fetchDays)
            } else {
                let creds = NightscoutCredentials(
                    baseURLString: urlString,
                    apiToken: apiToken,
                    apiSecretPlaintext: apiSecret
                )
                logStderr("[advisor-cli] Fetching rolling \(fetchDays)-day telemetry from Nightscout...")
                bundle = try await NightscoutClient().fetchTelemetry(
                    credentials: creds,
                    rollingDays: fetchDays
                )
                logStderr("[advisor-cli] Loaded \(bundle.cgmSamples.count) CGM samples, \(bundle.boluses.count) boluses, \(bundle.carbs.count) carb entries.")
            }

            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

            let jsonData: Data
            if !multiDaysList.isEmpty {
                var multiMap: [String: AdvisorReport] = [:]
                for d in multiDaysList {
                    var cfgD = config
                    cfgD.rollingDays = d
                    let sliced = (d == fetchDays) ? bundle : bundle.sliced(rollingDays: d)
                    let rep = try TherapyAdvisorSolver.solve(bundle: sliced, config: cfgD)
                    logStderr(
                        String(
                            format: "[advisor-cli] Solved %dd report (TIR=%.1f%%, ISF=%.0f [N=%d], aligned=%d/4).",
                            d,
                            rep.statsRolling.tirPercent,
                            rep.globalISF.recommendedMgdLPerU,
                            rep.globalISF.episodeCount,
                            rep.alignedSectionCount
                        )
                    )
                    multiMap["\(d)"] = rep
                }
                jsonData = try encoder.encode(multiMap)
            } else {
                let report = try TherapyAdvisorSolver.solve(bundle: bundle, config: config)
                logStderr(
                    String(
                        format: "[advisor-cli] Solved %d-day report (TZ=%@, TIR=%.1f%%, ISF=%.0f, ζ=%.2f, aligned=%d/4).",
                        report.rollingDays,
                        report.timeZoneIdentifier,
                        report.statsRolling.tirPercent,
                        report.globalISF.recommendedMgdLPerU,
                        report.stability.dampingRatioZeta,
                        report.alignedSectionCount
                    )
                )
                jsonData = try encoder.encode(report)
            }

            if let outPath = outputPath {
                try jsonData.write(to: URL(fileURLWithPath: outPath), options: .atomic)
                logStderr("[advisor-cli] Wrote JSON report to \(outPath)")
            } else {
                FileHandle.standardOutput.write(jsonData)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
        } catch {
            logStderr("[advisor-cli] ERROR: \(error.localizedDescription)")
            exit(1)
        }
    }
}
