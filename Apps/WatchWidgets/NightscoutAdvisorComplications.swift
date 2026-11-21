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

    private var count: Int {
        entry.summary.effectiveAdjustmentsCount
    }

    private var actions: [String] {
        entry.summary.effectiveActions
    }

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                if count == 0 {
                    VStack(spacing: 1) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.green)
                        Text("SYNC")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                    }
                } else {
                    VStack(spacing: 0) {
                        Text("\(count)")
                            .font(.system(.title3, design: .rounded).weight(.bold))
                            .foregroundStyle(.orange)
                        Text(count == 1 ? "ADJ" : "ADJS")
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }

        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: count == 0 ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                        .foregroundStyle(count == 0 ? Color.green : Color.orange)
                    Text(count == 0 ? "Settings In Sync" : "\(count) Update\(count == 1 ? "" : "s")")
                        .font(.caption2.weight(.bold))
                }

                if count == 0 {
                    Text("All 4 schedules match")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("ISF \(entry.summary.headlineISF) • \(entry.summary.headlineTarget)")
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
                Text("✓ Settings In Sync")
            }

        case .accessoryCorner:
            Image(systemName: count == 0 ? "checkmark.circle.fill" : "exclamationmark.arrow.circlepath")
                .font(.title3)
                .foregroundStyle(count == 0 ? Color.green : Color.orange)
                .widgetLabel {
                    if let first = actions.first {
                        Text(first)
                    } else {
                        Text("Settings In Sync")
                    }
                }

        default:
            Text(count == 0 ? "✓" : "\(count)")
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
        .description("Shows ✓ when settings are in sync, or highlights suggested adjustments.")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline,
            .accessoryCorner
        ])
    }
}
