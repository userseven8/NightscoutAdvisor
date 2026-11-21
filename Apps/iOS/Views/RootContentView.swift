import NightscoutAdvisorKit
import SwiftUI

struct RootContentView: View {
    @ObservedObject var viewModel: AdvisorViewModel
    @State private var showingSettings = false

    var body: some View {
        Group {
            if let report = viewModel.report {
                OverviewTabView(
                    viewModel: viewModel,
                    report: report,
                    onOpenSettings: { showingSettings = true }
                )
                .sheet(isPresented: $showingSettings) {
                    SettingsTabView(viewModel: viewModel)
                }
            } else {
                OnboardingWelcomeView(viewModel: viewModel)
            }
        }
        .overlay {
            if viewModel.isLoading && viewModel.report == nil {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Syncing Nightscout…")
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(24)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
        }
    }
}

struct OnboardingWelcomeView: View {
    @ObservedObject var viewModel: AdvisorViewModel
    @State private var showAdvanced = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Nightscout URL (https://…)", text: $viewModel.credentials.baseURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("Connect Nightscout")
                } footer: {
                    Text("Analyzes your glucose and insulin history privately on your iPhone.")
                }

                Section {
                    DisclosureGroup("Options (Insulin, Pump & Token)", isExpanded: $showAdvanced) {
                        Picker("Insulin", selection: $viewModel.config.insulinPreset) {
                            ForEach(InsulinPreset.allCases) { preset in
                                Text(preset.title).tag(preset)
                            }
                        }

                        Picker("Pump Step", selection: $viewModel.config.pumpQuantum) {
                            ForEach(PumpQuantum.allCases) { step in
                                Text(step.title).tag(step)
                            }
                        }

                        Picker("Loop Mode", selection: $viewModel.config.dosingMode) {
                            ForEach(ClosedLoopDosingMode.allCases) { mode in
                                Text(mode.title).tag(mode)
                            }
                        }

                        SecureField("API Token (if private site)", text: $viewModel.credentials.apiToken)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
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
                        Task { await viewModel.saveSettingsAndRefresh() }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Connect")
                                .font(.headline)
                            Spacer()
                        }
                    }
                    .disabled(viewModel.credentials.normalizedBaseURL == nil || viewModel.isLoading)

                    Button {
                        Task { await viewModel.loadDemoTelemetry(units: .mgdL) }
                    } label: {
                        HStack {
                            Spacer()
                            Text("Try Demo Data")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("NS Advisor")
        }
    }
}
