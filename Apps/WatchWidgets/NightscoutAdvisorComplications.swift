import NightscoutAdvisorKit
import SwiftUI
import WidgetKit

struct AdvisorComplicationEntry: TimelineEntry {
    let date: Date
    let summary: WatchAdvisorSummary?
}

struct AdvisorComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> AdvisorComplicationEntry {
        AdvisorComplicationEntry(date: Date(), summary: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (AdvisorComplicationEntry) -> Void) {
        if context.isPreview {
            completion(AdvisorComplicationEntry(date: Date(), summary: .placeholder))
        } else {
            completion(AdvisorComplicationEntry(date: Date(), summary: AdvisorStore.shared.loadWatchSummary()))
        }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AdvisorComplicationEntry>) -> Void) {
        let store = AdvisorStore.shared
        if let cached = store.loadWatchSummary(),
           Date().timeIntervalSince(cached.generatedAt) < 3600 {
            let next = Date().addingTimeInterval(1800)
            completion(Timeline(entries: [AdvisorComplicationEntry(date: Date(), summary: cached)], policy: .after(next)))
            return
        }

        let creds = store.loadCredentials()
        guard creds.normalizedBaseURL != nil else {
            let existing = store.loadWatchSummary()
            let next = Date().addingTimeInterval(600)
            completion(Timeline(entries: [AdvisorComplicationEntry(date: Date(), summary: existing)], policy: .after(next)))
            return
        }

        let cfg = store.loadConfig()
        Task {
            do {
                let bundle = try await NightscoutClient().fetchTelemetry(credentials: creds, rollingDays: cfg.rollingDays)
                let report = try TherapyAdvisorSolver.solve(bundle: bundle, config: cfg)
                let fresh = report.makeWatchSummary()
                store.saveWatchSummary(fresh)
                let next = Date().addingTimeInterval(1800)
                completion(Timeline(entries: [AdvisorComplicationEntry(date: Date(), summary: fresh)], policy: .after(next)))
            } catch {
                let fallback = store.loadWatchSummary()
                let next = Date().addingTimeInterval(900)
                completion(Timeline(entries: [AdvisorComplicationEntry(date: Date(), summary: fallback)], policy: .after(next)))
            }
        }
    }
}

struct AdvisorComplicationEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: AdvisorComplicationEntry

    var body: some View {
        if let summary = entry.summary {
            configuredView(summary: summary)
        } else {
            unconfiguredView
        }
    }

    @ViewBuilder
    private func configuredView(summary: WatchAdvisorSummary) -> some View {
        let count = summary.effectiveAdjustmentsCount
        let actions = summary.effectiveActions

        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if count == 0 {
                    Image(systemName: "checkmark")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.green)
                } else {
                    Text("\(count)")
                        .font(.system(.title2, design: .rounded).weight(.bold))
                        .foregroundStyle(Color.orange)
                }
            }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: count == 0 ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(count == 0 ? Color.green : Color.orange)
                    Text(count == 0 ? "All Good" : "\(count) Update\(count == 1 ? "" : "s")")
                        .font(.caption2.weight(.bold))
                }

                if count == 0 {
                    Text("ISF \(summary.headlineISF) • \(summary.headlineTarget)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    if let first = actions.first {
                        Text(first)
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .lineLimit(1)
                    }
                    if actions.count >= 2 {
                        Text(actions[1])
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .accessoryInline:
            if let first = actions.first {
                Text("NS: \(first)")
            } else {
                Text("✓ NS Advisor")
            }

        case .accessoryCorner:
            if count == 0 {
                Image(systemName: "checkmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.green)
            } else {
                Text("\(count)")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(Color.orange)
                    .widgetLabel {
                        if let first = actions.first {
                            Text(first)
                        }
                    }
            }

        default:
            Text(count == 0 ? "✓" : "\(count)")
        }
    }

    @ViewBuilder
    private var unconfiguredView: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "ellipsis")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("NS Advisor")
                    .font(.caption2.weight(.bold))
                Text("Tap to open & sync")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Text("NS Advisor: —")
        case .accessoryCorner:
            Image(systemName: "ellipsis")
                .foregroundStyle(.secondary)
        default:
            Text("—")
        }
    }
}

@main
struct NightscoutAdvisorComplicationsBundle: Widget {
    let kind: String = "NightscoutAdvisorComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AdvisorComplicationProvider()) { entry in
            AdvisorComplicationEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("NS Advisor")
        .description("Shows a clean ✓ when settings match, or the count of suggested adjustments.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
    }
}
