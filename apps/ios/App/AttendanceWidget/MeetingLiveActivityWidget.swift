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
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.red.opacity(0.16))

                        Image(systemName: "person.3.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.red)
                    }
                    .frame(width: 34, height: 34)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.endsAt, style: .timer)
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        .frame(minWidth: 48, alignment: .trailing)
                }

                // Keep descriptive text below the TrueDepth camera area.
                // This gives long Vietnamese room names enough horizontal room
                // and prevents the title, room and countdown from colliding.
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 5) {
                            Text(context.attributes.title)
                                .font(.system(size: 15, weight: .semibold, design: .rounded))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .layoutPriority(2)

                            Text("·")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.48))

                            Text(context.attributes.roomName)
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.white.opacity(0.68))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .layoutPriority(1)

                            Spacer(minLength: 0)
                        }

                        HStack(spacing: 10) {
                            Text(context.attributes.startsAt, style: .time)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(.red)
                                .lineLimit(1)
                                .frame(width: 46, alignment: .leading)

                            ProgressView(
                                timerInterval: progressInterval(context),
                                countsDown: false
                            )
                            .progressViewStyle(.linear)
                            .labelsHidden()
                            .tint(.red)
                            .scaleEffect(x: 1, y: 0.72, anchor: .center)
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
            } compactTrailing: {
                Text(context.state.endsAt, style: .timer)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            } minimal: {
                Image(systemName: "person.3.fill")
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
            .keylineTint(.red.opacity(0.8))
        }
    }

    private func progress(_ context: ActivityViewContext<MeetingLiveActivityAttributes>) -> Double {
        let total = context.attributes.startsAt.distance(to: context.state.endsAt)
        guard total > 0 else { return 1 }
        let elapsed = context.attributes.startsAt.distance(to: Date())
        return min(max(elapsed / total, 0), 1)
    }

    private func progressInterval(
        _ context: ActivityViewContext<MeetingLiveActivityAttributes>
    ) -> ClosedRange<Date> {
        let end = context.state.endsAt
        let start = min(context.attributes.startsAt, end.addingTimeInterval(-1))
        return start...end
    }
}
