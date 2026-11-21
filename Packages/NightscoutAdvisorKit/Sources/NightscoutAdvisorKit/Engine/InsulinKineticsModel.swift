import Foundation

/// Exact Exponential Insulin Kinetics Model (subcutaneous absorption curve).
/// Convolves 5-minute reconstructed pump delivery (scheduled basal + temp basals + boluses)
/// using the exact discrete step kernel PK_KERNEL[m] = iobFraction(m * 5) - iobFraction((m + 1) * 5).
public struct InsulinKineticsTimeline: Sendable {
    public static let binSeconds: TimeInterval = 300.0 // 5-minute grid

    public let gridStartTimestamp: TimeInterval
    public let peakMinutes: Double
    public let diaMinutes: Double
    public let deliveredPerBin: [Double]
    public let cumulativeDelivered: [Double]
    public let cumulativeAbsorbed: [Double]

    /// Exact LoopKit ExponentialInsulinModel IOB fraction remaining tMin minutes after bolus.
    public static func iobFraction(minutes tMin: Double, peakMinutes tp: Double, diaMinutes td: Double) -> Double {
        if tMin <= 0.0 { return 1.0 }
        if tMin >= td { return 0.0 }
        let ratio = tp / td
        let denom = 1.0 - 2.0 * ratio
        guard abs(denom) > 1e-6 else {
            return max(0.0, 1.0 - tMin / td)
        }
        let tau = tp * (1.0 - ratio) / denom
        let a = 2.0 * tau / td
        let expNegTdTau = exp(-td / tau)
        let s = 1.0 / (1.0 - a + (1.0 + a) * expNegTdTau)
        let poly = (tMin * tMin) / (tau * td * (1.0 - a)) - (tMin / tau) - 1.0
        let frac = 1.0 - s * (1.0 - a) * (poly * exp(-tMin / tau) + 1.0)
        return min(1.0, max(0.0, frac))
    }

    public init(
        startTimestamp: TimeInterval,
        endTimestamp: TimeInterval,
        peakMinutes: Double,
        diaMinutes: Double,
        boluses: [BolusEvent],
        tempBasals: [TempBasalEvent],
        scheduledBasalRateAt: (TimeInterval) -> Double
    ) {
        self.peakMinutes = peakMinutes
        self.diaMinutes = diaMinutes

        let gridT0 = floor(startTimestamp / Self.binSeconds) * Self.binSeconds - diaMinutes * 60.0
        let gridT1 = floor(endTimestamp / Self.binSeconds) * Self.binSeconds + Self.binSeconds
        let nBins = max(1, Int((gridT1 - gridT0) / Self.binSeconds))
        self.gridStartTimestamp = gridT0

        // Truncate superseded overlapping temp basals identically to Python reference
        let sortedRaw = tempBasals.sorted { $0.startTimestamp < $1.startTimestamp }
        var cleanedTemps: [TempBasalEvent] = []
        cleanedTemps.reserveCapacity(sortedRaw.count)
        for i in 0..<sortedRaw.count {
            let s = sortedRaw[i].startTimestamp
            var e = sortedRaw[i].endTimestamp
            let r = sortedRaw[i].rateUnitsPerHour
            if i + 1 < sortedRaw.count && sortedRaw[i + 1].startTimestamp < e {
                e = sortedRaw[i + 1].startTimestamp
            }
            if e > s {
                cleanedTemps.append(TempBasalEvent(startTimestamp: s, endTimestamp: e, rateUnitsPerHour: r))
            }
        }
        let tbStarts = cleanedTemps.map(\.startTimestamp)

        func pumpBasalRate(at ts: TimeInterval) -> Double {
            // bisect_right(tbStarts, ts) - 1
            var lo = 0
            var hi = tbStarts.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if tbStarts[mid] <= ts {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            let idx = lo - 1
            if idx >= 0 && cleanedTemps[idx].startTimestamp <= ts && ts < cleanedTemps[idx].endTimestamp {
                return cleanedTemps[idx].rateUnitsPerHour
            }
            return scheduledBasalRateAt(ts)
        }

        var deliv = [Double](repeating: 0.0, count: nBins)
        for k in 0..<nBins {
            let midTS = gridT0 + Double(k) * Self.binSeconds + 0.5 * Self.binSeconds
            deliv[k] = pumpBasalRate(at: midTS) * (Self.binSeconds / 3600.0)
        }

        for bol in boluses where bol.units > 0 {
            let kIdx = Int(floor((bol.timestamp - gridT0) / Self.binSeconds))
            if kIdx >= 0 && kIdx < nBins {
                deliv[kIdx] += bol.units
            }
        }
        self.deliveredPerBin = deliv

        var cumDeliv = [Double](repeating: 0.0, count: nBins + 1)
        for k in 0..<nBins {
            cumDeliv[k + 1] = cumDeliv[k] + deliv[k]
        }
        self.cumulativeDelivered = cumDeliv

        let pkSteps = max(1, Int(round(diaMinutes / 5.0)))
        let pkKernel: [Double] = (0..<pkSteps).map { m in
            Self.iobFraction(minutes: Double(m) * 5.0, peakMinutes: peakMinutes, diaMinutes: diaMinutes)
            - Self.iobFraction(minutes: Double(m + 1) * 5.0, peakMinutes: peakMinutes, diaMinutes: diaMinutes)
        }

        var cumAbs = [Double](repeating: 0.0, count: nBins + 1)
        for k in 0..<nBins {
            let limit = min(k + 1, pkSteps)
            var absorbedInBin = 0.0
            for m in 0..<limit {
                absorbedInBin += deliv[k - m] * pkKernel[m]
            }
            cumAbs[k + 1] = cumAbs[k] + absorbedInBin
        }
        self.cumulativeAbsorbed = cumAbs
    }

    public func deliveredInsulin(from t1: TimeInterval, to t2: TimeInterval) -> Double {
        guard t2 > t1 else { return 0.0 }
        let nGrid = cumulativeDelivered.count - 1
        let k1 = max(0, min(nGrid, Int(((t1 - gridStartTimestamp) / Self.binSeconds).rounded())))
        let k2 = max(0, min(nGrid, Int(((t2 - gridStartTimestamp) / Self.binSeconds).rounded())))
        return cumulativeDelivered[k2] - cumulativeDelivered[k1]
    }

    public func absorbedInsulin(from t1: TimeInterval, to t2: TimeInterval) -> Double {
        guard t2 > t1 else { return 0.0 }
        let nGrid = cumulativeAbsorbed.count - 1
        let k1 = max(0, min(nGrid, Int(((t1 - gridStartTimestamp) / Self.binSeconds).rounded())))
        let k2 = max(0, min(nGrid, Int(((t2 - gridStartTimestamp) / Self.binSeconds).rounded())))
        return cumulativeAbsorbed[k2] - cumulativeAbsorbed[k1]
    }
}
