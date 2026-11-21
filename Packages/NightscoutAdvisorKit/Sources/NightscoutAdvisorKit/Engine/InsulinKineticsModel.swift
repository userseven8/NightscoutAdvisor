import Foundation

/// Exact Exponential Insulin Kinetics Model (subcutaneous absorption curve).
/// Convolves 5-minute reconstructed pump delivery (scheduled basal + temp basals + boluses)
/// to yield exact plasma-absorbed insulin I_abs(t1, t2) = IOB(t1) + I_deliv(t1, t2) - IOB(t2).
public struct InsulinKineticsTimeline: Sendable {
    public static let binSeconds: TimeInterval = 300.0 // 5-minute grid

    public let gridStartTimestamp: TimeInterval
    public let peakMinutes: Double
    public let diaMinutes: Double
    public let deliveredPerBin: [Double]
    public let cumulativeDelivered: [Double]
    public let iobAtBoundary: [Double]

    /// Exponential exponential IOB fraction remaining tMinutes after bolus.
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
        let term = ((tMin / tau) - 1.0 + a) * exp(-tMin / tau)
        let frac = 1.0 - s * (1.0 - a) * (term + 1.0 - a)
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

        let paddedStart = floor((startTimestamp - diaMinutes * 60.0) / Self.binSeconds) * Self.binSeconds
        let paddedEnd = ceil((endTimestamp + 3600.0) / Self.binSeconds) * Self.binSeconds
        let nBins = max(1, Int((paddedEnd - paddedStart) / Self.binSeconds))
        self.gridStartTimestamp = paddedStart

        var deliv = [Double](repeating: 0.0, count: nBins)

        // 1. Reconstruct continuous basal across 5-minute bins (non-overlapping truncated temp basals + scheduled basal)
        var cleanedTemps: [TempBasalEvent] = []
        let sortedTemps = tempBasals.sorted { $0.startTimestamp < $1.startTimestamp }
        for tb in sortedTemps {
            guard tb.endTimestamp > tb.startTimestamp else { continue }
            if let last = cleanedTemps.last, last.endTimestamp > tb.startTimestamp {
                let truncatedEnd = tb.startTimestamp
                cleanedTemps.removeLast()
                if truncatedEnd > last.startTimestamp {
                    cleanedTemps.append(
                        TempBasalEvent(
                            startTimestamp: last.startTimestamp,
                            endTimestamp: truncatedEnd,
                            rateUnitsPerHour: last.rateUnitsPerHour
                        )
                    )
                }
            }
            cleanedTemps.append(tb)
        }

        var tbCursor = 0
        let nTB = cleanedTemps.count

        for b in 0..<nBins {
            let bStart = paddedStart + Double(b) * Self.binSeconds
            let bEnd = bStart + Self.binSeconds
            while tbCursor < nTB && cleanedTemps[tbCursor].endTimestamp <= bStart {
                tbCursor += 1
            }

            var coveredSeconds = 0.0
            var tempUnits = 0.0
            var j = tbCursor
            while j < nTB && cleanedTemps[j].startTimestamp < bEnd {
                let ovStart = max(bStart, cleanedTemps[j].startTimestamp)
                let ovEnd = min(bEnd, cleanedTemps[j].endTimestamp)
                if ovEnd > ovStart {
                    let dur = ovEnd - ovStart
                    coveredSeconds += dur
                    tempUnits += cleanedTemps[j].rateUnitsPerHour * (dur / 3600.0)
                }
                j += 1
            }

            let uncoveredSeconds = max(0.0, Self.binSeconds - coveredSeconds)
            var schedUnits = 0.0
            if uncoveredSeconds > 0.0 {
                schedUnits = scheduledBasalRateAt(bStart + 0.5 * Self.binSeconds) * (uncoveredSeconds / 3600.0)
            }
            deliv[b] = tempUnits + schedUnits
        }

        // 2. Add discrete manual & automatic boluses
        for bol in boluses where bol.units > 0 {
            let idx = Int((bol.timestamp - paddedStart) / Self.binSeconds)
            if idx >= 0 && idx < nBins {
                deliv[idx] += bol.units
            }
        }

        self.deliveredPerBin = deliv

        // 3. Cumulative delivered array at bin boundaries [0...nBins]
        var cum = [Double](repeating: 0.0, count: nBins + 1)
        for i in 0..<nBins {
            cum[i + 1] = cum[i] + deliv[i]
        }
        self.cumulativeDelivered = cum

        // 4. Convolve with Exponential exponential IOB kernel at every boundary
        let kernelBins = max(1, Int(ceil((diaMinutes * 60.0) / Self.binSeconds)))
        let kernel: [Double] = (0..<kernelBins).map { k in
            let ageMinutes = (Double(k) + 0.5) * (Self.binSeconds / 60.0)
            return Self.iobFraction(minutes: ageMinutes, peakMinutes: peakMinutes, diaMinutes: diaMinutes)
        }

        var iob = [Double](repeating: 0.0, count: nBins + 1)
        for i in 1...nBins {
            let maxK = min(kernelBins, i)
            var acc = 0.0
            for k in 0..<maxK {
                acc += deliv[i - 1 - k] * kernel[k]
            }
            iob[i] = acc
        }
        self.iobAtBoundary = iob
    }

    public func iob(at timestamp: TimeInterval) -> Double {
        let pos = (timestamp - gridStartTimestamp) / Self.binSeconds
        if pos <= 0 { return iobAtBoundary.first ?? 0.0 }
        let maxIdx = iobAtBoundary.count - 1
        if pos >= Double(maxIdx) { return iobAtBoundary.last ?? 0.0 }
        let idx = Int(pos)
        let frac = pos - Double(idx)
        return iobAtBoundary[idx] * (1.0 - frac) + iobAtBoundary[idx + 1] * frac
    }

    public func cumulativeDelivered(at timestamp: TimeInterval) -> Double {
        let pos = (timestamp - gridStartTimestamp) / Self.binSeconds
        if pos <= 0 { return 0.0 }
        let maxIdx = cumulativeDelivered.count - 1
        if pos >= Double(maxIdx) { return cumulativeDelivered.last ?? 0.0 }
        let idx = Int(pos)
        let frac = pos - Double(idx)
        return cumulativeDelivered[idx] * (1.0 - frac) + cumulativeDelivered[idx + 1] * frac
    }

    public func deliveredInsulin(from t1: TimeInterval, to t2: TimeInterval) -> Double {
        guard t2 > t1 else { return 0.0 }
        return cumulativeDelivered(at: t2) - cumulativeDelivered(at: t1)
    }

    /// Exact conservation of mass: I_abs(t1, t2) = IOB(t1) + I_deliv(t1, t2) - IOB(t2).
    public func absorbedInsulin(from t1: TimeInterval, to t2: TimeInterval) -> Double {
        guard t2 > t1 else { return 0.0 }
        return iob(at: t1) + deliveredInsulin(from: t1, to: t2) - iob(at: t2)
    }
}
