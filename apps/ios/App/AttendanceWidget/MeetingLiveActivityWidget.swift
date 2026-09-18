import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 17.0, *)
struct MeetingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingLiveActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Circle()
                        .fill(Color.green.opacity(0.75))
                        .frame(width: 8, height: 8)
                    Text(context.attributes.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(context.state.endsAt, style: .timer)
                        .font(.caption.monospacedDigit())
                }
                Text(context.attributes.roomName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ProgressView(value: progress(context))
                    .tint(.green)
            }
            .padding(14)
            .activityBackgroundTint(Color.green.opacity(0.14))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "person.3.fill")
                        .foregroundStyle(.green)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 3) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text(context.attributes.roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.endsAt, style: .timer)
                        .font(.caption.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: progress(context))
                        .tint(.green)
                }
            } compactLeading: {
                Image(systemName: "person.3.fill")
            } compactTrailing: {
                Text(context.state.endsAt, style: .timer)
                    .font(.caption2.monospacedDigit())
            } minimal: {
                Image(systemName: "calendar")
            }
        }
    }

    private func progress(_ context: ActivityViewContext<MeetingLiveActivityAttributes>) -> Double {
        let total = context.attributes.startsAt.distance(to: context.state.endsAt)
        guard total > 0 else { return 1 }
        let elapsed = context.attributes.startsAt.distance(to: Date())
        return min(max(elapsed / total, 0), 1)
    }
}
