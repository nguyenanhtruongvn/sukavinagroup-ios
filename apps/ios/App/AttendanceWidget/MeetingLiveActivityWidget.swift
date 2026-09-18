import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 17.0, *)
struct MeetingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MeetingLiveActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)

                        Text(context.attributes.roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }

                    Spacer(minLength: 4)

                    Text(context.state.endsAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                ProgressView(value: progress(context))
                    .tint(.green)
            }
            .padding(14)
            .activityBackgroundTint(Color.green.opacity(0.14))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "video.fill")
                        .foregroundStyle(.green)
                }

                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.attributes.title)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)

                        Text(context.attributes.roomName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.endsAt, style: .timer)
                        .font(.caption.monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }

                DynamicIslandExpandedRegion(.bottom) {
                    ProgressView(value: progress(context))
                        .tint(.green)
                }
            } compactLeading: {
                Image(systemName: "video.fill")
                    .font(.caption2)
            } compactTrailing: {
                Text(context.state.endsAt, style: .timer)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
            } minimal: {
                Image(systemName: "video.fill")
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
