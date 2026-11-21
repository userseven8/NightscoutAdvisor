import NightscoutAdvisorKit
import SwiftUI

struct SettingsTabView: View {
    @ObservedObject var viewModel: AdvisorViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("https://your-site.t1pal.com", text: $viewModel.credentials.baseURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Read-Only API Token (Optional)", text: $viewModel.credentials.apiToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("API Secret (Optional)", text: $viewModel.credentials.apiSecretPlaintext)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Nightscout Endpoint")
                } footer: {
                    Text("Stored locally in iOS Keychain and synced securely to your paired Apple Watch.")
                }

                Section("Insulin & Pump Hardware") {
                    Picker("Insulin Curve", selection: $viewModel.config.insulinPreset) {
                        ForEach(InsulinPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    if viewModel.config.insulinPreset == .custom {
                        Stepper(
                            "Peak Activity: \(Int(viewModel.config.customPeakMinutes)) min",
                            value: $viewModel.config.customPeakMinutes,
                            in: 35...110,
                            step: 5
                        )
                        Stepper(
                            "Insulin DIA: \(Int(viewModel.config.customDIAMinutes)) min",
                            value: $viewModel.config.customDIAMinutes,
                            in: 240...480,
                            step: 30
                        )
                    }

                    Picker("Pump Bolus Step", selection: $viewModel.config.pumpQuantum) {
                        ForEach(PumpQuantum.allCases) { q in
                            Text(q.title).tag(q)
                        }
                    }

                    Picker("Closed-Loop Mode", selection: $viewModel.config.dosingMode) {
                        ForEach(ClosedLoopDosingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Picker("Rolling Window", selection: $viewModel.config.rollingDays) {
                        Text("14 Days").tag(14)
                        Text("30 Days (Recommended)").tag(30)
                        Text("45 Days").tag(45)
                    }

                    Picker("Display Units", selection: $viewModel.config.preferredUnitOverride) {
                        Text("Auto (From Nightscout)").tag(BGUnit?.none)
                        Text("mg/dL").tag(BGUnit?.some(.mgdL))
                        Text("mmol/L").tag(BGUnit?.some(.mmolL))
                    }
                }

                if let err = viewModel.errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task { await viewModel.saveSettingsAndRefresh() }
                    } label: {
                        Label("Save & Re-Solve from Nightscout", systemImage: "arrow.triangle.2.circlepath")
                            .font(.headline)
                    }
                    .disabled(viewModel.isLoading)

                    Button {
                        Task { await viewModel.loadDemoTelemetry(units: viewModel.config.preferredUnitOverride ?? .mgdL) }
                    } label: {
                        Label("Load Synthetic 30-Day Demo Data", systemImage: "sparkles")
                    }
                }
            }
            .navigationTitle("Nightscout & Physics")
        }
    }
}
