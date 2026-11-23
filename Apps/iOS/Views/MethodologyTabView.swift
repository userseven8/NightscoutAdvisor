import NightscoutAdvisorKit
import SwiftUI

struct MethodologyTabView: View {
    let report: AdvisorReport

    var body: some View {
        NavigationStack {
            List {
                Section("Open-Source Clinical Disclaimer") {
                    Text("Nightscout Advisor is an open-source educational and retrospective telemetry analysis tool (#WeAreNotWaiting). It is not FDA-cleared or CE-marked medical advice. Always review closed-loop parameter adjustments with your endocrinology care team.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Stage 1 • Coupled Kinetic ISF & Geometric Mean") {
                    MethodologyRow(
                        formula: "I_abs(t₁, t₂) = IOB(t₁) + I_deliv(t₁, t₂) − IOB(t₂)",
                        explanation: "Reconstructs continuous scheduled + truncated temp basals + boluses across historical Nightscout profiles and convolves with Exponential's exponential insulin model (peak \(Int(report.settingsUsed.peakMinutes))m, DIA \(Int(report.settingsUsed.diaMinutes))m). Uses the log-symmetric geometric mean across isolated correction episodes rather than dose-weighted pooling, preventing resistant high-dose nights from biasing ISF downward."
                    )
                }

                Section("Stage 2 • ATTD Closed-Loop Basal Quantile") {
                    MethodologyRow(
                        formula: "τ* = L_TBR / (L_TBR + L_TAR) = 4% / (4% + 25%) = 13.8%",
                        explanation: "In Automatic Bolus / SMB closed-loop systems, actuation is physically one-sided: the controller can add micro-boluses upward on higher-demand nights, but cannot remove subcutaneous insulin infused 55–75 minutes earlier. By the Koenker-Bassett / Newsvendor theorem, the ATTD consensus risk ratio solves every basal block uniformly with zero heuristic guardrails."
                    )
                }

                Section("Stage 3 • Meal Mass-Balance & Gauss-Markov WLS") {
                    MethodologyRow(
                        formula: "w_i = 1 / C_i  ⇒  CR_WLS = Σ C_total,i / Σ I_meal,i",
                        explanation: "Integrates 3.5-hour postprandial kinetic insulin absorption minus piecewise scheduled basal, clusters multi-part meals, sums rescue carbs, evaluates 3.5h settling relative to the active target (profile + Temporary Overrides), and applies proportional shot-noise Weighted Least Squares so giant meals do not exert C² leverage."
                    )
                }

                Section("Stage 4 • Correction Range & Deadband Physics") {
                    MethodologyRow(
                        formula: "T* = argmin_{T ≥ T_min} E[BGRI(T + ε)],  W* = 2 max(σ_CGM, q_pump · ISF)",
                        explanation: "Isolates controller tracking residuals ε(t) = BG(t) − T_active(t), enforces ATTD hypoglycemia tail floors (<4% below 70 mg/dL, <1% below 54 mg/dL), minimizes Kovatchev's symmetric Blood Glucose Risk Index, sizes the deadband from 5m CGM MAD jitter and pump bolus quantum to prevent chatter, and computes 95% CIs via 24-hour calendar day-block bootstrap."
                    )
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #endif
            .navigationTitle("Methodology")
        }
    }
}

private struct MethodologyRow: View {
    let formula: String
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(formula)
                .font(.caption.monospaced().weight(.semibold))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            Text(explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
