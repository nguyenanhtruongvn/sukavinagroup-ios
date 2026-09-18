import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 17.0, *)
struct MeetingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingLiveActivityAttributes.self) { context in
            lockScreenView(context)
                .activityBackgroundTint(.black.opacity(0.08))
                .activitySystemActionForegroundColor(.primary)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Họp", systemImage: "person.3.fill")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(remaining(context.state.endsAt))
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 4) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: progress(context))
                        .tint(.green)
                }
            } compactLeading: {
                Image(systemName: "calendar")
            } compactTrailing: {
                Text(remaining(context.state.endsAt))
                    .font(.caption2)
            } minimal: {
                Image(systemName: "calendar")
            }
        }
    }

    private func lockScreenView(_ context: ActivityViewContext<MeetingLiveActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "calendar.badge.clock")
                Text(context.attributes.title)
                    .bold()
                Spacer()
                Text(remaining(context.state.endsAt))
            }
            Text(context.attributes.roomName)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView(value: progress(context))
                .tint(.green)
        }
        .padding()
    }

    private func progress(_ context: ActivityViewContext<MeetingLiveActivityAttributes>) -> Double {
        let total = context.attributes.startsAt.distance(to: context.attributes.endsAt)
        guard total > 0 else { return 0 }
        let done = context.attributes.startsAt.distance(to: Date())
        return min(max(done / total, 0), 1)
    }

    private func remaining(_ date: Date) -> String {
        let minutes = max(0, Int(date.timeIntervalSinceNow / 60))
        return "\(minutes)p"
    }
}
