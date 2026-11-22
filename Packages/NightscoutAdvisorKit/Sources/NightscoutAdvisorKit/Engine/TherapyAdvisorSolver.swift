import Foundation

/// Generalized 4-Stage Coupled Insulin-Kinetics & Stochastic Control Solver.
/// Matches the validated Python reference physics & statistical estimators across all 4 stages
/// while operating dynamically on any Nightscout user's schedule blocks and units.
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

    public static func solve(
        bundle: NightscoutTelemetryBundle,
        config: TherapySettingsConfig
    ) throws -> AdvisorReport {
        let cgm = bundle.cgmSamples.sorted { $0.timestamp < $1.timestamp }
        guard cgm.count >= 24 else { throw SolverError.emptyCGMData }

        let sortedProfiles = bundle.profiles.sorted { $0.effectiveTimestamp < $1.effectiveTimestamp }
        guard let activeProfile = bundle.activeProfile ?? sortedProfiles.last else {
            throw SolverError.missingActiveProfile
        }

        let resolvedTZIdentifier: String = {
            if let pref = config.preferredTimeZoneIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
               !pref.isEmpty,
               TimeZone(identifier: pref) != nil {
                return pref
            }
            return activeProfile.timeZoneIdentifier
        }()
        let tz = TimeZone(identifier: resolvedTZIdentifier) ?? .current
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

        func localMinuteOfDay(_ ts: TimeInterval) -> Int {
            let comps = calendar.dateComponents([.hour, .minute], from: Date(timeIntervalSince1970: ts))
            return (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        }

        func localSecondOfDay(_ ts: TimeInterval) -> Int {
            let comps = calendar.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: ts))
            return (comps.hour ?? 0) * 3600 + (comps.minute ?? 0) * 60 + (comps.second ?? 0)
        }

        func localDayKey(_ ts: TimeInterval) -> String {
            let comps = calendar.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: ts))
            return String(format: "%04d-%02d-%02d", comps.year ?? 2026, comps.month ?? 1, comps.day ?? 1)
        }

        let profTimes = sortedProfiles.map(\.effectiveTimestamp)
        func profileAt(_ ts: TimeInterval) -> HistoricalProfileVersion {
            guard !sortedProfiles.isEmpty else { return activeProfile }
            var lo = 0
            var hi = profTimes.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if profTimes[mid] <= ts {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            return sortedProfiles[max(0, lo - 1)]
        }

        func evalSegmentSec(_ segments: [ScheduleSegment], secondOfDay: Int, fallback: Double) -> Double {
            guard !segments.isEmpty else { return fallback }
            var val = segments[0].value
            for seg in segments {
                if seg.startMinutes * 60 <= secondOfDay {
                    val = seg.value
                } else {
                    break
                }
            }
            return val
        }

        func evalTargetMidSec(_ segments: [TargetScheduleSegment], secondOfDay: Int, fallback: Double = 117.5) -> Double {
            guard !segments.isEmpty else { return fallback }
            var val = segments[0].midMgdL
            for seg in segments {
                if seg.startMinutes * 60 <= secondOfDay {
                    val = seg.midMgdL
                } else {
                    break
                }
            }
            return val
        }

        let sortedOverrides = bundle.targetOverrides.sorted { $0.startTimestamp < $1.startTimestamp }
        let ovStarts = sortedOverrides.map(\.startTimestamp)
        func activeTargetMid(at ts: TimeInterval) -> Double {
            var lo = 0
            var hi = ovStarts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if ovStarts[mid] <= ts {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            let idx = lo - 1
            if idx >= 0 && sortedOverrides[idx].startTimestamp <= ts && ts < sortedOverrides[idx].endTimestamp {
                return sortedOverrides[idx].midMgdL
            }
            let prof = profileAt(ts)
            return evalTargetMidSec(prof.targetSchedule, secondOfDay: localSecondOfDay(ts))
        }

        let exercises = bundle.exerciseWindows
        func inExerciseWindow(from tStart: TimeInterval, to tEnd: TimeInterval) -> Bool {
            exercises.contains { min(tEnd, $0.endTimestamp) - max(tStart, $0.startTimestamp) >= 900.0 }
        }

        // Exact 5-minute discrete exponential PK timeline
        let pkTimeline = InsulinKineticsTimeline(
            startTimestamp: minTS,
            endTimestamp: maxTS,
            peakMinutes: effectiveConfig.peakMinutes,
            diaMinutes: effectiveConfig.diaMinutes,
            boluses: bundle.boluses,
            tempBasals: bundle.tempBasals,
            scheduledBasalRateAt: { ts in
                let prof = profileAt(ts)
                return evalSegmentSec(prof.basalSchedule, secondOfDay: localSecondOfDay(ts), fallback: 0.10)
            }
        )

        let cgmTimes = cgm.map(\.timestamp)
        func bgAt(_ ts: TimeInterval, maxGapSeconds: TimeInterval = 900.0) -> Double? {
            var lo = 0
            var hi = cgmTimes.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if cgmTimes[mid] < ts {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            var bestVal: Double?
            var minDist = TimeInterval.greatestFiniteMagnitude
            let startIdx = max(0, lo - 2)
            let endIdx = min(cgm.count, lo + 3)
            for i in startIdx..<endIdx {
                let d = abs(cgm[i].timestamp - ts)
                if d < minDist && d <= maxGapSeconds {
                    minDist = d
                    bestVal = cgm[i].sgvMgdL
                }
            }
            return bestVal
        }

        let sortedCarbs = bundle.carbs.sorted { $0.timestamp < $1.timestamp }
        let sortedBoluses = bundle.boluses.sorted { $0.timestamp < $1.timestamp }

        // Respects declared Nightscout absorptionTime (45m for <=40m rescue carbs, >=3.5h for standard meals)
        func hasActiveGutCarbs(from t1: TimeInterval, to t2: TimeInterval) -> Bool {
            for c in sortedCarbs {
                if c.timestamp > t2 { break }
                let effAbs = c.absorptionSeconds <= 2400.0 ? 2700.0 : max(12600.0, c.absorptionSeconds)
                if c.timestamp <= t2 && (c.timestamp + effAbs) > t1 {
                    return true
                }
            }
            return false
        }

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

        func roundISFToGrid(_ mgdLPerU: Double) -> Double {
            if displayUnit == .mmolL {
                let mmolVal = (mgdLPerU / BGUnit.mmolConversionFactor * 10.0).rounded() / 10.0
                return mmolVal * BGUnit.mmolConversionFactor
            } else {
                return (mgdLPerU / 5.0).rounded() * 5.0
            }
        }

        // MARK: - Coupled Solvers 1 & 2 (Exact Kinetic ISF <-> Fasting EGP Basal)

        let curISF = activeProfile.isfSchedule.first?.value ?? 100.0
        var recISF = curISF
        var geomISF = curISF

        // Build isolated correction bolus clusters (boluses without concurrent carbs within +-10m)
        let corrTreatments = sortedBoluses.filter { bol in
            !sortedCarbs.contains { abs($0.timestamp - bol.timestamp) < 600.0 }
        }
        var corrClusters: [[BolusEvent]] = []
        var curCluster: [BolusEvent] = []
        for bol in corrTreatments {
            if curCluster.isEmpty || bol.timestamp - curCluster.last!.timestamp <= 2700.0 {
                curCluster.append(bol)
            } else {
                corrClusters.append(curCluster)
                curCluster = [bol]
            }
        }
        if !curCluster.isEmpty {
            corrClusters.append(curCluster)
        }

        var basalSamplesByBlock: [Int: [Double]] = [:]
        var egpMedByBlock: [Int: Double] = [:]
        var solvedEpisodeDetails: [ISFEpisodeDetail] = []

        func integrateBasalMap(_ rateByBlock: [Int: Double], fallback: Double, from t1: TimeInterval, to t2: TimeInterval) -> Double {
            guard t2 > t1 else { return 0.0 }
            var tot = 0.0
            var tt = t1
            while tt < t2 {
                let nxt = min(t2, tt + 300.0)
                let midMin = localMinuteOfDay(0.5 * (tt + nxt))
                let bIdx = blockIndex(for: midMin, in: userBasalBlocks)
                tot += (rateByBlock[bIdx] ?? fallback) * ((nxt - tt) / 3600.0)
                tt = nxt
            }
            return tot
        }

        let diaSeconds = effectiveConfig.diaMinutes * 60.0
        let startFastingT = ceil((minTS + diaSeconds) / 1800.0) * 1800.0

        for _ in 0..<4 {
            basalSamplesByBlock = [:]
            var curT = startFastingT
            while curT + 3600.0 <= maxTS {
                let t1 = curT
                let t2 = curT + 3600.0
                curT += 1800.0
                if hasActiveGutCarbs(from: t1, to: t2) { continue }
                if inExerciseWindow(from: t1 - 1800.0, to: t2) { continue }
                guard let bg1 = bgAt(t1, maxGapSeconds: 600.0),
                      let bg2 = bgAt(t2, maxGapSeconds: 600.0) else { continue }
                // Normoglycemic start (70..180); retain drops down to 40 mg/dL to avoid hypo survivorship bias
                guard bg1 >= 70.0, bg1 <= 180.0, bg2 >= 40.0, bg2 <= 180.0 else { continue }

                let iFlux = pkTimeline.absorbedInsulin(from: t1, to: t2) + ((bg2 - bg1) / recISF)
                let bIdx = blockIndex(for: localMinuteOfDay(t1), in: userBasalBlocks)
                basalSamplesByBlock[bIdx, default: []].append(iFlux)
            }

            egpMedByBlock = [:]
            for (bIdx, vals) in basalSamplesByBlock where !vals.isEmpty {
                egpMedByBlock[bIdx] = percentile(vals.sorted(), p: 0.50)
            }

            var iterEpisodes: [ISFEpisodeDetail] = []
            var lastISFNadirTS: TimeInterval = 0.0

            for cl in corrClusters {
                let tStart = cl[0].timestamp
                let totalBol = cl.reduce(0.0) { $0 + $1.units }
                if tStart <= lastISFNadirTS || totalBol < 0.15 { continue }
                if hasActiveGutCarbs(from: tStart, to: tStart + 3600.0) { continue }
                guard let bgBolus = bgAt(tStart, maxGapSeconds: 600.0), bgBolus >= 165.0 else { continue }

                // Truncate nadir search prior to any post-drop low-BG rescue carb rather than discarding episode
                let laterCarbs = sortedCarbs.filter { $0.timestamp > tStart + 3600.0 && $0.timestamp <= tStart + 14400.0 }
                let searchEnd: TimeInterval
                if let firstC = laterCarbs.first {
                    guard let bgAtC = bgAt(firstC.timestamp, maxGapSeconds: 600.0),
                          bgAtC < 90.0,
                          firstC.grams <= 16.0 else {
                        continue
                    }
                    searchEnd = firstC.timestamp
                } else {
                    searchEnd = tStart + 14400.0
                }

                let cgmAfter = cgm.filter { $0.timestamp >= tStart + 3600.0 && $0.timestamp <= searchEnd }
                guard let nadirPt = cgmAfter.min(by: { $0.sgvMgdL < $1.sgvMgdL }) else { continue }
                let drop = bgBolus - nadirPt.sgvMgdL
                if drop < 25.0 || inExerciseWindow(from: tStart - 1800.0, to: nadirPt.timestamp) {
                    continue
                }

                let iAbsWin = pkTimeline.absorbedInsulin(from: tStart, to: nadirPt.timestamp)
                let egpOffset = integrateBasalMap(egpMedByBlock, fallback: 0.25, from: tStart, to: nadirPt.timestamp)
                let netIAbs = iAbsWin - egpOffset
                if netIAbs > 0.12 {
                    let epISF = drop / netIAbs
                    if epISF >= 15.0 && epISF <= 500.0 {
                        iterEpisodes.append(
                            ISFEpisodeDetail(
                                timestamp: tStart,
                                bgBolusMgdL: bgBolus,
                                bgNadirMgdL: nadirPt.sgvMgdL,
                                dropMgdL: drop,
                                absorbedInsulinU: iAbsWin,
                                egpOffsetU: egpOffset,
                                netCorrectionU: netIAbs,
                                impliedISFMgdLPerU: epISF
                            )
                        )
                        lastISFNadirTS = nadirPt.timestamp
                    }
                }
            }

            solvedEpisodeDetails = iterEpisodes
            if !iterEpisodes.isEmpty {
                let meanLog = iterEpisodes.map { log($0.impliedISFMgdLPerU) }.reduce(0.0, +) / Double(iterEpisodes.count)
                geomISF = exp(meanLog)
                recISF = roundISFToGrid(geomISF)
            }
        }

        // Build ISF Schedule Recommendations
        let userISFBlocks = activeProfile.isfSchedule.isEmpty
            ? [ScheduleSegment(startMinutes: 0, timeString: "00:00", value: curISF)]
            : activeProfile.isfSchedule

        var isfRecommendations: [ISFRecommendation] = []
        for (idx, seg) in userISFBlocks.enumerated() {
            let endMin = idx + 1 < userISFBlocks.count ? userISFBlocks[idx + 1].startMinutes : 1440
            let winLabel = "\(seg.timeString) – \(formatMinutes(endMin))"
            let blockEps = solvedEpisodeDetails.filter { ep in
                let m = localMinuteOfDay(ep.timestamp)
                return m >= seg.startMinutes && m < endMin
            }.map(\.impliedISFMgdLPerU)

            let usedEps = blockEps.count >= 3 ? blockEps : solvedEpisodeDetails.map(\.impliedISFMgdLPerU)
            let geomVal: Double
            let medVal: Double
            let recVal: Double
            let ciLo: Double
            let ciHi: Double
            if !usedEps.isEmpty {
                geomVal = exp(usedEps.map { log($0) }.reduce(0.0, +) / Double(usedEps.count))
                medVal = percentile(usedEps.sorted(), p: 0.50)
                recVal = roundISFToGrid(geomVal)
                let empMin = usedEps.min() ?? recVal
                let empMax = usedEps.max() ?? recVal
                ciLo = empMin.rounded()
                ciHi = empMax.rounded()
            } else {
                geomVal = seg.value
                medVal = seg.value
                recVal = seg.value
                ciLo = seg.value
                ciHi = seg.value
            }

            let isISFInCI = (seg.value >= ciLo && seg.value <= ciHi)
            let status: SyncStatus
            if usedEps.isEmpty {
                status = .insufficientData
            } else if abs(seg.value - recVal) <= max(15.0, 0.10 * recVal) {
                status = abs(seg.value - recVal) < 2.0 ? .inSync : .inConfidenceInterval
            } else if isISFInCI {
                status = .inConfidenceInterval
            } else {
                status = .adjustRecommended
            }

            let rationale = usedEps.isEmpty
                ? "No isolated carb-free correction episodes (\(winLabel)); retaining active profile setting."
                : "Exact kinetic log-symmetric geometric mean across N=\(usedEps.count) correction episodes (\(displayUnit.formatISF(geomVal, includeUnit: true)); observed range \(displayUnit.formatISF(ciLo, includeUnit: false))–\(displayUnit.formatISF(ciHi, includeUnit: true)))."

            isfRecommendations.append(
                ISFRecommendation(
                    timeString: seg.timeString,
                    windowLabel: winLabel,
                    currentMgdLPerU: seg.value,
                    recommendedMgdLPerU: recVal,
                    geometricMeanMgdLPerU: geomVal,
                    medianMgdLPerU: medVal,
                    ciLowMgdLPerU: ciLo,
                    ciHighMgdLPerU: ciHi,
                    episodeCount: usedEps.count,
                    status: status,
                    rationale: rationale
                )
            )
        }

        let allEpISFs = solvedEpisodeDetails.map(\.impliedISFMgdLPerU).sorted()
        let globalMedISF = allEpISFs.isEmpty ? userISFBlocks[0].value : percentile(allEpISFs, p: 0.50)
        let globalISFRec = ISFRecommendation(
            timeString: userISFBlocks[0].timeString,
            windowLabel: "00:00 – 24:00",
            currentMgdLPerU: userISFBlocks[0].value,
            recommendedMgdLPerU: recISF,
            geometricMeanMgdLPerU: geomISF,
            medianMgdLPerU: globalMedISF,
            ciLowMgdLPerU: isfRecommendations.first?.ciLowMgdLPerU ?? recISF,
            ciHighMgdLPerU: isfRecommendations.first?.ciHighMgdLPerU ?? recISF,
            episodeCount: solvedEpisodeDetails.count,
            status: isfRecommendations.first?.status ?? .inSync,
            rationale: isfRecommendations.first?.rationale ?? ""
        )

        // MARK: - Stage 2: Universal ATTD Asymmetric-Quantile Basal Solver

        let tauStar = effectiveConfig.dosingMode.basalQuantileTau
        let qStep = effectiveConfig.pumpQuantum.rawValue
        var basalRecommendations: [BasalRecommendation] = []
        var solvedBasalByBlock: [Int: Double] = [:]

        for (bIdx, seg) in userBasalBlocks.enumerated() {
            let endMin = bIdx + 1 < userBasalBlocks.count ? userBasalBlocks[bIdx + 1].startMinutes : 1440
            let winLabel = "\(seg.timeString) – \(formatMinutes(endMin))"
            let samps = (basalSamplesByBlock[bIdx] ?? []).sorted()

            if samps.count >= 5 {
                let qATTD = percentile(samps, p: tauStar)
                let medEGP = percentile(samps, p: 0.50)
                let rawRec = max(qStep, ((max(0.0, qATTD) / qStep) + 1e-9).rounded() * qStep)

                let (boot025, boot975) = rawQuantileBootstrapCI(samps, quantile: tauStar, iterations: 1000, seed: 42 + bIdx)
                let ciLo = min(rawRec, (max(0.0, boot025) * 1000.0).rounded() / 1000.0)
                let ciHi = max(rawRec, (max(qStep, boot975) * 1000.0).rounded() / 1000.0)
                solvedBasalByBlock[bIdx] = rawRec

                let status: SyncStatus
                if abs(seg.value - rawRec) < 0.01 {
                    status = .inSync
                } else if seg.value >= (ciLo - 0.005) && seg.value <= (ciHi + 0.005) {
                    status = .inConfidenceInterval
                } else {
                    status = .adjustRecommended
                }

                let autoSupp = max(0.0, medEGP - rawRec)
                let rationale = String(
                    format: "ATTD closed-loop quantile τ* = %.1f%% across N=%d fasting hours (τ* baseline: %.3f U/hr → %.2f U/hr; median total EGP flux: %.3f U/hr, with ~%.2f U/hr supplied dynamically on higher-demand days).",
                    tauStar * 100.0, samps.count, max(0.0, qATTD), rawRec, max(0.0, medEGP), autoSupp
                )

                basalRecommendations.append(
                    BasalRecommendation(
                        timeString: seg.timeString,
                        windowLabel: winLabel,
                        currentUnitsPerHour: seg.value,
                        recommendedUnitsPerHour: rawRec,
                        rawQuantileFlux: max(0.0, qATTD),
                        medianTotalFlux: max(0.0, medEGP),
                        ciLowUnitsPerHour: ciLo,
                        ciHighUnitsPerHour: ciHi,
                        fastingHourCount: samps.count,
                        status: status,
                        rationale: rationale
                    )
                )
            } else {
                let rec = max(qStep, seg.value)
                solvedBasalByBlock[bIdx] = rec
                basalRecommendations.append(
                    BasalRecommendation(
                        timeString: seg.timeString,
                        windowLabel: winLabel,
                        currentUnitsPerHour: seg.value,
                        recommendedUnitsPerHour: rec,
                        rawQuantileFlux: rec,
                        medianTotalFlux: rec,
                        ciLowUnitsPerHour: rec,
                        ciHighUnitsPerHour: rec,
                        fastingHourCount: samps.count,
                        status: .insufficientData,
                        rationale: "Insufficient carb-free fasting windows (N=\(samps.count) hrs in \(winLabel)); anchored to active profile (\(String(format: "%.2f", rec)) U/hr)."
                    )
                )
            }
        }

        // MARK: - Stage 3: Kinetic Mass-Balance & Gauss-Markov WLS Carb Ratio Solver

        struct MealCluster {
            let startTS: TimeInterval
            let carbs: Double
            let maxAbsSec: TimeInterval
        }

        var clusteredMeals: [MealCluster] = []
        var curMT: TimeInterval?
        var curMC: Double = 0.0
        var curMAbs: TimeInterval = 10800.0

        for c in sortedCarbs {
            let bgAtC = bgAt(c.timestamp, maxGapSeconds: 600.0)
            if curMT == nil || (c.timestamp - curMT!) >= 2700.0 {
                if let validMT = curMT, curMC >= 8.0 {
                    clusteredMeals.append(MealCluster(startTS: validMT, carbs: curMC, maxAbsSec: curMAbs))
                }
                // Standalone fast-acting hypo rescue (<85 mg/dL, <=40m, <=12g) does not initiate a meal cluster
                if c.absorptionSeconds <= 2400.0 && (bgAtC != nil && bgAtC! < 85.0) && c.grams <= 12.0 {
                    curMT = nil
                    curMC = 0.0
                    curMAbs = 10800.0
                } else {
                    curMT = c.timestamp
                    curMC = c.grams
                    curMAbs = c.absorptionSeconds
                }
            } else {
                curMC += c.grams
                curMAbs = max(curMAbs, c.absorptionSeconds)
            }
        }
        if let validMT = curMT, curMC >= 8.0 {
            clusteredMeals.append(MealCluster(startTS: validMT, carbs: curMC, maxAbsSec: curMAbs))
        }

        let userCRBlocks: [ScheduleSegment] = activeProfile.carbRatioSchedule.isEmpty
            ? [ScheduleSegment(startMinutes: 0, timeString: "00:00", value: 10.0)]
            : activeProfile.carbRatioSchedule

        let mealHorizonSec: TimeInterval = 12600.0 // 3.5h horizon
        var slotPts: [Int: [(carbs: Double, iFood: Double)]] = [:]
        var slotDeltas: [Int: [Double]] = [:]
        var slotRescueCounts: [Int: Int] = [:]

        for cl in clusteredMeals {
            let mt = cl.startTS
            guard let bg0 = bgAt(mt, maxGapSeconds: 900.0),
                  let bgEnd = bgAt(mt + mealHorizonSec, maxGapSeconds: 900.0),
                  bg0 >= 75.0 else { continue }

            // Exclude overlapping second meals in (0, 3.5h), while retaining low-BG rescue treatments (<90 mg/dL, <=16g)
            let subMeals = clusteredMeals.filter { $0.startTS > mt && ($0.startTS - mt) < mealHorizonSec }
            if !subMeals.isEmpty {
                let allRescues = subMeals.allSatisfy { sm in
                    let b = bgAt(sm.startTS, maxGapSeconds: 600.0) ?? 999.0
                    return b < 90.0 && sm.carbs <= 16.0
                }
                if !allRescues { continue }
            }
            if inExerciseWindow(from: mt - 900.0, to: mt + mealHorizonSec) { continue }

            let cIdx = blockIndex(for: localMinuteOfDay(mt), in: userCRBlocks)
            let totCarbs = sortedCarbs
                .filter { $0.timestamp >= mt - 300.0 && $0.timestamp < mt + mealHorizonSec }
                .reduce(0.0) { $0 + $1.grams }
            let hasLoggedFollowup = totCarbs > cl.carbs
            let postBGs = cgm
                .filter { $0.timestamp >= mt + 1800.0 && $0.timestamp <= mt + mealHorizonSec }
                .map(\.sgvMgdL)
            let nadirBG = postBGs.min() ?? bgEnd
            let effBGEnd = (nadirBG < 70.0 && !hasLoggedFollowup) ? min(bgEnd, nadirBG) : bgEnd

            let tW0 = mt - 1200.0
            let tW1 = mt + mealHorizonSec
            let iAbsMeal = pkTimeline.absorbedInsulin(from: tW0, to: tW1)
            let bSchedMeal = integrateBasalMap(solvedBasalByBlock, fallback: 0.10, from: tW0, to: tW1)
            let iFood = iAbsMeal - bSchedMeal + ((effBGEnd - bg0) / recISF)

            let maxPlausibleCR = max(25.0, userCRBlocks[cIdx].value * 2.8)
            if iFood > 0.2 && totCarbs >= 6.0 && (totCarbs / iFood) <= maxPlausibleCR {
                slotPts[cIdx, default: []].append((totCarbs, iFood))
                let activeTMid = activeTargetMid(at: mt + mealHorizonSec)
                slotDeltas[cIdx, default: []].append(bgEnd - activeTMid)
                if hasLoggedFollowup || nadirBG < 70.0 {
                    slotRescueCounts[cIdx, default: 0] += 1
                }
            }
        }

        var crRecommendations: [CarbRatioRecommendation] = []
        for (cIdx, seg) in userCRBlocks.enumerated() {
            let endMin = cIdx + 1 < userCRBlocks.count ? userCRBlocks[cIdx + 1].startMinutes : 1440
            let winLabel = "\(seg.timeString) – \(formatMinutes(endMin))"
            let pts = slotPts[cIdx] ?? []
            let deltas = slotDeltas[cIdx] ?? []
            let rescueN = slotRescueCounts[cIdx] ?? 0
            let n = pts.count
            let isNocturnalSlot = (seg.startMinutes == 0 && endMin <= 540) || seg.startMinutes >= 1260

            if n >= 2 {
                let sumC = pts.reduce(0.0) { $0 + $1.carbs }
                let sumI = pts.reduce(0.0) { $0 + $1.iFood }
                let betaWLS = sumC > 0 ? (sumI / sumC) : (1.0 / seg.value)
                let wlsCR = betaWLS > 0 ? (1.0 / betaWLS) : seg.value

                let df = max(1, n - 1)
                let s2WLS = pts.reduce(0.0) { acc, item in
                    let r = item.iFood - betaWLS * item.carbs
                    return acc + (r * r) / item.carbs
                } / Double(df)
                let seBeta = sumC > 0 ? sqrt(s2WLS / sumC) : 0.0
                let relSE = betaWLS > 0 ? (seBeta / betaWLS) : 1.0
                let tCrit = studentTCrit95(df: df)
                let betaLow = max(1e-4, betaWLS - tCrit * seBeta)
                let betaHigh = betaWLS + tCrit * seBeta

                let crCILo = ((1.0 / betaHigh) * 10.0).rounded() / 10.0
                let crCIHi = ((1.0 / betaLow) * 10.0).rounded() / 10.0

                let empCRs = pts.compactMap { $0.iFood > 0 ? ($0.carbs / $0.iFood) : nil }
                let empMin = empCRs.min().map { ($0 * 10.0).rounded() / 10.0 } ?? seg.value
                let empMax = empCRs.max().map { ($0 * 10.0).rounded() / 10.0 } ?? seg.value

                let meanC = sumC / Double(n)
                let meanI = sumI / Double(n)
                let covCI = pts.reduce(0.0) { $0 + ($1.carbs - meanC) * ($1.iFood - meanI) }
                let varC = pts.reduce(0.0) { $0 + pow($1.carbs - meanC, 2) }
                let varI = pts.reduce(0.0) { $0 + pow($1.iFood - meanI, 2) }
                let rSquared = (varC > 0 && varI > 0) ? ((covCI * covCI) / (varC * varI)) : 0.0
                let medDelta = deltas.isEmpty ? 0.0 : percentile(deltas.sorted(), p: 0.50)

                let isUnderpowered = (n < 4) || (seBeta > 0 && (betaWLS / seBeta) < tCrit)
                if isUnderpowered && !isNocturnalSlot {
                    crRecommendations.append(
                        CarbRatioRecommendation(
                            timeString: seg.timeString,
                            windowLabel: winLabel,
                            currentGramsPerUnit: seg.value,
                            recommendedGramsPerUnit: seg.value,
                            rawWLSGramsPerUnit: wlsCR,
                            ciLowGramsPerUnit: crCILo,
                            ciHighGramsPerUnit: crCIHi,
                            empiricalMinGramsPerUnit: empMin,
                            empiricalMaxGramsPerUnit: empMax,
                            relativeStandardError: relSE,
                            rescueWindowCount: rescueN,
                            centeredRSquared: rSquared,
                            medianPostMealTargetDeltaMgdL: medDelta,
                            mealCount: n,
                            status: .insufficientData,
                            rationale: String(format: "Underpowered sample (N=%d, WLS 1:%.1f g/U). Maintaining active profile setting (1:%.1f g/U).", n, wlsCR, seg.value)
                        )
                    )
                } else if n < 5 && isNocturnalSlot {
                    crRecommendations.append(
                        CarbRatioRecommendation(
                            timeString: seg.timeString,
                            windowLabel: winLabel,
                            currentGramsPerUnit: seg.value,
                            recommendedGramsPerUnit: seg.value,
                            rawWLSGramsPerUnit: wlsCR,
                            ciLowGramsPerUnit: crCILo,
                            ciHighGramsPerUnit: crCIHi,
                            empiricalMinGramsPerUnit: empMin,
                            empiricalMaxGramsPerUnit: empMax,
                            relativeStandardError: relSE,
                            rescueWindowCount: rescueN,
                            centeredRSquared: rSquared,
                            medianPostMealTargetDeltaMgdL: medDelta,
                            mealCount: n,
                            status: .inSync,
                            rationale: String(format: "Sparse nocturnal meals (N=%d, WLS 1:%.1f g/U). Anchored to active profile setting (1:%.1f g/U).", n, wlsCR, seg.value)
                        )
                    )
                } else {
                    let recCR = (wlsCR * 10.0).rounded() / 10.0
                    let status: SyncStatus
                    if abs(seg.value - recCR) < 0.2 {
                        status = .inSync
                    } else if seg.value >= crCILo && seg.value <= crCIHi {
                        status = .inConfidenceInterval
                    } else {
                        status = .adjustRecommended
                    }

                    let deltaDisplay = displayUnit.formatBG(abs(medDelta), includeUnit: true)
                    let signStr = medDelta >= 0 ? "+" : "−"
                    let rationale = String(
                        format: "Gauss-Markov WLS (w = 1/C): 1:%.1f g/U (N = %d, Centered R² = %.2f, Med 3.5h BG − Target = %@%@). 95%% CI: 1:%.1f – 1:%.1f g/U.",
                        wlsCR, n, rSquared, signStr, deltaDisplay, crCILo, crCIHi
                    )

                    crRecommendations.append(
                        CarbRatioRecommendation(
                            timeString: seg.timeString,
                            windowLabel: winLabel,
                            currentGramsPerUnit: seg.value,
                            recommendedGramsPerUnit: recCR,
                            rawWLSGramsPerUnit: wlsCR,
                            ciLowGramsPerUnit: crCILo,
                            ciHighGramsPerUnit: crCIHi,
                            empiricalMinGramsPerUnit: empMin,
                            empiricalMaxGramsPerUnit: empMax,
                            relativeStandardError: relSE,
                            rescueWindowCount: rescueN,
                            centeredRSquared: rSquared,
                            medianPostMealTargetDeltaMgdL: medDelta,
                            mealCount: n,
                            status: status,
                            rationale: rationale
                        )
                    )
                }
            } else {
                crRecommendations.append(
                    CarbRatioRecommendation(
                        timeString: seg.timeString,
                        windowLabel: winLabel,
                        currentGramsPerUnit: seg.value,
                        recommendedGramsPerUnit: seg.value,
                        rawWLSGramsPerUnit: seg.value,
                        ciLowGramsPerUnit: seg.value,
                        ciHighGramsPerUnit: seg.value,
                        empiricalMinGramsPerUnit: seg.value,
                        empiricalMaxGramsPerUnit: seg.value,
                        relativeStandardError: 0.0,
                        rescueWindowCount: rescueN,
                        centeredRSquared: 0.0,
                        medianPostMealTargetDeltaMgdL: 0.0,
                        mealCount: n,
                        status: .insufficientData,
                        rationale: "Fasting period with minimal isolated meals (N=\(n)); anchored to active profile (1:\(String(format: "%.1f", seg.value)) g/U)."
                    )
                )
            }
        }

        // MARK: - Stage 4: Optimal Correction Target Range Solver

        var adjDiffs: [Double] = []
        for i in 1..<cgm.count {
            let dt = cgm[i].timestamp - cgm[i - 1].timestamp
            if dt >= 240.0 && dt <= 360.0 {
                adjDiffs.append(abs(cgm[i].sgvMgdL - cgm[i - 1].sgvMgdL))
            }
        }
        adjDiffs.sort()
        let sigmaCGM = adjDiffs.isEmpty ? 5.5 : (percentile(adjDiffs, p: 0.50) / 0.6745) / sqrt(2.0)
        let podStepImpact = qStep * recISF
        let rawDeadband = 2.0 * max(sigmaCGM, podStepImpact)
        let targetDeadbandWidthMgdL: Double = displayUnit == .mmolL
            ? ceil((rawDeadband / BGUnit.mmolConversionFactor) / 0.2) * 0.2 * BGUnit.mmolConversionFactor
            : max(10.0, ceil(rawDeadband / 5.0) * 5.0)

        struct TargetEvalWindow {
            let timeString: String
            let label: String
            let curLow: Double
            let curHigh: Double
            let matchesMinute: (Int) -> Bool
        }

        let targetWindows: [TargetEvalWindow] = {
            let sched = activeProfile.targetSchedule
            if sched.count >= 3,
               let first = sched.first,
               let last = sched.last,
               first.startMinutes == 0,
               last.startMinutes > 0,
               abs(first.lowMgdL - last.lowMgdL) < 0.5,
               abs(first.highMgdL - last.highMgdL) < 0.5 {
                // Merge contiguous midnight wrap-around window (e.g. 22:00-24:00 + 00:00-08:30)
                let wrapEndMin = sched[1].startMinutes
                var windows: [TargetEvalWindow] = [
                    TargetEvalWindow(
                        timeString: last.timeString,
                        label: "Overnight & Dawn (\(last.timeString) – \(formatMinutes(wrapEndMin)))",
                        curLow: last.lowMgdL,
                        curHigh: last.highMgdL,
                        matchesMinute: { m in m >= last.startMinutes || m < wrapEndMin }
                    )
                ]
                for idx in 1..<(sched.count - 1) {
                    let seg = sched[idx]
                    let endMin = sched[idx + 1].startMinutes
                    let prefix = (sched.count == 3) ? "Daytime Active " : ""
                    windows.append(
                        TargetEvalWindow(
                            timeString: seg.timeString,
                            label: prefix.isEmpty
                                ? "\(seg.timeString) – \(formatMinutes(endMin))"
                                : "\(prefix)(\(seg.timeString) – \(formatMinutes(endMin)))",
                            curLow: seg.lowMgdL,
                            curHigh: seg.highMgdL,
                            matchesMinute: { m in m >= seg.startMinutes && m < endMin }
                        )
                    )
                }
                return windows
            } else if sched.count >= 2 {
                return sched.enumerated().map { idx, seg in
                    let endMin = idx + 1 < sched.count
                        ? sched[idx + 1].startMinutes
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
                let single = sched.first
                    ?? TargetScheduleSegment(startMinutes: 0, timeString: "00:00", lowMgdL: 110.0, highMgdL: 125.0)
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

            let (optMid, floorMid, bgriMin, q04Val, q01Val) = solveOptimalTargetMidpoint(sortedErrors: errsAll, strideStep: 1)
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
                bootMids.reserveCapacity(250)
                let blocksArray = Array(dayBlocks)
                for _ in 0..<250 {
                    var flat: [Double] = []
                    for _ in 0..<blocksArray.count {
                        let pick = Int(rng.next() % UInt64(blocksArray.count))
                        flat.append(contentsOf: blocksArray[pick])
                    }
                    flat.sort()
                    let (bm, _, _, _, _) = solveOptimalTargetMidpoint(sortedErrors: flat, strideStep: 4)
                    bootMids.append(bm)
                }
                bootMids.sort()
                return (
                    (bootMids[Int(0.025 * Double(bootMids.count))] * 10.0).rounded() / 10.0,
                    (bootMids[Int(0.975 * Double(bootMids.count))] * 10.0).rounded() / 10.0
                )
            }()

            let predTIR = errsAll.isEmpty ? 0.0 : (100.0 * Double(errsAll.filter { optMid + $0 >= 70.0 && optMid + $0 <= 180.0 }.count) / Double(errsAll.count))
            let curMid = 0.5 * (win.curLow + win.curHigh)
            let status: SyncStatus
            if (Int(win.curLow.rounded()) == Int(recLow.rounded()) && Int(win.curHigh.rounded()) == Int(recHigh.rounded())) || abs(curMid - optMid) <= 3.0 {
                status = .inSync
            } else if curMid >= (ciMidLo - 2.5) && curMid <= (ciMidHi + 2.5) {
                status = .inConfidenceInterval
            } else {
                status = .adjustRecommended
            }

            let rationale = "ATTD safety floor \(displayUnit.formatBG(floorMid, includeUnit: true)) • Kovatchev BGRI minimum \(displayUnit.formatBG(optMid, includeUnit: true)) (BGRI \(String(format: "%.2f", bgriMin)), Pred TIR \(String(format: "%.1f%%", predTIR))) across \(dayBlocks.count) days. Deadband width \(displayUnit.formatBG(targetDeadbandWidthMgdL, includeUnit: true))."

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
                    q04ErrorMgdL: q04Val,
                    q01ErrorMgdL: q01Val,
                    sampleCount: errsAll.count,
                    bgriScore: bgriMin,
                    predictedTIRPercent: predTIR,
                    dayCount: dayBlocks.count,
                    status: status,
                    rationale: rationale
                )
            )
        }

        // MARK: - Control Stability & Glycemic Stats

        let stability = computeStabilityAudit(
            recommendedISF: recISF,
            empiricalISF: geomISF,
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
            profileUpdatedTimestamp: activeProfile.effectiveTimestamp,
            latestCGMTimestamp: maxTS,
            timeZoneIdentifier: tz.identifier,
            displayUnit: displayUnit,
            rollingDays: config.rollingDays,
            settingsUsed: effectiveConfig,
            stats24h: stats24h,
            stats7d: stats7d,
            statsRolling: statsRolling,
            agpBins: agpBins,
            globalISF: globalISFRec,
            isfEpisodes: solvedEpisodeDetails,
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

    private static func solveOptimalTargetMidpoint(sortedErrors: [Double], strideStep: Int) -> (Double, Double, Double, Double, Double) {
        let n = sortedErrors.count
        guard n >= 20 else { return (112.5, 105.0, 4.0, -35.0, -50.0) }
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
            if cand > 145.0 { break }
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
        return (bestMid, tFloor, bestBGRI, q04, q01)
    }

    private static func computeStabilityAudit(
        recommendedISF: Double,
        empiricalISF: Double,
        peakMinutes: Double,
        diaMinutes: Double,
        sensorJitterMgdL: Double,
        pumpStepImpactMgdL: Double
    ) -> ControlStabilityAudit {
        let tauDelay = max(0.5, peakMinutes / 60.0)
        let tauDIA = max(3.0, diaMinutes / 60.0)
        let isfTrue = max(10.0, empiricalISF)
        let recISF = max(10.0, recommendedISF)

        let aCoeff = tauDIA * tauDelay
        let bCoeff = tauDIA + tauDelay
        let cCoeff = 1.0 + (isfTrue / recISF)

        let dampingRatio = bCoeff / (2.0 * sqrt(aCoeff * cCoeff))
        let discrim = bCoeff * bCoeff - 4.0 * aCoeff * cCoeff

        let poleSummary: String
        if discrim >= 0 {
            let p1 = (-bCoeff + sqrt(discrim)) / (2.0 * aCoeff)
            let p2 = (-bCoeff - sqrt(discrim)) / (2.0 * aCoeff)
            poleSummary = String(format: "Real [%.2f, %.2f] h⁻¹ (Zero Oscillation)", p1, p2)
        } else {
            let realP = -bCoeff / (2.0 * aCoeff)
            let imagP = sqrt(-discrim) / (2.0 * aCoeff)
            poleSummary = String(format: "Complex [%.2f ± %.2fj] h⁻¹", realP, imagP)
        }

        let cCrit = (bCoeff * bCoeff) / (4.0 * aCoeff)
        let critISFBound = isfTrue / max(0.05, cCrit - 1.0)
        let gainMargin = critISFBound > 0 ? (recISF / critISFBound) : 1.2

        var loW = 0.1
        var hiW = 10.0
        for _ in 0..<50 {
            let midW = 0.5 * (loW + hiW)
            let phaseLag = -atan(midW * tauDIA) - midW * tauDelay
            if phaseLag > -.pi {
                loW = midW
            } else {
                hiW = midW
            }
        }
        let omegaU = 0.5 * (loW + hiW)
        let oscPeriodHrs = (2.0 * .pi) / omegaU

        let omegaC = 0.12
        let phaseAtC = -atan(omegaC * tauDIA) - omegaC * tauDelay
        let phaseMarginDeg = 180.0 + (phaseAtC * 180.0 / .pi)

        return ControlStabilityAudit(
            dampingRatioZeta: dampingRatio,
            poleSummary: poleSummary,
            criticalISFBoundMgdLPerU: critISFBound,
            gainMarginMultiplier: gainMargin,
            phaseMarginDegrees: phaseMarginDeg,
            omegaUltimate: omegaU,
            oscillationPeriodHours: oscPeriodHrs,
            sensorJitterMgdL: sensorJitterMgdL,
            pumpStepImpactMgdL: pumpStepImpactMgdL,
            isOverdampedStable: dampingRatio >= 0.85
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

    private static func rawQuantileBootstrapCI(
        _ sortedValues: [Double],
        quantile: Double,
        iterations: Int,
        seed: Int
    ) -> (Double, Double) {
        var rng = SplitMix64(seed: UInt64(abs(seed) + 1))
        var boots: [Double] = []
        boots.reserveCapacity(iterations)
        let n = sortedValues.count
        for _ in 0..<iterations {
            var sample = [Double]()
            sample.reserveCapacity(n)
            for _ in 0..<n {
                let pick = Int(rng.next() % UInt64(n))
                sample.append(sortedValues[pick])
            }
            sample.sort()
            boots.append(percentile(sample, p: quantile))
        }
        boots.sort()
        let idxLo = max(0, min(iterations - 1, Int(0.025 * Double(iterations))))
        let idxHi = max(0, min(iterations - 1, Int(0.975 * Double(iterations))))
        return (boots[idxLo], boots[idxHi])
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
