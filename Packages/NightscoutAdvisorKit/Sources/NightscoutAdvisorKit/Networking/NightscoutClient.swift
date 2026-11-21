import CryptoKit
import Foundation

public struct NightscoutClient: Sendable {

    public enum ClientError: LocalizedError {
        case invalidURL
        case unauthorized
        case httpError(Int)
        case malformedPayload(String)

        public var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Please enter a valid Nightscout URL (for example, https://your-site.t1pal.com)."
            case .unauthorized:
                return "Nightscout returned 401/403 Unauthorized. Add a Read-Only API Token or API Secret in Settings."
            case .httpError(let code):
                return "Nightscout server returned HTTP \(code)."
            case .malformedPayload(let detail):
                return "Unable to parse Nightscout JSON (\(detail))."
            }
        }
    }

    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchTelemetry(
        credentials: NightscoutCredentials,
        rollingDays: Int
    ) async throws -> NightscoutTelemetryBundle {
        guard let baseURL = credentials.normalizedBaseURL else {
            throw ClientError.invalidURL
        }

        let now = Date()
        let cutoffDate = now.addingTimeInterval(-Double(max(7, rollingDays)) * 86400.0)
        // Pad treatments & CGM slightly earlier by 6h DIA so initial IOB is exact
        let paddedCutoff = cutoffDate.addingTimeInterval(-6.0 * 3600.0)
        let cutoffMillis = Int64(paddedCutoff.timeIntervalSince1970 * 1000.0)

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime]
        let cutoffISO = isoFormatter.string(from: paddedCutoff)

        async let profilesData = performGET(
            baseURL: baseURL,
            path: "/api/v1/profile.json",
            queryItems: [URLQueryItem(name: "count", value: "200")],
            credentials: credentials
        )
        async let cgmData = performGET(
            baseURL: baseURL,
            path: "/api/v1/entries/sgv.json",
            queryItems: [
                URLQueryItem(name: "find[date][$gte]", value: "\(cutoffMillis)"),
                URLQueryItem(name: "count", value: "20000")
            ],
            credentials: credentials
        )
        async let treatmentsData = performGET(
            baseURL: baseURL,
            path: "/api/v1/treatments.json",
            queryItems: [
                URLQueryItem(name: "find[created_at][$gte]", value: cutoffISO),
                URLQueryItem(name: "count", value: "10000")
            ],
            credentials: credentials
        )
        async let deviceStatusData = try? performGET(
            baseURL: baseURL,
            path: "/api/v1/devicestatus.json",
            queryItems: [URLQueryItem(name: "count", value: "15")],
            credentials: credentials
        )

        let (pBytes, cBytes, tBytes, dsBytes) = try await (profilesData, cgmData, treatmentsData, deviceStatusData)

        let profiles = try Self.parseProfiles(from: pBytes)
        let activeUnits = profiles.last?.units ?? .mgdL
        let cgmSamples = try Self.parseCGM(from: cBytes).filter { $0.timestamp >= cutoffDate.timeIntervalSince1970 }
        let (boluses, carbs, tempBasals, overrides) = try Self.parseTreatments(from: tBytes, fallbackUnit: activeUnits)
        let detectedMode = dsBytes.flatMap { Self.detectDosingMode(from: $0) }

        return NightscoutTelemetryBundle(
            fetchedAt: now,
            sourceURL: baseURL.absoluteString,
            profiles: profiles,
            cgmSamples: cgmSamples,
            boluses: boluses,
            carbs: carbs,
            tempBasals: tempBasals,
            targetOverrides: overrides,
            detectedDosingMode: detectedMode
        )
    }

    private func performGET(
        baseURL: URL,
        path: String,
        queryItems: [URLQueryItem],
        credentials: NightscoutCredentials
    ) async throws -> Data {
        guard var comps = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidURL
        }
        var items = queryItems
        let token = credentials.apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            items.append(URLQueryItem(name: "token", value: token))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw ClientError.invalidURL }

        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let secret = credentials.apiSecretPlaintext.trimmingCharacters(in: .whitespacesAndNewlines)
        if !secret.isEmpty {
            let digest = Insecure.SHA1.hash(data: Data(secret.utf8))
            let sha1Hex = digest.map { String(format: "%02x", $0) }.joined()
            request.setValue(sha1Hex, forHTTPHeaderField: "api-secret")
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 {
                throw ClientError.unauthorized
            }
            if !(200...299).contains(http.statusCode) {
                throw ClientError.httpError(http.statusCode)
            }
        }
        return data
    }

    // MARK: - Flexible Nightscout JSON Parsers

    public static func parseProfiles(from data: Data) throws -> [HistoricalProfileVersion] {
        guard let rawArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ClientError.malformedPayload("profile.json is not an array")
        }

        var versions: [HistoricalProfileVersion] = []
        for doc in rawArray {
            guard let store = doc["store"] as? [String: Any], !store.isEmpty else { continue }
            let defaultName = (doc["defaultProfile"] as? String) ?? store.keys.sorted().first ?? "Default"
            let activeDict = (store[defaultName] as? [String: Any]) ?? (store.values.first as? [String: Any]) ?? [:]

            let unitsStr = (activeDict["units"] as? String) ?? (doc["units"] as? String)
            let unit = BGUnit.fromNightscout(unitsStr)
            let tzID = (activeDict["timezone"] as? String) ?? TimeZone.current.identifier

            let effTS: TimeInterval = {
                if let mills = doubleFromAny(doc["mills"]), mills > 1e11 {
                    return mills / 1000.0
                }
                if let sDate = doc["startDate"] as? String ?? doc["created_at"] as? String,
                   let ts = parseISOTimestamp(sDate) {
                    return ts
                }
                return 0.0
            }()

            let basal = parseScheduleList(activeDict["basal"], convertUnit: nil)
            let isf = parseScheduleList(activeDict["sens"], convertUnit: unit)
            let cr = parseScheduleList(activeDict["carbratio"], convertUnit: nil)
            let targets = parseTargetList(
                lowRaw: activeDict["target_low"],
                highRaw: activeDict["target_high"],
                unit: unit
            )

            versions.append(
                HistoricalProfileVersion(
                    effectiveTimestamp: effTS,
                    profileName: defaultName,
                    timeZoneIdentifier: tzID,
                    units: unit,
                    basalSchedule: basal,
                    isfSchedule: isf,
                    carbRatioSchedule: cr,
                    targetSchedule: targets
                )
            )
        }
        return versions.sorted { $0.effectiveTimestamp < $1.effectiveTimestamp }
    }

    public static func parseCGM(from data: Data) throws -> [CGMSample] {
        guard let rawArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ClientError.malformedPayload("entries/sgv.json is not an array")
        }
        var samples: [CGMSample] = []
        samples.reserveCapacity(rawArray.count)
        for item in rawArray {
            guard let sgv = doubleFromAny(item["sgv"]), sgv >= 25.0, sgv <= 600.0 else { continue }
            let ts: TimeInterval? = {
                if let dateMillis = doubleFromAny(item["date"]), dateMillis > 1e11 {
                    return dateMillis / 1000.0
                }
                if let dateStr = item["dateString"] as? String {
                    return parseISOTimestamp(dateStr)
                }
                return nil
            }()
            if let validTS = ts {
                samples.append(CGMSample(timestamp: validTS, sgvMgdL: sgv))
            }
        }
        return samples.sorted { $0.timestamp < $1.timestamp }
    }

    public static func parseTreatments(
        from data: Data,
        fallbackUnit: BGUnit
    ) throws -> ([BolusEvent], [CarbEvent], [TempBasalEvent], [TargetOverrideEvent]) {
        guard let rawArray = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ClientError.malformedPayload("treatments.json is not an array")
        }

        var boluses: [BolusEvent] = []
        var carbs: [CarbEvent] = []
        var tempBasals: [TempBasalEvent] = []
        var overrides: [TargetOverrideEvent] = []

        for tr in rawArray {
            let ts: TimeInterval? = {
                if let tsStr = tr["timestamp"] as? String ?? tr["created_at"] as? String,
                   let parsed = parseISOTimestamp(tsStr) {
                    return parsed
                }
                if let mills = doubleFromAny(tr["mills"]), mills > 1e11 {
                    return mills / 1000.0
                }
                return nil
            }()
            guard let validTS = ts else { continue }

            let eventType = (tr["eventType"] as? String) ?? ""

            if let ins = doubleFromAny(tr["insulin"]), ins > 0.0 {
                let auto = (tr["automatic"] as? Bool) == true || eventType.lowercased().contains("smb")
                boluses.append(BolusEvent(timestamp: validTS, units: ins, isAutomatic: auto))
            }

            if let cGrams = doubleFromAny(tr["carbs"]), cGrams > 0.0 {
                let absMin = doubleFromAny(tr["absorptionTime"]) ?? 180.0
                // Nightscout Loop uploads absorptionTime in minutes (typically 30..480)
                let absSec = absMin > 1000.0 ? absMin : absMin * 60.0
                carbs.append(CarbEvent(timestamp: validTS, grams: cGrams, absorptionSeconds: absSec))
            }

            if eventType == "Temp Basal" {
                let durMin = doubleFromAny(tr["duration"]) ?? 0.0
                if durMin > 0.0, let rate = doubleFromAny(tr["rate"]) ?? doubleFromAny(tr["absolute"]) {
                    tempBasals.append(
                        TempBasalEvent(
                            startTimestamp: validTS,
                            endTimestamp: validTS + durMin * 60.0,
                            rateUnitsPerHour: max(0.0, rate)
                        )
                    )
                }
            } else if eventType == "Temporary Override" || eventType == "Temporary Target" {
                let durMin = doubleFromAny(tr["duration"]) ?? 0.0
                if durMin > 0.0 {
                    var loVal: Double?
                    var hiVal: Double?
                    if let crArr = tr["correctionRange"] as? [Any], crArr.count == 2 {
                        loVal = doubleFromAny(crArr[0])
                        hiVal = doubleFromAny(crArr[1])
                    } else {
                        loVal = doubleFromAny(tr["targetBottom"])
                        hiVal = doubleFromAny(tr["targetTop"])
                    }
                    if var lo = loVal, var hi = hiVal {
                        // Detect mmol/L override ranges (< 30) automatically
                        let trUnits = BGUnit.fromNightscout(tr["units"] as? String)
                        if trUnits == .mmolL || (fallbackUnit == .mmolL && hi < 35.0) || hi < 30.0 {
                            lo *= BGUnit.mmolConversionFactor
                            hi *= BGUnit.mmolConversionFactor
                        }
                        if lo >= 55.0 && hi <= 260.0 && lo <= hi {
                            let reason = (tr["reason"] as? String) ?? ""
                            overrides.append(
                                TargetOverrideEvent(
                                    startTimestamp: validTS,
                                    endTimestamp: validTS + durMin * 60.0,
                                    lowMgdL: lo,
                                    highMgdL: hi,
                                    reason: reason
                                )
                            )
                        }
                    }
                }
            }
        }

        return (
            boluses.sorted { $0.timestamp < $1.timestamp },
            carbs.sorted { $0.timestamp < $1.timestamp },
            tempBasals.sorted { $0.startTimestamp < $1.startTimestamp },
            overrides.sorted { $0.startTimestamp < $1.startTimestamp }
        )
    }

    private static func detectDosingMode(from data: Data) -> ClosedLoopDosingMode? {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        for doc in arr {
            if let loop = doc["loop"] as? [String: Any] {
                if loop["automaticBolusApplicationFactor"] != nil {
                    return .automaticBolus
                }
                if let enacted = loop["enacted"] as? [String: Any],
                   let bolusVol = doubleFromAny(enacted["bolusVolume"]), bolusVol > 0 {
                    return .automaticBolus
                }
            }
            if doc["openaps"] != nil {
                return .automaticBolus // Trio / iAPS / AAPS SMB
            }
        }
        return nil
    }

    private static func parseScheduleList(_ raw: Any?, convertUnit: BGUnit?) -> [ScheduleSegment] {
        guard let list = raw as? [[String: Any]] else { return [] }
        var out: [ScheduleSegment] = []
        for entry in list {
            guard var val = doubleFromAny(entry["value"]) else { continue }
            if let u = convertUnit, u == .mmolL, val < 40.0 {
                val = u.toMgdL(val)
            }
            let (mins, timeStr) = parseScheduleTime(entry)
            out.append(ScheduleSegment(startMinutes: mins, timeString: timeStr, value: val))
        }
        return out.sorted { $0.startMinutes < $1.startMinutes }
    }

    private static func parseTargetList(lowRaw: Any?, highRaw: Any?, unit: BGUnit) -> [TargetScheduleSegment] {
        let lows = parseScheduleList(lowRaw, convertUnit: unit)
        let highs = parseScheduleList(highRaw, convertUnit: unit)
        guard !lows.isEmpty else { return [] }

        return lows.map { loSeg in
            var matchedHigh = loSeg.value + 15.0
            for hiSeg in highs where hiSeg.startMinutes <= loSeg.startMinutes {
                matchedHigh = hiSeg.value
            }
            return TargetScheduleSegment(
                startMinutes: loSeg.startMinutes,
                timeString: loSeg.timeString,
                lowMgdL: loSeg.value,
                highMgdL: max(loSeg.value, matchedHigh)
            )
        }
    }

    private static func parseScheduleTime(_ entry: [String: Any]) -> (Int, String) {
        if let sec = doubleFromAny(entry["timeAsSeconds"]) {
            let mins = max(0, min(1439, Int(sec) / 60))
            return (mins, String(format: "%02d:%02d", mins / 60, mins % 60))
        }
        if let tStr = entry["time"] as? String {
            let parts = tStr.split(separator: ":")
            if parts.count >= 2, let h = Int(parts[0]), let m = Int(parts[1]) {
                let mins = max(0, min(1439, h * 60 + m))
                return (mins, String(format: "%02d:%02d", mins / 60, mins % 60))
            }
        }
        return (0, "00:00")
    }

    private static func doubleFromAny(_ val: Any?) -> Double? {
        switch val {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    private static func parseISOTimestamp(_ raw: String) -> TimeInterval? {
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d.timeIntervalSince1970 }

        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f2.date(from: raw) { return d.timeIntervalSince1970 }
        return nil
    }
}
