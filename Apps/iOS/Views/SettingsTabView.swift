import NightscoutAdvisorKit
import SwiftUI

struct SettingsTabView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: AdvisorViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Nightscout") {
                    TextField("Nightscout URL (https://…)", text: $viewModel.credentials.baseURLString)
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()

                    SecureField("API Token (Optional)", text: $viewModel.credentials.apiToken)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                }

                Section("Therapy Setup") {
                    Picker("Insulin", selection: $viewModel.config.insulinPreset) {
                        ForEach(InsulinPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    if viewModel.config.insulinPreset == .custom {
                        Stepper(
                            "Peak: \(Int(viewModel.config.customPeakMinutes)) min",
                            value: $viewModel.config.customPeakMinutes,
                            in: 35...110,
                            step: 5
                        )
                        Stepper(
                            "DIA: \(Int(viewModel.config.customDIAMinutes)) min",
                            value: $viewModel.config.customDIAMinutes,
                            in: 240...480,
                            step: 30
                        )
                    }

                    Picker("Pump Step", selection: $viewModel.config.pumpQuantum) {
                        ForEach(PumpQuantum.allCases) { q in
                            Text(q.title).tag(q)
                        }
                    }

                    Picker("Loop Mode", selection: $viewModel.config.dosingMode) {
                        ForEach(ClosedLoopDosingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }

                    Picker("History Window", selection: $viewModel.config.rollingDays) {
                        Text("14 Days").tag(14)
                        Text("30 Days").tag(30)
                        Text("45 Days").tag(45)
                    }

                    Picker("Units", selection: $viewModel.config.preferredUnitOverride) {
                        Text("Auto").tag(BGUnit?.none)
                        Text("mg/dL").tag(BGUnit?.some(.mgdL))
                        Text("mmol/L").tag(BGUnit?.some(.mmolL))
                    }
                }

                Section("Documentation & Safety") {
                    if let report = viewModel.report {
                        NavigationLink("How Calculations Work") {
                            MethodologyTabView(report: report)
                        }
                    }
                    NavigationLink("Safety & Open-Source Disclaimer") {
                        DIYSafetyAcknowledgmentView(isReadOnlyReview: true)
                    }
                }

                if let err = viewModel.errorMessage {
                    Section {
                        Label(err, systemImage: "exclamationmark.circle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button {
                        Task {
                            await viewModel.saveSettingsAndRefresh()
                            if viewModel.errorMessage == nil {
                                dismiss()
                            }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if viewModel.isLoading {
                                ProgressView()
                            } else {
                                Text("Save & Refresh")
                                    .font(.headline)
                            }
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isLoading)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #else
            .frame(minWidth: 500, minHeight: 540)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}
