import ActivityKit
import SwiftUI
import WidgetKit

@available(iOS 17.0, *)
struct MeetingLiveActivityWidget: Widget {
    private let accent = Color(red: 1.0, green: 0.25, blue: 0.25)

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
                // The expanded presentation is intentionally one full-width
                // composition below the TrueDepth hardware. That lets the
                // visual hierarchy match the requested two-row design without
                // the system splitting title/location into a separate row.
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 10) {
                        HStack(spacing: 10) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .fill(accent.opacity(0.18))

                                Image(systemName: "person.3.fill")
                                    .font(.system(size: 17, weight: .bold))
                                    .foregroundStyle(accent)
                            }
                            .frame(width: 40, height: 40)

                            HStack(spacing: 6) {
                                Text(context.attributes.title)
                                    .font(.system(size: 16, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.68)
                                    .layoutPriority(2)

                                Text("·")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.48))

                                Text(context.attributes.roomName)
                                    .font(.system(size: 15, weight: .medium, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.64)
                                    .layoutPriority(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text(context.state.endsAt, style: .timer)
                                .font(.system(size: 21, weight: .bold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(accent)
                                .lineLimit(1)
                                .minimumScaleFactor(0.58)
                                .frame(minWidth: 58, alignment: .trailing)
                        }

                        HStack(spacing: 12) {
                            Text(context.attributes.startsAt, style: .time)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(accent)
                                .lineLimit(1)
                                .frame(width: 52, alignment: .leading)

                            ProgressView(
                                timerInterval: progressInterval(context),
                                countsDown: false
                            )
                            .progressViewStyle(.linear)
                            .labelsHidden()
                            .tint(accent)
                            .scaleEffect(x: 1, y: 1.18, anchor: .center)
                        }
                    }
                    .padding(.top, 2)
                }
            } compactLeading: {
                Image(systemName: "person.3.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(accent)
            } compactTrailing: {
                Text(context.state.endsAt, style: .timer)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
            } minimal: {
                Image(systemName: "person.3.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(accent)
            }
            .keylineTint(accent.opacity(0.9))
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
