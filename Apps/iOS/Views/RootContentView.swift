import NightscoutAdvisorKit
import SwiftUI

struct RootContentView: View {
    @ObservedObject var viewModel: AdvisorViewModel
    @State private var showingSettings = false

    var body: some View {
        Group {
            if !viewModel.hasAcceptedDIYDisclaimer {
                DIYSafetyAcknowledgmentView {
                    viewModel.acceptDIYDisclaimer()
                }
            } else if let report = viewModel.report {
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
            if viewModel.isLoading && viewModel.report == nil && viewModel.hasAcceptedDIYDisclaimer {
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

struct DIYSafetyAcknowledgmentView: View {
    var isReadOnlyReview: Bool = false
    var onAccept: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var confirmedUnderstanding = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Experimental Open-Source Code", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(.orange)
                        Text("Nightscout Advisor is an open-source #WeAreNotWaiting community research project. It has NOT been reviewed, cleared, or approved by the FDA, EMA, or any regulatory authority, and is provided \"AS IS\" without warranty of any kind.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                Section("Important Safety Boundaries") {
                    DIYNoticeRow(
                        icon: "chart.xyaxis.line",
                        title: "Retrospective Statistics Only — Not Medical Advice",
                        detail: "All outputs are mathematical summaries of historical Nightscout logs. They cannot detect sensor compression lows, infusion site issues, illness, exercise, hormones, or unlogged meals."
                    )
                    DIYNoticeRow(
                        icon: "bolt.heart.fill",
                        title: "Insulin Parameter Changes Carry Severe Risk",
                        detail: "Incorrect basal rates, insulin sensitivity factors (ISF), carb ratios, or target ranges can cause severe hypoglycemia, diabetic ketoacidosis (DKA), coma, or death."
                    )
                    DIYNoticeRow(
                        icon: "stethoscope",
                        title: "Independent Clinician Review Required",
                        detail: "Never change insulin pump or closed-loop settings based solely on this software. Always evaluate retrospective data together with a qualified endocrinologist or diabetes care clinician."
                    )
                    DIYNoticeRow(
                        icon: "person.badge.shield.checkmark.fill",
                        title: "DIY Self-Build & Full User Responsibility",
                        detail: "Do not distribute compiled builds to others. By building and running this source code, you assume sole responsibility for its operation and verify all clinical decisions independently."
                    )
                }

                if !isReadOnlyReview {
                    Section {
                        Toggle(isOn: $confirmedUnderstanding) {
                            Text("I understand this is unvalidated open-source research software, not medical advice, and I accept full responsibility.")
                                .font(.footnote.weight(.medium))
                        }

                        Button {
                            onAccept?()
                        } label: {
                            HStack {
                                Spacer()
                                Text("I Understand & Continue")
                                    .font(.headline)
                                Spacer()
                            }
                        }
                        .disabled(!confirmedUnderstanding)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Safety & Disclaimer")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                if isReadOnlyReview {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
    }
}

private struct DIYNoticeRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
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
                        #if os(iOS)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                } header: {
                    Text("Connect Nightscout")
                } footer: {
                    Text("Reads historical glucose and treatment telemetry privately on your device (read-only).")
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
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
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
            .formStyle(.grouped)
            .navigationTitle("NS Advisor")
        }
    }
}
