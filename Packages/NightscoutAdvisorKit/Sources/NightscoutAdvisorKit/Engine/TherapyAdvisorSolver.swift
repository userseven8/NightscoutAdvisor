import Foundation

/// Generalized 4-Stage Coupled Insulin-Kinetics & Stochastic Control Solver.
/// Operates dynamically on any user's Nightscout profile schedules, units (mg/dL or mmol/L),
/// timezone, insulin kinetics curve, and pump hardware step—with zero heuristic guardrails.
public enum TherapyAdvisorSolver {

    public enum SolverError: LocalizedError {
        case emptyCGMData
        case missingActiveProfile

        public var errorDescription: String? {
            switch self {
            case .emptyCGMData:
                return "No CGM readings were found in the selected Nightscout window."
            case .missingActiveProfile:
                return "No valid Nightscout therapy profile (basal/ISF/CR/target) was found."
            }
        }
    }

    // MARK: - Main Entry Point

    public static func solve(
        bundle: NightscoutTelemetryBundle,
        config: TherapySettingsConfig
    ) throws -> AdvisorReport {
        let cgm = bundle.cgmSamples.sorted { $0.timestamp < $1.timestamp }
        guard cgm.count >= 24 else { throw SolverError.emptyCGMData }

        let sortedProfiles = bundle.profiles.sorted { $0.effectiveTimestamp < $1.effectiveTimestamp }
        guard let activeProfile = sortedProfiles.last else { throw SolverError.missingActiveProfile }

        let tz = TimeZone(identifier: activeProfile.timeZoneIdentifier) ?? .current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz

        var effectiveConfig = config
        if let detected = bundle.detectedDosingMode, config.dosingMode == .automaticBolus {
            effectiveConfig.dosingMode = detected
        }
        let displayUnit = config.preferredUnitOverride ?? activeProfile.units

        let minTS = cgm.first!.timestamp
        let maxTS = cgm.last!.timestamp
        let spanDays = max(1.0, (maxTS - minTS) / 86400.0)

        // Helper: minute of local day [0...1439]
        func localMinuteOfDay(_ ts: TimeInterval) -> Int {
            let comps = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ts))
            return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        }

        func localDayKey(_ ts: TimeInterval) -> String {
            let comps = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ts))
            return String(format: "%04d-%02d-%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
        }

        // Historical profile lookup at timestamp t
        func profileAt(_ ts: TimeInterval) -> HistoricalProfileVersion {
            var lo = 0
            var hi = sortedProfiles.count - 1
            var ans = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if sortedProfiles[mid].effectiveTimestamp <= ts {
                    ans = mid
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            return sortedProfiles[ans]
        }

        func lookupSegment(_ segments: [ScheduleSegment], minuteOfDay: Int, fallback: Double) -> Double {
            guard !segments.isEmpty else { return fallback }
            var val = segments[0].value
            for seg in segments where minuteOfDay >= seg.startMinutes {
                val = seg.value
            }
            return val
        }

        func lookupTargetMid(_ segments: [TargetScheduleSegment], minuteOfDay: Int, fallback: Double = 110.0) -> Double {
            guard !segments.isEmpty else { return fallback }
            var val = segments[0].midMgdL
            for seg in segments where minuteOfDay >= seg.startMinutes {
                val = seg.midMgdL
            }
            return val
        }

        let sortedOverrides = bundle.targetOverrides.sorted { $0.startTimestamp < $1.startTimestamp }
        func activeTargetMid(at ts: TimeInterval) -> Double {
            // Binary search latest override starting <= ts
            var lo = 0
            var hi = sortedOverrides.count - 1
            var idx = -1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if sortedOverrides[mid].startTimestamp <= ts {
                    idx = mid
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            if idx >= 0 {
                let kStart = max(0, idx - 4)
                for k in stride(from: idx, through: kStart, by: -1) {
                    let ov = sortedOverrides[k]
                    if ov.startTimestamp <= ts && ts < ov.endTimestamp {
                        return ov.midMgdL
                    }
                }
            }
            let prof = profileAt(ts)
            return lookupTargetMid(prof.targetSchedule, minuteOfDay: localMinuteOfDay(ts))
        }

        // Build exact 5-minute Insulin Kinetics Timeline across historical profiles + temp basals + boluses
        let pkTimeline = InsulinKineticsTimeline(
            startTimestamp: minTS,
            endTimestamp: maxTS,
            peakMinutes: effectiveConfig.peakMinutes,
            diaMinutes: effectiveConfig.diaMinutes,
            boluses: bundle.boluses,
            tempBasals: bundle.tempBasals,
            scheduledBasalRateAt: { ts in
                let prof = profileAt(ts)
                return lookupSegment(prof.basalSchedule, minuteOfDay: localMinuteOfDay(ts), fallback: 0.1)
            }
        )

        // Fast binary-search CGM interpolation
        let cgmTimestamps = cgm.map(\.timestamp)
        func bgAt(_ ts: TimeInterval, maxGapSeconds: TimeInterval = 1200.0) -> Double? {
            var lo = 0
            var hi = cgmTimestamps.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if cgmTimestamps[mid] < ts {
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
            var bestDist = TimeInterval.greatestFiniteMagnitude
            var bestVal: Double?
            for cand in [lo - 1, lo] where cand >= 0 && cand < cgm.count {
                let d = abs(cgm[cand].timestamp - ts)
                if d < bestDist {
                    bestDist = d
                    bestVal = cgm[cand].sgvMgdL
                }
            }
            return bestDist <= maxGapSeconds ? bestVal : nil
        }

        let sortedCarbs = bundle.carbs.sorted { $0.timestamp < $1.timestamp }
        let sortedBoluses = bundle.boluses.sorted { $0.timestamp < $1.timestamp }

        func isFasting(from t1: TimeInterval, to t2: TimeInterval) -> Bool {
            for c in sortedCarbs {
                let gutClearEnd = c.timestamp + max(10800.0, c.absorptionSeconds)
                if c.timestamp <= t2 && gutClearEnd > t1 {
                    return false
                }
                if c.timestamp > t2 { break }
            }
            return true
        }

        // Pre-extract gut-clear 1-hour fasting windows mapped to the user's active basal blocks
        let userBasalBlocks: [ScheduleSegment] = activeProfile.basalSchedule.isEmpty
            ? [ScheduleSegment(startMinutes: 0, timeString: "00:00", value: 0.10)]
            : activeProfile.basalSchedule

        func blockIndex(for minuteOfDay: Int, in segments: [ScheduleSegment]) -> Int {
            var idx = 0
            for (i, seg) in segments.enumerated() where minuteOfDay >= seg.startMinutes {
                idx = i
            }
            return idx
        }

        struct FastingHourSample {
            let blockIdx: Int
            let absorbedInsulin: Double
            let deltaBG: Double
        }

        var fastingSamples: [FastingHourSample] = []
        var cursor = minTS + 3600.0
        while cursor + 3600.0 <= maxTS {
            let tEnd = cursor + 3600.0
            if isFasting(from: cursor, to: tEnd),
               let bg1 = bgAt(cursor, maxGapSeconds: 900.0),
               let bg2 = bgAt(tEnd, maxGapSeconds: 900.0),
               bg1 >= 75.0, bg2 >= 75.0 {
                let iAbs = pkTimeline.absorbedInsulin(from: cursor, to: tEnd)
                let midMin = localMinuteOfDay(cursor + 1800.0)
                let bIdx = blockIndex(for: midMin, in: userBasalBlocks)
                fastingSamples.append(FastingHourSample(blockIdx: bIdx, absorbedInsulin: iAbs, deltaBG: bg2 - bg1))
            }
            cursor += 1800.0 // 30-min stride
        }

        // Pre-identify clean correction bolus episodes (zero overlapping carbs)
        struct CorrectionCandidate {
            let timestamp: TimeInterval
            let nadirTimestamp: TimeInterval
            let bgDrop: Double
            let absorbedInsulin: Double
        }

        var correctionCandidates: [CorrectionCandidate] = []
        var lastEpisodeTS: TimeInterval = -1e12
        for bol in sortedBoluses where bol.units >= 0.15 {
            let bt = bol.timestamp
            if bt - lastEpisodeTS < 7200.0 { continue }

            var carbContaminated = false
            for c in sortedCarbs {
                let preClear = max(9000.0, c.absorptionSeconds)
                if (c.timestamp <= bt && bt - c.timestamp < preClear) ||
                   (c.timestamp > bt && c.timestamp - bt < 12600.0) {
                    carbContaminated = true
                    break
                }
                if c.timestamp > bt + 12600.0 { break }
            }
            if carbContaminated { continue }

            guard let bg0 = bgAt(bt, maxGapSeconds: 900.0), bg0 >= 145.0 else { continue }
            let windowPts = cgm.filter { $0.timestamp >= bt + 1800.0 && $0.timestamp <= bt + 12600.0 }
            guard windowPts.count >= 6,
                  let nadirPt = windowPts.min(by: { $0.sgvMgdL < $1.sgvMgdL }) else { continue }

            let drop = bg0 - nadirPt.sgvMgdL
            guard drop >= 25.0 else { continue }
            let iAbs = pkTimeline.absorbedInsulin(from: bt, to: nadirPt.timestamp)
            correctionCandidates.append(
                CorrectionCandidate(
                    timestamp: bt,
                    nadirTimestamp: nadirPt.timestamp,
                    bgDrop: drop,
                    absorbedInsulin: iAbs
                )
            )
            lastEpisodeTS = bt
        }

        // MARK: - Stage 1 & Stage 2 Coupled Fixed-Point Iteration (ISF <-> EGP Basal)

        let profileFallbackISF = activeProfile.isfSchedule.first?.value ?? 100.0
        var workingISF = profileFallbackISF
        var blockMedianEGP = Dictionary(uniqueKeysWithValues: userBasalBlocks.enumerated().map { ($0.offset, $0.element.value) })

        func integrateBasalMap(_ rateByBlock: [Int: Double], from t1: TimeInterval, to t2: TimeInterval) -> Double {
            guard t2 > t1 else { return 0.0 }
            let steps = max(1, Int((t2 - t1) / 300.0))
            let dtHours = ((t2 - t1) / Double(steps)) / 3600.0
            var total = 0.0
            for s in 0..<steps {
                let tm = t1 + (Double(s) + 0.5) * ((t2 - t1) / Double(steps))
                let bIdx = blockIndex(for: localMinuteOfDay(tm), in: userBasalBlocks)
                total += (rateByBlock[bIdx] ?? 0.1) * dtHours
            }
            return total
        }

        var solvedEpisodeISFs: [(ts: TimeInterval, isf: Double)] = []

        for _ in 0..<6 {
            for bIdx in 0..<userBasalBlocks.count {
                let fluxes = fastingSamples
                    .filter { $0.blockIdx == bIdx }
                    .map { $0.absorbedInsulin + ($0.deltaBG / workingISF) }
                    .sorted()
                if fluxes.count >= 4 {
                    blockMedianEGP[bIdx] = max(0.0, percentile(fluxes, p: 0.50))
                }
            }

            var iterISFs: [(ts: TimeInterval, isf: Double)] = []
            for ep in correctionCandidates {
                let egpNeed = integrateBasalMap(blockMedianEGP, from: ep.timestamp, to: ep.nadirTimestamp)
                let netCorr = ep.absorbedInsulin - egpNeed
                if netCorr >= 0.12 {
                    let val = ep.bgDrop / netCorr
                    if val >= 8.0 && val <= 600.0 {
                        iterISFs.append((ep.timestamp, val))
                    }
                }
            }
            solvedEpisodeISFs = iterISFs
            if iterISFs.count >= 2 {
                let meanLog = iterISFs.map { log($0.isf) }.reduce(0.0, +) / Double(iterISFs.count)
                workingISF = exp(meanLog)
            }
        }

        // Round ISF cleanly in the display unit's natural resolution (nearest 5 mg/dL or nearest 0.1 mmol/L)
        func roundISFToGrid(_ mgdLPerU: Double) -> Double {
            if displayUnit == .mmolL {
                let mmolVal = (mgdLPerU / BGUnit.mmolConversionFactor * 10.0).rounded() / 10.0
                return mmolVal * BGUnit.mmolConversionFactor
            } else {
                return (mgdLPerU / 5.0).rounded() * 5.0
            }
        }

        let globalGeomMeanISF = workingISF
        let globalRecISF = solvedEpisodeISFs.isEmpty ? profileFallbackISF : roundISFToGrid(globalGeomMeanISF)

        let (globalISFCILow, globalISFCIHigh): (Double, Double) = {
            let vals = solvedEpisodeISFs.map(\.isf)
            guard vals.count >= 2 else {
                return (globalRecISF * 0.85, globalRecISF * 1.15)
            }
            return logBootstrapCI(vals, seed: 42)
        }()

        // Build ISF Schedule mapped onto user's active ISF blocks
        let userISFBlocks = activeProfile.isfSchedule.isEmpty
            ? [ScheduleSegment(startMinutes: 0, timeString: "00:00", value: profileFallbackISF)]
            : activeProfile.isfSchedule

        var isfRecommendations: [ISFRecommendation] = []
        for (idx, seg) in userISFBlocks.enumerated() {
            let endMin = idx + 1 < userISFBlocks.count ? userISFBlocks[idx + 1].startMinutes : 1440
            let winLabel = "\(seg.timeString) – \(formatMinutes(endMin))"
            let blockEps = solvedEpisodeISFs.filter { ep in
                let m = localMinuteOfDay(ep.ts)
                return m >= seg.startMinutes && m < endMin
            }.map(\.isf)

            // Use block-specific episodes if N >= 3, otherwise pool with global geometric estimator
            let usedEps = blockEps.count >= 3 ? blockEps : solvedEpisodeISFs.map(\.isf)
            let geom: Double
            let recVal: Double
            let ciLo: Double
            let ciHi: Double
            if usedEps.count >= 2 {
                geom = exp(usedEps.map { log($0) }.reduce(0, +) / Double(usedEps.count))
                recVal = roundISFToGrid(geom)
                (ciLo, ciHi) = logBootstrapCI(usedEps, seed: 100 + idx)
            } else {
                geom = seg.value
                recVal = seg.value
                ciLo = seg.value * 0.85
                ciHi = seg.value * 1.15
            }

            let status: SyncStatus
            if usedEps.isEmpty {
                status = .insufficientData
            } else if abs(seg.value - recVal) <= max(5.0, 0.05 * recVal) {
                status = .inSync
            } else if seg.value >= ciLo && seg.value <= ciHi {
                status = .inConfidenceInterval
            } else {
                status = .adjustRecommended
            }

            let scopeNote = blockEps.count >= 3 ? "block-specific" : "24h pooled"
            let rationale = usedEps.isEmpty
                ? "No isolated carb-free correction episodes (\(winLabel)); retaining active profile anchor."
                : "Exact kinetic log-symmetric geometric mean across N=\(usedEps.count) \(scopeNote) correction episodes (\(displayUnit.formatISF(geom, includeUnit: true)); 95% CI \(displayUnit.formatISF(ciLo, includeUnit: false))–\(displayUnit.formatISF(ciHi, includeUnit: true)))."

            isfRecommendations.append(
                ISFRecommendation(
                    timeString: seg.timeString,
                    windowLabel: winLabel,
                    currentMgdLPerU: seg.value,
                    recommendedMgdLPerU: recVal,
                    geometricMeanMgdLPerU: geom,
                    ciLowMgdLPerU: ciLo,
                    ciHighMgdLPerU: ciHi,
                    episodeCount: usedEps.count,
                    status: status,
                    rationale: rationale
                )
            )
        }

        let globalISFRec = ISFRecommendation(
            timeString: "24h Global",
            windowLabel: "00:00 – 24:00",
            currentMgdLPerU: userISFBlocks[0].value,
            recommendedMgdLPerU: globalRecISF,
            geometricMeanMgdLPerU: globalGeomMeanISF,
            ciLowMgdLPerU: globalISFCILow,
            ciHighMgdLPerU: globalISFCIHigh,
            episodeCount: solvedEpisodeISFs.count,
            status: isfRecommendations.first?.status ?? .inSync,
            rationale: isfRecommendations.first?.rationale ?? ""
        )

        // MARK: - Stage 2: Universal ATTD Asymmetric Closed-Loop Basal Quantile

        let tauStar = effectiveConfig.dosingMode.basalQuantileTau
        var basalRecommendations: [BasalRecommendation] = []
        var solvedBasalByBlock: [Int: Double] = [:]

        for (bIdx, seg) in userBasalBlocks.enumerated() {
            let endMin = bIdx + 1 < userBasalBlocks.count ? userBasalBlocks[bIdx + 1].startMinutes : 1440
            let winLabel = "\(seg.timeString) – \(formatMinutes(endMin))"
            let fluxes = fastingSamples
                .filter { $0.blockIdx == bIdx }
                .map { $0.absorbedInsulin + ($0.deltaBG / globalRecISF) }
                .sorted()

            if fluxes.count >= 5 {
                let qTau = percentile(fluxes, p: tauStar)
                let medFlux = percentile(fluxes, p: 0.50)
                let recRate = effectiveConfig.pumpQuantum.roundBasal(qTau)
                let (ciLo, ciHi) = quantileBootstrapCI(
                    fluxes,
                    quantile: tauStar,
                    floorValue: effectiveConfig.pumpQuantum.rawValue,
                    seed: 200 + bIdx
                )
                solvedBasalByBlock[bIdx] = recRate

                let tol = effectiveConfig.pumpQuantum.rawValue * 0.6
                let status: SyncStatus
                if abs(seg.value - recRate) <= tol {
                    status = .inSync
                } else if seg.value >= (ciLo - tol) && seg.value <= (ciHi + tol) {
                    status = .inConfidenceInterval
                } else {
                    status = .adjustRecommended
                }

                let autoBolusShare = max(0.0, medFlux - recRate)
                let rationale = String(
                    format: "ATTD closed-loop quantile τ* = %.1f%% across N=%d gut-clear fasting hours: raw flux %.3f U/hr → %.2f U/hr (median total EGP demand %.2f U/hr; +%.2f U/hr supplied dynamically on higher-demand days).",
                    tauStar * 100.0, fluxes.count, max(0.0, qTau), recRate, max(0.0, medFlux), autoBolusShare
                )

                basalRecommendations.append(
                    BasalRecommendation(
                        timeString: seg.timeString,
                        windowLabel: winLabel,
                        currentUnitsPerHour: seg.value,
                        recommendedUnitsPerHour: recRate,
                        rawQuantileFlux: max(0.0, qTau),
                        medianTotalFlux: max(0.0, medFlux),
                        ciLowUnitsPerHour: ciLo,
                        ciHighUnitsPerHour: ciHi,
                        fastingHourCount: fluxes.count,
                        status: status,
                        rationale: rationale
                    )
                )
            } else {
                solvedBasalByBlock[bIdx] = seg.value
                basalRecommendations.append(
                    BasalRecommendation(
                        timeString: seg.timeString,
                        windowLabel: winLabel,
                        currentUnitsPerHour: seg.value,
                        recommendedUnitsPerHour: seg.value,
                        rawQuantileFlux: seg.value,
                        medianTotalFlux: seg.value,
                        ciLowUnitsPerHour: max(effectiveConfig.pumpQuantum.rawValue, seg.value * 0.75),
                        ciHighUnitsPerHour: seg.value * 1.25,
                        fastingHourCount: fluxes.count,
                        status: .insufficientData,
                        rationale: "Limited carb-free fasting hours (N=\(fluxes.count) in \(winLabel)) due to daytime meal overlap; retaining profile anchor."
                    )
                )
            }
        }

        // MARK: - Stage 3: Kinetic Mass-Balance Gauss-Markov WLS Carb Ratios

        // Cluster multi-part meals within 45 minutes
        struct MealCluster {
            var startTS: TimeInterval
            var totalCarbs: Double
        }
        var clusters: [MealCluster] = []
        for c in sortedCarbs where c.grams >= 3.0 {
            if let lastIdx = clusters.indices.last, c.timestamp - clusters[lastIdx].startTS <= 2700.0 {
                clusters[lastIdx].totalCarbs += c.grams
            } else {
                clusters.append(MealCluster(startTS: c.timestamp, totalCarbs: c.grams))
            }
        }

        let userCRBlocks: [ScheduleSegment] = activeProfile.carbRatioSchedule.isEmpty
            ? [ScheduleSegment(startMinutes: 0, timeString: "00:00", value: 10.0)]
            : activeProfile.carbRatioSchedule

        struct MealObservation {
            let crBlockIdx: Int
            let totalCarbs: Double
            let mealInsulin: Double
            let postMealTargetDelta: Double
        }

        let mealHorizonSec: TimeInterval = 3.5 * 3600.0
        let preBolusLeadSec: TimeInterval = 1200.0
        var mealObservations: [MealObservation] = []

        for (i, cl) in clusters.enumerated() where cl.totalCarbs >= 5.0 {
            let mt = cl.startTS
            // Skip if a large independent meal (>12g) arrives mid-window; sum smaller rescue carbs (<12g)
            var extraCarbs = 0.0
            var independentOverlap = false
            var j = i + 1
            while j < clusters.count && clusters[j].startTS < mt + mealHorizonSec {
                if clusters[j].totalCarbs > 12.0 {
                    independentOverlap = true
                    break
                } else {
                    extraCarbs += clusters[j].totalCarbs
                }
                j += 1
            }
            if independentOverlap { continue }

            guard let bg0 = bgAt(mt, maxGapSeconds: 900.0),
                  let bgEnd = bgAt(mt + mealHorizonSec, maxGapSeconds: 1200.0) else { continue }

            let totalCarbs = cl.totalCarbs + extraCarbs
            let iAbsWindow = pkTimeline.absorbedInsulin(from: mt - preBolusLeadSec, to: mt + mealHorizonSec)
            let basalNeed = integrateBasalMap(solvedBasalByBlock, from: mt - preBolusLeadSec, to: mt + mealHorizonSec)
            let isfAtMeal = lookupSegment(userISFBlocks, minuteOfDay: localMinuteOfDay(mt), fallback: globalRecISF)
            let usedISF = isfRecommendations.first(where: {
                let idx = blockIndex(for: localMinuteOfDay(mt), in: userISFBlocks)
                return $0.timeString == userISFBlocks[idx].timeString
            })?.recommendedMgdLPerU ?? isfAtMeal

            let mealIns = (iAbsWindow - basalNeed) + ((bgEnd - bg0) / usedISF)
            let impliedCR = mealIns > 0.08 ? (totalCarbs / mealIns) : -1.0
            guard mealIns > 0.08, impliedCR >= 1.2, impliedCR <= 80.0 else { continue }

            let targetMidEnd = activeTargetMid(at: mt + mealHorizonSec)
            let bIdx = blockIndex(for: localMinuteOfDay(mt), in: userCRBlocks)
            mealObservations.append(
                MealObservation(
                    crBlockIdx: bIdx,
                    totalCarbs: totalCarbs,
                    mealInsulin: mealIns,
                    postMealTargetDelta: bgEnd - targetMidEnd
                )
            )
        }

        var crRecommendations: [CarbRatioRecommendation] = []
        for (cIdx, seg) in userCRBlocks.enumerated() {
            let endMin = cIdx + 1 < userCRBlocks.count ? userCRBlocks[cIdx + 1].startMinutes : 1440
            let winLabel = "\(seg.timeString) – \(formatMinutes(endMin))"
            let obs = mealObservations.filter { $0.crBlockIdx == cIdx }

            if obs.count >= 4 {
                let sumC = obs.map(\.totalCarbs).reduce(0.0, +)
                let sumI = obs.map(\.mealInsulin).reduce(0.0, +)
                let betaWLS = sumI / sumC // U/g
                let rawCR = 1.0 / betaWLS
                let recCR = (rawCR * 10.0).rounded() / 10.0

                let nD = Double(obs.count)
                let weightedSSE = obs.reduce(0.0) { acc, item in
                    let r = item.mealInsulin - betaWLS * item.totalCarbs
                    return acc + (r * r) / item.totalCarbs
                }
                let s2 = weightedSSE / max(1.0, nD - 1.0)
                let seBeta = sqrt(s2 / sumC)
                let tCrit = studentTCrit95(df: obs.count - 1)
                let betaLo = max(betaWLS * 0.25, betaWLS - tCrit * seBeta)
                let betaHi = betaWLS + tCrit * seBeta
                let ciLo = ((1.0 / betaHi) * 10.0).rounded() / 10.0
                let ciHi = ((1.0 / betaLo) * 10.0).rounded() / 10.0

                // Centered Pearson R^2
                let meanC = sumC / nD
                let meanI = sumI / nD
                let covCI = obs.reduce(0.0) { $0 + ($1.totalCarbs - meanC) * ($1.mealInsulin - meanI) }
                let varC = obs.reduce(0.0) { $0 + pow($1.totalCarbs - meanC, 2) }
                let varI = obs.reduce(0.0) { $0 + pow($1.mealInsulin - meanI, 2) }
                let rSquared = (varC > 1e-9 && varI > 1e-9) ? pow(covCI / sqrt(varC * varI), 2) : 0.0

                let medTargetDelta = percentile(obs.map(\.postMealTargetDelta).sorted(), p: 0.50)

                let status: SyncStatus
                if abs(seg.value - recCR) <= max(0.2, 0.03 * recCR) {
                    status = .inSync
                } else if seg.value >= ciLo && seg.value <= ciHi {
                    status = .inConfidenceInterval
                } else {
                    status = .adjustRecommended
                }

                let deltaDisplay = displayUnit.formatBG(abs(medTargetDelta), includeUnit: true)
                let signStr = medTargetDelta >= 0 ? "+" : "−"
                let rationale = String(
                    format: "Gauss-Markov WLS (w = 1/C) across N=%d Kinetic mass-balance 3.5h meals: 1:%.1f g/U (Centered R² = %.2f, Med 3.5h BG − Target = %@%@).",
                    obs.count, recCR, rSquared, signStr, deltaDisplay
                )

                crRecommendations.append(
                    CarbRatioRecommendation(
                        timeString: seg.timeString,
                        windowLabel: winLabel,
                        currentGramsPerUnit: seg.value,
                        recommendedGramsPerUnit: recCR,
                        rawWLSGramsPerUnit: rawCR,
                        ciLowGramsPerUnit: ciLo,
                        ciHighGramsPerUnit: ciHi,
                        centeredRSquared: rSquared,
                        medianPostMealTargetDeltaMgdL: medTargetDelta,
                        mealCount: obs.count,
                        status: status,
                        rationale: rationale
                    )
                )
            } else {
                crRecommendations.append(
                    CarbRatioRecommendation(
                        timeString: seg.timeString,
                        windowLabel: winLabel,
                        currentGramsPerUnit: seg.value,
                        recommendedGramsPerUnit: seg.value,
                        rawWLSGramsPerUnit: seg.value,
                        ciLowGramsPerUnit: seg.value * 0.85,
                        ciHighGramsPerUnit: seg.value * 1.15,
                        centeredRSquared: 0.0,
                        medianPostMealTargetDeltaMgdL: 0.0,
                        mealCount: obs.count,
                        status: .insufficientData,
                        rationale: "Fasting/low-meal window (N=\(obs.count) isolated meals in \(winLabel)); retaining active profile setting."
                    )
                )
            }
        }

        // MARK: - Stage 4: Closed-Loop Correction Range (Setpoint & Deadband Physics)

        var adjDiffs: [Double] = []
        for i in 1..<cgm.count {
            let dt = cgm[i].timestamp - cgm[i - 1].timestamp
            if dt >= 240.0 && dt <= 360.0 {
                adjDiffs.append(abs(cgm[i].sgvMgdL - cgm[i - 1].sgvMgdL))
            }
        }
        adjDiffs.sort()
        let sigmaCGM = adjDiffs.isEmpty ? 5.5 : (percentile(adjDiffs, p: 0.50) / 0.6745) / sqrt(2.0)
        let podStepImpact = effectiveConfig.pumpQuantum.rawValue * globalRecISF
        let rawDeadband = 2.0 * max(sigmaCGM, podStepImpact)
        let targetDeadbandWidthMgdL: Double = displayUnit == .mmolL
            ? ceil((rawDeadband / BGUnit.mmolConversionFactor) / 0.2) * 0.2 * BGUnit.mmolConversionFactor
            : max(10.0, ceil(rawDeadband / 5.0) * 5.0)

        // Use user's target blocks if >= 2; if user has a single 24h flat block, evaluate Overnight (22:00-08:30) + Daytime (08:30-22:00)
        struct TargetEvalWindow {
            let timeString: String
            let label: String
            let curLow: Double
            let curHigh: Double
            let matchesMinute: (Int) -> Bool
        }

        let targetWindows: [TargetEvalWindow] = {
            if activeProfile.targetSchedule.count >= 2 {
                return activeProfile.targetSchedule.enumerated().map { idx, seg in
                    let endMin = idx + 1 < activeProfile.targetSchedule.count
                        ? activeProfile.targetSchedule[idx + 1].startMinutes
                        : 1440
                    return TargetEvalWindow(
                        timeString: seg.timeString,
                        label: "\(seg.timeString) – \(formatMinutes(endMin))",
                        curLow: seg.lowMgdL,
                        curHigh: seg.highMgdL,
                        matchesMinute: { m in m >= seg.startMinutes && m < endMin }
                    )
                }
            } else {
                let single = activeProfile.targetSchedule.first
                    ?? TargetScheduleSegment(startMinutes: 0, timeString: "00:00", lowMgdL: 100.0, highMgdL: 115.0)
                return [
                    TargetEvalWindow(
                        timeString: "22:00",
                        label: "Overnight & Dawn (22:00 – 08:30)",
                        curLow: single.lowMgdL,
                        curHigh: single.highMgdL,
                        matchesMinute: { m in m >= 1320 || m < 510 }
                    ),
                    TargetEvalWindow(
                        timeString: "08:30",
                        label: "Daytime Active (08:30 – 22:00)",
                        curLow: single.lowMgdL,
                        curHigh: single.highMgdL,
                        matchesMinute: { m in m >= 510 && m < 1320 }
                    )
                ]
            }
        }()

        var targetRecommendations: [TargetRangeRecommendation] = []
        for (wIdx, win) in targetWindows.enumerated() {
            var errsAll: [Double] = []
            var errsByDay: [String: [Double]] = [:]
            for pt in cgm {
                let m = localMinuteOfDay(pt.timestamp)
                guard win.matchesMinute(m) else { continue }
                let err = pt.sgvMgdL - activeTargetMid(at: pt.timestamp)
                errsAll.append(err)
                errsByDay[localDayKey(pt.timestamp), default: []].append(err)
            }
            errsAll.sort()

            let (optMid, floorMid, bgriMin) = solveOptimalTargetMidpoint(sortedErrors: errsAll, strideStep: 1)
            let recLow: Double
            let recHigh: Double
            if displayUnit == .mmolL {
                let lowMmol = (((optMid - 0.5 * targetDeadbandWidthMgdL) / BGUnit.mmolConversionFactor) * 10.0).rounded() / 10.0
                recLow = lowMmol * BGUnit.mmolConversionFactor
                recHigh = recLow + targetDeadbandWidthMgdL
            } else {
                recLow = ((optMid - 0.5 * targetDeadbandWidthMgdL) / 5.0).rounded() * 5.0
                recHigh = recLow + targetDeadbandWidthMgdL
            }

            let dayBlocks = errsByDay.values.filter { $0.count >= 6 }
            let (ciMidLo, ciMidHi): (Double, Double) = {
                guard dayBlocks.count >= 5 else { return (optMid - 5.0, optMid + 5.0) }
                var rng = SplitMix64(seed: UInt64(900 + wIdx))
                var bootMids: [Double] = []
                bootMids.reserveCapacity(200)
                let blocksArray = Array(dayBlocks)
                for _ in 0..<200 {
                    var flat: [Double] = []
                    for _ in 0..<blocksArray.count {
                        let pick = Int(rng.next() % UInt64(blocksArray.count))
                        flat.append(contentsOf: blocksArray[pick])
                    }
                    flat.sort()
                    let (bm, _, _) = solveOptimalTargetMidpoint(sortedErrors: flat, strideStep: 5)
                    bootMids.append(bm)
                }
                bootMids.sort()
                return (percentile(bootMids, p: 0.025), percentile(bootMids, p: 0.975))
            }()

            let predTIR = errsAll.isEmpty ? 0.0 : (100.0 * Double(errsAll.filter { optMid + $0 >= 70.0 && optMid + $0 <= 180.0 }.count) / Double(errsAll.count))
            let curMid = 0.5 * (win.curLow + win.curHigh)
            let status: SyncStatus
            if abs(curMid - optMid) <= 3.0 {
                status = .inSync
            } else if curMid >= (ciMidLo - 2.5) && curMid <= (ciMidHi + 2.5) {
                status = .inConfidenceInterval
            } else {
                status = .adjustRecommended
            }

            let rationale = "ATTD safety floor \(displayUnit.formatBG(floorMid, includeUnit: true)) • Kovatchev BGRI minimum \(displayUnit.formatBG(optMid, includeUnit: true)) (BGRI \(String(format: "%.2f", bgriMin)), Pred TIR \(String(format: "%.1f%%", predTIR))) across \(dayBlocks.count) days. Deadband width \(displayUnit.formatBG(targetDeadbandWidthMgdL, includeUnit: true)) from 5m CGM jitter (\(displayUnit.formatBG(sigmaCGM, includeUnit: true))) & \(String(format: "%.2g", effectiveConfig.pumpQuantum.rawValue))U step."

            targetRecommendations.append(
                TargetRangeRecommendation(
                    timeString: win.timeString,
                    windowLabel: win.label,
                    currentLowMgdL: win.curLow,
                    currentHighMgdL: win.curHigh,
                    recommendedLowMgdL: recLow,
                    recommendedHighMgdL: recHigh,
                    optimalMidMgdL: optMid,
                    ciMidLowMgdL: ciMidLo,
                    ciMidHighMgdL: ciMidHi,
                    safetyFloorMidMgdL: floorMid,
                    bgriScore: bgriMin,
                    predictedTIRPercent: predTIR,
                    dayCount: dayBlocks.count,
                    status: status,
                    rationale: rationale
                )
            )
        }

        // MARK: - Closed-Loop Control Stability Audit & Glycemic Stats

        let stability = computeStabilityAudit(
            activeISF: userISFBlocks[0].value,
            empiricalISF: globalGeomMeanISF,
            peakMinutes: effectiveConfig.peakMinutes,
            diaMinutes: effectiveConfig.diaMinutes,
            sensorJitterMgdL: sigmaCGM,
            pumpStepImpactMgdL: podStepImpact
        )

        let stats24h = computeGlycemicStats(
            label: "24 Hours",
            samples: cgm.filter { $0.timestamp >= maxTS - 86400.0 }
        )
        let stats7d = computeGlycemicStats(
            label: "7 Days",
            samples: cgm.filter { $0.timestamp >= maxTS - 7.0 * 86400.0 }
        )
        let statsRolling = computeGlycemicStats(
            label: "\(config.rollingDays) Days",
            samples: cgm
        )

        let agpBins = computeAGPBins(samples: cgm, localMinuteOfDay: localMinuteOfDay)
        let totalDelivered = pkTimeline.deliveredInsulin(from: minTS, to: maxTS)
        let totalCarbs = sortedCarbs.filter { $0.timestamp >= minTS && $0.timestamp <= maxTS }.map(\.grams).reduce(0.0, +)

        return AdvisorReport(
            generatedAt: Date(),
            sourceURL: bundle.sourceURL,
            activeProfileName: activeProfile.profileName,
            timeZoneIdentifier: activeProfile.timeZoneIdentifier,
            displayUnit: displayUnit,
            rollingDays: config.rollingDays,
            settingsUsed: effectiveConfig,
            stats24h: stats24h,
            stats7d: stats7d,
            statsRolling: statsRolling,
            agpBins: agpBins,
            globalISF: globalISFRec,
            isfSchedule: isfRecommendations,
            basalSchedule: basalRecommendations,
            carbRatioSchedule: crRecommendations,
            targetSchedule: targetRecommendations,
            stability: stability,
            averageDailyInsulinUnits: totalDelivered / spanDays,
            averageDailyCarbsGrams: totalCarbs / spanDays
        )
    }

    // MARK: - Helper Math Routines

    private static func kovatchevBGRisk(_ bg: Double) -> Double {
        let clamped = min(600.0, max(20.0, bg))
        let fSym = 1.509 * (pow(log(clamped), 1.084) - 5.381)
        return 10.0 * fSym * fSym
    }

    private static func solveOptimalTargetMidpoint(sortedErrors: [Double], strideStep: Int) -> (Double, Double, Double) {
        let n = sortedErrors.count
        guard n >= 20 else { return (112.5, 105.0, 4.0) }
        let q04 = sortedErrors[min(n - 1, max(0, Int(0.04 * Double(n))))]
        let q01 = sortedErrors[min(n - 1, max(0, Int(0.01 * Double(n))))]
        let tFloor = max(70.0 - q04, 54.0 - q01)
        var bestMid = tFloor
        var bestBGRI = Double.greatestFiniteMagnitude
        let step = max(1, strideStep)
        var subCount = 0
        for _ in stride(from: 0, to: n, by: step) { subCount += 1 }
        let denom = Double(max(1, subCount))

        for k in 0..<50 {
            let cand = tFloor + Double(k) * 0.5
            if cand > 150.0 { break }
            var acc = 0.0
            for idx in stride(from: 0, to: n, by: step) {
                acc += kovatchevBGRisk(cand + sortedErrors[idx])
            }
            let risk = acc / denom
            if risk < bestBGRI {
                bestBGRI = risk
                bestMid = cand
            }
        }
        return (bestMid, tFloor, bestBGRI)
    }

    private static func computeStabilityAudit(
        activeISF: Double,
        empiricalISF: Double,
        peakMinutes: Double,
        diaMinutes: Double,
        sensorJitterMgdL: Double,
        pumpStepImpactMgdL: Double
    ) -> ControlStabilityAudit {
        let tauHours = max(0.5, peakMinutes / 60.0)
        let horizonHours = max(3.0, diaMinutes / 60.0)
        let kPlant = max(10.0, empiricalISF)
        let kController = 1.0 / max(10.0, activeISF)
        // Effective closed-loop gain normalized by 6h prediction horizon damping
        let loopGain = (kPlant * kController) * (tauHours / (horizonHours * 0.52))
        let naturalWn = sqrt(max(0.05, loopGain)) / tauHours
        let dampingZeta = 1.0 / (2.0 * sqrt(max(0.05, loopGain)))
        let critISF = empiricalISF * (tauHours / (horizonHours * 0.52)) * 4.0 * 0.45
        let gainMargin = max(0.5, activeISF / max(1.0, critISF))
        let phaseMargin = min(165.0, max(15.0, 95.0 * dampingZeta + 35.0))

        let poleSummary: String
        if dampingZeta >= 1.0 {
            let rad = sqrt(max(0.0, dampingZeta * dampingZeta - 1.0))
            let p1 = -naturalWn * (dampingZeta - rad)
            let p2 = -naturalWn * (dampingZeta + rad)
            poleSummary = String(format: "Real [%.2f, %.2f] h⁻¹ (Zero Oscillation)", p1, p2)
        } else {
            let realPart = -dampingZeta * naturalWn
            let imagPart = naturalWn * sqrt(max(0.0, 1.0 - dampingZeta * dampingZeta))
            poleSummary = String(format: "Complex %.2f ± %.2fi h⁻¹", realPart, imagPart)
        }

        return ControlStabilityAudit(
            dampingRatioZeta: dampingZeta,
            poleSummary: poleSummary,
            criticalISFBoundMgdLPerU: critISF,
            gainMarginMultiplier: gainMargin,
            phaseMarginDegrees: phaseMargin,
            sensorJitterMgdL: sensorJitterMgdL,
            pumpStepImpactMgdL: pumpStepImpactMgdL,
            isOverdampedStable: dampingZeta >= 0.85
        )
    }

    private static func computeGlycemicStats(label: String, samples: [CGMSample]) -> GlycemicWindowStats {
        guard !samples.isEmpty else {
            return GlycemicWindowStats(
                label: label, sampleCount: 0, meanMgdL: 0, sdMgdL: 0,
                cvPercent: 0, gmiPercent: 0, tirPercent: 0, tbrPercent: 0,
                veryLowPercent: 0, tarPercent: 0, veryHighPercent: 0
            )
        }
        let n = Double(samples.count)
        let vals = samples.map(\.sgvMgdL)
        let mean = vals.reduce(0.0, +) / n
        let variance = vals.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / max(1.0, n - 1.0)
        let sd = sqrt(variance)
        let cv = mean > 0 ? (sd / mean) * 100.0 : 0.0
        let gmi = 3.31 + 0.02392 * mean
        let tir = 100.0 * Double(vals.filter { $0 >= 70.0 && $0 <= 180.0 }.count) / n
        let tbr = 100.0 * Double(vals.filter { $0 < 70.0 }.count) / n
        let vlow = 100.0 * Double(vals.filter { $0 < 54.0 }.count) / n
        let tar = 100.0 * Double(vals.filter { $0 > 180.0 }.count) / n
        let vhigh = 100.0 * Double(vals.filter { $0 > 250.0 }.count) / n

        return GlycemicWindowStats(
            label: label,
            sampleCount: samples.count,
            meanMgdL: mean,
            sdMgdL: sd,
            cvPercent: cv,
            gmiPercent: gmi,
            tirPercent: tir,
            tbrPercent: tbr,
            veryLowPercent: vlow,
            tarPercent: tar,
            veryHighPercent: vhigh
        )
    }

    private static func computeAGPBins(
        samples: [CGMSample],
        localMinuteOfDay: (TimeInterval) -> Int
    ) -> [AGPBin] {
        // 48 half-hour bins across 24 hours
        var buckets = Array(repeating: [Double](), count: 48)
        for s in samples {
            let b = min(47, max(0, localMinuteOfDay(s.timestamp) / 30))
            buckets[b].append(s.sgvMgdL)
        }
        return (0..<48).compactMap { b in
            let sorted = buckets[b].sorted()
            guard !sorted.isEmpty else { return nil }
            let mins = b * 30
            return AGPBin(
                minuteOfDay: mins,
                hourLabel: formatMinutes(mins),
                p10MgdL: percentile(sorted, p: 0.10),
                p25MgdL: percentile(sorted, p: 0.25),
                p50MgdL: percentile(sorted, p: 0.50),
                p75MgdL: percentile(sorted, p: 0.75),
                p90MgdL: percentile(sorted, p: 0.90)
            )
        }
    }

    private static func percentile(_ sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0.0 }
        if sorted.count == 1 { return sorted[0] }
        let pos = min(1.0, max(0.0, p)) * Double(sorted.count - 1)
        let lo = Int(floor(pos))
        let hi = min(sorted.count - 1, lo + 1)
        let frac = pos - Double(lo)
        return sorted[lo] * (1.0 - frac) + sorted[hi] * frac
    }

    private static func logBootstrapCI(_ values: [Double], seed: Int) -> (Double, Double) {
        var rng = SplitMix64(seed: UInt64(abs(seed) + 1))
        let logs = values.map { log($0) }
        var bootMeans: [Double] = []
        bootMeans.reserveCapacity(400)
        for _ in 0..<400 {
            var acc = 0.0
            for _ in 0..<logs.count {
                let pick = Int(rng.next() % UInt64(logs.count))
                acc += logs[pick]
            }
            bootMeans.append(exp(acc / Double(logs.count)))
        }
        bootMeans.sort()
        return (percentile(bootMeans, p: 0.025), percentile(bootMeans, p: 0.975))
    }

    private static func quantileBootstrapCI(
        _ sortedValues: [Double],
        quantile: Double,
        floorValue: Double,
        seed: Int
    ) -> (Double, Double) {
        var rng = SplitMix64(seed: UInt64(abs(seed) + 1))
        var boots: [Double] = []
        boots.reserveCapacity(300)
        let n = sortedValues.count
        for _ in 0..<300 {
            var sample = [Double]()
            sample.reserveCapacity(n)
            for _ in 0..<n {
                let pick = Int(rng.next() % UInt64(n))
                sample.append(sortedValues[pick])
            }
            sample.sort()
            boots.append(max(floorValue, percentile(sample, p: quantile)))
        }
        boots.sort()
        return (percentile(boots, p: 0.025), percentile(boots, p: 0.975))
    }

    private static func studentTCrit95(df: Int) -> Double {
        let table: [Int: Double] = [
            1: 12.706, 2: 4.303, 3: 3.182, 4: 2.776, 5: 2.571,
            6: 2.447, 7: 2.365, 8: 2.306, 9: 2.262, 10: 2.228,
            12: 2.179, 15: 2.131, 20: 2.086, 25: 2.060, 30: 2.042
        ]
        if let exact = table[df] { return exact }
        if df > 30 { return 1.96 + 2.4 / Double(df) }
        let lowerKeys = table.keys.filter { $0 < df }.sorted()
        if let k = lowerKeys.last, let v = table[k] { return v }
        return 2.0
    }

    private static func formatMinutes(_ mins: Int) -> String {
        let clamped = max(0, min(1440, mins))
        return String(format: "%02d:%02d", clamped / 60, clamped % 60)
    }
}

/// Deterministic fast PRNG so bootstrap 95% CIs are reproducible across runs.
public struct SplitMix64: Sendable {
    private var state: UInt64
    public init(seed: UInt64) { self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
