import NightscoutAdvisorKit
import SwiftUI

struct RootContentView: View {
    @ObservedObject var viewModel: AdvisorViewModel
    @State private var selectedTab: Int = 0

    var body: some View {
        Group {
            if let report = viewModel.report {
                TabView(selection: $selectedTab) {
                    OverviewTabView(viewModel: viewModel, report: report)
                        .tabItem {
                            Label("Overview", systemImage: "waveform.path.ecg")
                        }
                        .tag(0)

                    SchedulesTabView(report: report)
                        .tabItem {
                            Label("Schedules", systemImage: "slider.horizontal.3")
                        }
                        .tag(1)

                    MethodologyTabView(report: report)
                        .tabItem {
                            Label("Methodology", systemImage: "function")
                        }
                        .tag(2)

                    SettingsTabView(viewModel: viewModel)
                        .tabItem {
                            Label("Nightscout", systemImage: "gearshape.fill")
                        }
                        .tag(3)
                }
            } else {
                OnboardingWelcomeView(viewModel: viewModel)
            }
        }
        .overlay {
            if viewModel.isLoading {
                ZStack {
                    Color.black.opacity(0.25).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                        Text("Solving 4-Stage Therapy Equilibrium…")
                            .font(.subheadline.weight(.semibold))
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

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("First-Principles Closed-Loop Advisor", systemImage: "waveform.path.ecg.rectangle.fill")
                            .font(.headline)
                            .foregroundStyle(.teal)
                        Text("Connect any Nightscout site to run on-device exponential insulin kinetics convolution, ATTD closed-loop basal quantiles, Gauss-Markov WLS meal carb ratios, and Kovatchev BGRI target range optimization. Your data never leaves your iPhone or Apple Watch.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Nightscout Connection") {
                    TextField("Nightscout URL (https://…)", text: $viewModel.credentials.baseURLString)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("Read-Only API Token (Optional)", text: $viewModel.credentials.apiToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    SecureField("API Secret (Optional)", text: $viewModel.credentials.apiSecretPlaintext)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Pump & Insulin Physics") {
                    Picker("Insulin Curve", selection: $viewModel.config.insulinPreset) {
                        ForEach(InsulinPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    Picker("Pump Bolus Step", selection: $viewModel.config.pumpQuantum) {
                        ForEach(PumpQuantum.allCases) { step in
                            Text(step.title).tag(step)
                        }
                    }

                    Picker("Dosing Mode", selection: $viewModel.config.dosingMode) {
                        ForEach(ClosedLoopDosingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
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
                        HStack {
                            Spacer()
                            Label("Connect & Analyze Nightscout", systemImage: "bolt.horizontal.circle.fill")
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
                            Label("Explore Synthetic 30-Day Demo", systemImage: "sparkles")
                                .font(.subheadline.weight(.medium))
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle("Nightscout Advisor")
        }
    }
}
