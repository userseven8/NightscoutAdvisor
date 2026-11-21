import NightscoutAdvisorKit
import SwiftUI
import WidgetKit

struct AdvisorComplicationEntry: TimelineEntry {
    let date: Date
    let summary: WatchAdvisorSummary
}

struct AdvisorComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> AdvisorComplicationEntry {
        AdvisorComplicationEntry(date: Date(), summary: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (AdvisorComplicationEntry) -> Void) {
        let sum = AdvisorStore.shared.loadWatchSummary() ?? .placeholder
        completion(AdvisorComplicationEntry(date: Date(), summary: sum))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AdvisorComplicationEntry>) -> Void) {
        let sum = AdvisorStore.shared.loadWatchSummary() ?? .placeholder
        let entry = AdvisorComplicationEntry(date: Date(), summary: sum)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(nextUpdate)))
    }
}

struct AdvisorComplicationEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: AdvisorComplicationEntry

    private var allGood: Bool {
        entry.summary.alignedSections == 4
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: min(100.0, max(0.0, entry.summary.effectiveTIR)), in: 0...100) {
                Text("TIR")
            } currentValueLabel: {
                Text(String(format: "%.0f", entry.summary.effectiveTIR))
                    .font(.system(.body, design: .rounded).weight(.bold))
            }
            .gaugeStyle(.accessoryCircularCapacity)

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("NS Advisor")
                        .font(.caption2.weight(.bold))
                    Spacer()
                    Text(allGood ? "✓ OK" : "Review")
                        .font(.caption2.weight(.semibold))
                }
                Text(String(format: "TIR %.0f%% • Low %.1f%%", entry.summary.effectiveTIR, entry.summary.effectiveTBR))
                    .font(.caption.monospacedDigit().weight(.semibold))
                Text("Target \(entry.summary.headlineTarget)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .accessoryInline:
            Text(String(format: "TIR %.0f%% • %@", entry.summary.effectiveTIR, allGood ? "OK" : "Review"))

        default:
            Text(String(format: "%.0f%%", entry.summary.effectiveTIR))
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
        .description("7-day Time in Range and therapy setting status.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
    }
}
