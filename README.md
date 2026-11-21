# Nightscout Advisor (iOS + watchOS + Complications)

**First-Principles Closed-Loop Telemetry & Therapy Schedule Advisor for Nightscout.**

Nightscout Advisor connects directly from your iPhone and Apple Watch to any **Nightscout** instance (`mg/dL` or `mmol/L`)—compatible across automated insulin delivery systems (`Trio`, `AndroidAPS`, `iAPS`, `OpenAPS`, `Loop`, and other Nightscout-connected controllers)—and runs a coupled 4-stage insulin-kinetics & stochastic control solver **100% on-device** with zero cloud intermediaries, zero data collection, and zero heuristic block hacks.

---

## Why Nightscout Advisor?

Legacy parameter tuners (such as OpenAPS Autotune) were designed for older temp-basal-only controllers, break down under modern **Automatic Bolus / SMB** dosing, ignore temporary target overrides, and require server-side CLI setup.

Nightscout Advisor solves all four closed-loop therapy schedules directly from your Nightscout telemetry:

1. **Stage 1 — Coupled Insulin-Kinetics ISF & Log-Symmetric Geometric Estimator**
   * Reconstructs continuous historical scheduled basals, truncated non-overlapping temp basals, and boluses across up to 200 historical Nightscout profile versions.
   * Convolves delivery with exact exponential subcutaneous insulin kinetics (`Lyumjev / Fiasp` $t_{\text{peak}}=55\text{m}$ or `Humalog / Novolog / Apidra` $t_{\text{peak}}=65\text{–}75\text{m}$):
     $$I_{\text{abs}}(t_1, t_2) = \text{IOB}(t_1) + I_{\text{deliv}}(t_1, t_2) - \text{IOB}(t_2)$$
   * Computes the log-space Maximum Likelihood Estimator (geometric mean) across carb-free correction episodes rather than dose-weighted pooling ($\sum \Delta\text{BG} / \sum I$), preventing insulin-resistant high-dose nights from biasing ISF dangerously low.

2. **Stage 2 — ATTD Closed-Loop Basal Quantile ($\tau^* = 4/29 \approx 13.8\%$)**
   * In Automatic Bolus / SMB controllers, actuation is physically one-sided: the controller can add micro-boluses upward on higher-demand nights, but cannot extract subcutaneous insulin infused an hour earlier.
   * Applies the Koenker–Bassett / Newsvendor quantile derived directly from the ATTD consensus limits ($4\%$ allowable TBR vs. $25\%$ allowable TAR) uniformly across your Nightscout basal schedule.

3. **Stage 3 — Postprandial Mass-Balance & Gauss–Markov WLS ($w_i = 1/C_i$)**
   * Clusters multi-part meals, accounts for rescue carbs, integrates piecewise scheduled basal across schedule boundaries, evaluates 3.5-hour postprandial settling relative to active targets (`profile.json` + `Temporary Override` / `Temporary Target` events), and applies proportional shot-noise Weighted Least Squares ($\widehat{\text{CR}} = \sum C_i / \sum I_i$) with Student-$t$ 95% CIs.

4. **Stage 4 — Optimal Correction Range (ATTD Safety Floor + Kovatchev BGRI + Deadband Physics)**
   * Isolates empirical closed-loop tracking error $\varepsilon(t) = \text{BG}(t) - T_{\text{active}}(t)$, enforces ATTD hypoglycemia tail floors ($\le 4\%$ `<70 mg/dL`, $\le 1\%$ `<54 mg/dL`), minimizes Kovatchev's symmetric Blood Glucose Risk Index, sizes deadband width from empirical 5-minute CGM MAD jitter and pump bolus quantum (`0.05 U` / `0.025 U` / `0.01 U`), and computes 95% CIs via **calendar day-block bootstrap**.

---

## Features

* **Universal Nightscout Auto-Detection:** Automatically reads your active schedule blocks, `mg/dL` or `mmol/L` units, timezone, historical profile changes, and temporary target overrides from `/api/v1/profile.json`, `/api/v1/entries/sgv.json`, and `/api/v1/treatments.json`.
* **Password-Protected Nightscout Sites:** Supports public guest URLs, Read-Only API Tokens (`?token=`), and `api-secret` SHA-1 authentication stored locally in iOS Keychain.
* **Native Swift Charts AGP & Stability Audit:** 24-hour Ambulatory Glucose Profile (`P10–P90`, `IQR`, `Median`), rolling `24h / 7d / 30d` TIR, TBR, CV, GMI, and linearized closed-loop damping ratio ($\zeta$) & gain/phase margins.
* **watchOS Companion (`NS Advisor`) & Watch Face Complications:** Syncs automatically from your paired iPhone via `WatchConnectivity` (or refreshes standalone over Watch Wi-Fi/Cellular), including `AccessoryCircular`, `AccessoryRectangular`, `AccessoryInline`, and `AccessoryCorner` WidgetKit complications.
* **Zero-Data Demo Mode:** Built-in synthetic 30-day closed-loop generator so anyone can explore the app before connecting Nightscout.

---

## Installation Option A: GitHub Browser Build $\to$ TestFlight

If you already build open-source Nightscout / DIY AID apps via GitHub Actions, you can reuse the standard 6 GitHub Secrets and `Match-Certificates` repository:

1. **Fork** this repository on GitHub.
2. Go to your fork's **Settings $\to$ Secrets and variables $\to$ Actions** and add:
   * `TEAM_ID` — Your 10-character Apple Developer Team ID
   * `FASTLANE_KEY_ID` — App Store Connect API Key ID
   * `FASTLANE_ISSUER_ID` — App Store Connect Issuer ID
   * `FASTLANE_KEY` — Contents of your `.p8` App Store Connect API key
   * `MATCH_PASSWORD` — Passphrase for your `Match-Certificates` private repo
   * `GH_PAT` — GitHub Personal Access Token with `repo` + `workflow` scope
3. Click the **Actions** tab $\to$ **Build & Upload to TestFlight (DIY Browser Build)** $\to$ **Run workflow**.
4. Open **TestFlight** on your iPhone and Apple Watch to install **Nightscout Advisor**!

---

## Installation Option B: Build Directly with Xcode

1. Clone this repository:
   ```bash
   git clone https://github.com/<your-username>/NightscoutAdvisor.git
   cd NightscoutAdvisor
   ```
2. Create an untracked local signing config at `Config/NightscoutAdvisorConfigOverride.xcconfig`:
   ```ini
   DEVELOPMENT_TEAM = YOUR_TEAM_ID
   BUNDLE_ID_PREFIX = com.yourname.nightscoutadvisor
   ```
3. Open `NightscoutAdvisor.xcodeproj` in **Xcode 16+**, select your iPhone or Simulator, and press **Run (`⌘R`)**.

---

## Running Unit Tests

The core math & Nightscout telemetry engine lives in a standalone, zero-dependency Swift Package (`Packages/NightscoutAdvisorKit`):

```bash
cd Packages/NightscoutAdvisorKit
swift test
```

---

## Clinical Disclaimer (`#WeAreNotWaiting`)

Nightscout Advisor is an open-source retrospective telemetry and educational research tool. It is **not** FDA-cleared or CE-marked medical device software and does **not** automatically modify pump settings or deliver insulin. Always review therapy profile adjustments with a qualified endocrinology clinician.
