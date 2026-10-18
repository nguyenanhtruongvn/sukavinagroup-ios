import UIKit
import SwiftUI
import Combine
import Security
import UserNotifications
import Network
import LocalAuthentication
import WidgetKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import WebKit
import UniformTypeIdentifiers

struct MeetingTimelineBookingStyle {
    let fill: Color
    let border: Color
    let foreground: Color
    let meta: Color
    let line: Color
}

enum MeetingScheduleLabelLane: Equatable {
    case center, left, right
}

enum MeetingScheduleLabelMetrics {
    static let height: CGFloat = 36
    static let spacing: CGFloat = 8
    static let verticalInset: CGFloat = 4
    static let horizontalInset: CGFloat = 16
    static let laneGap: CGFloat = 22
    static let cornerRadius: CGFloat = 5
}

struct TimelineBookingItem: Identifiable {
    let sourceIndex: Int
    let booking: MeetingBooking

    var id: String {
        if booking.id.isEmpty {
            return "private|\(sourceIndex)|\(booking.roomId)|\(booking.startsAt)|\(booking.endsAt)"
        }
        return "booking|\(booking.id)|\(booking.startsAt)|\(booking.endsAt)"
    }
}

struct MeetingScheduleLabelCandidate {
    let item: TimelineBookingItem
    let startY: CGFloat
    let endY: CGFloat
    let idealTop: CGFloat
}

struct MeetingScheduleLabelPlacement: Identifiable {
    let id: String
    let booking: MeetingBooking
    let style: MeetingTimelineBookingStyle
    let lane: MeetingScheduleLabelLane
    let startY: CGFloat
    let endY: CGFloat
    var labelTop: CGFloat
}

struct MeetingTimeline: View {
    let bookings: [MeetingBooking]
    let date: Date
    let onSelect: (MeetingBooking) -> Void

    private let firstHour = 6
    private let lastHour = 23
    private let hourHeight: CGFloat = 72
    /// ScrollViewReader id of the current-minute anchor (today only).
    static let nowAnchorID = "meeting-timeline-now"

    private var timelineHeight: CGFloat {
        hourHeight * CGFloat(lastHour - firstHour + 1)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 0) {
                ForEach(Array(firstHour...lastHour), id: \.self) { hour in
                    Text(String(format: "%02d:00", hour))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 56, height: hourHeight, alignment: .topTrailing)
                        .padding(.trailing, 8)
                        .id(hour)
                }
            }

            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(Array(firstHour...lastHour), id: \.self) { _ in
                        Rectangle()
                            .fill(Color.secondary.opacity(0.035))
                            .frame(height: hourHeight)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.12))
                                    .frame(height: 1)
                            }
                    }
                }

                // Where the current minute is laid out (the red marker below
                // is only offset, which scrolling cannot target): the sheet
                // centres this anchor when it opens.
                if let nowOffset = MeetingScheduleLayout.currentOffset(
                    day: date, now: Date(), firstHour: firstHour, lastHour: lastHour, hourHeight: hourHeight
                ) {
                    // The anchor is its own 2 pt view below a spacer, so the
                    // identified frame is exactly the red line's. With the
                    // id on a padded view (even before the padding) scrollTo
                    // centred the padded span: half way to the line, which
                    // opened the schedule near 07:00 at 18:54 (TestFlight 133).
                    VStack(spacing: 0) {
                        Color.clear.frame(width: 1, height: nowOffset)
                        Color.clear
                            .frame(width: 1, height: 2)
                            .id(Self.nowAnchorID)
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }

                MeetingScheduleLabelsOverlay(
                    placements: labelPlacements,
                    onSelect: onSelect
                )
                .frame(maxWidth: .infinity)
                .frame(height: timelineHeight)
                .zIndex(2)

                // The marker and its time label advance every minute instead
                // of only when the timeline happens to redraw.
                TimelineView(.everyMinute) { clock in
                    if let currentOffset = MeetingScheduleLayout.currentOffset(
                        day: date, now: clock.date, firstHour: firstHour, lastHour: lastHour, hourHeight: hourHeight
                    ) {
                        ZStack(alignment: .topLeading) {
                            Rectangle()
                                .fill(.red)
                                .frame(height: 2)
                                .offset(y: currentOffset)

                            Text(MeetingPresentation.clock.string(from: clock.date))
                                .font(.caption2.bold().monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 4)
                                .background(.red)
                                .offset(y: currentOffset - 13)
                        }
                    }
                }
                .allowsHitTesting(false)
                .zIndex(4)
            }
            .frame(
                maxWidth: .infinity,
                minHeight: timelineHeight,
                alignment: .topLeading
            )
            .clipped()
        }
    }

    private var labelPlacements: [MeetingScheduleLabelPlacement] {
        MeetingScheduleLayout.slots(
            bookings: bookings,
            firstHour: firstHour,
            lastHour: lastHour,
            hourHeight: hourHeight
        ).map { slot in
            MeetingScheduleLabelPlacement(
                id: slot.item.id,
                booking: slot.item.booking,
                style: bookingStyle(for: slot.item.booking),
                lane: slot.lane,
                startY: slot.startY,
                endY: slot.endY,
                labelTop: slot.labelTop
            )
        }
    }

    private func bookingStyle(for booking: MeetingBooking) -> MeetingTimelineBookingStyle {
        let colors = MeetingTimelinePalette.colors(for: booking)
        return MeetingTimelineBookingStyle(
            fill: Color(uiColor: colors.fill),
            border: Color(uiColor: colors.border),
            foreground: Color(uiColor: colors.foreground),
            meta: Color(uiColor: colors.meta),
            line: Color(uiColor: colors.line)
        )
    }
}

/// A booking's colours on the day timeline: organiser green, invitee blue,
/// others a quieter grey. Each has a dark-appearance variant (the light
/// pastels glared on the dark schedule). Shared by the SwiftUI timeline and
/// the iOS 17 UIKit one.
enum MeetingTimelinePalette {
    struct Colors {
        let fill: UIColor
        let border: UIColor
        let foreground: UIColor
        let meta: UIColor
        let line: UIColor
    }

    static func colors(for booking: MeetingBooking) -> Colors {
        if booking.isOwner == true { return organiser }
        if booking.isMine == true { return invitee }
        return other
    }

    private static let organiser = Colors(
        fill: adaptive((220, 239, 226), (31, 56, 40)),
        border: adaptive((143, 198, 160), (64, 112, 80)),
        foreground: adaptive((46, 106, 67), (163, 214, 178)),
        meta: adaptive((92, 127, 104), (125, 170, 140)),
        line: adaptive((166, 207, 178), (72, 122, 88))
    )
    private static let invitee = Colors(
        fill: adaptive((220, 233, 250), (28, 44, 70)),
        border: adaptive((142, 180, 232), (66, 100, 150)),
        foreground: adaptive((49, 92, 145), (163, 195, 238)),
        meta: adaptive((96, 126, 167), (125, 155, 195)),
        line: adaptive((168, 195, 232), (74, 108, 160))
    )
    private static let other = Colors(
        fill: adaptive((229, 231, 235), (44, 46, 51)),
        border: adaptive((184, 190, 199), (82, 87, 95)),
        foreground: adaptive((89, 97, 109), (196, 200, 207)),
        meta: adaptive((119, 127, 137), (148, 153, 161)),
        line: adaptive((195, 200, 207), (92, 97, 105))
    )

    private static func adaptive(_ light: (CGFloat, CGFloat, CGFloat), _ dark: (CGFloat, CGFloat, CGFloat)) -> UIColor {
        UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0 / 255, green: value.1 / 255, blue: value.2 / 255, alpha: 1)
        }
    }
}

struct MeetingScheduleLabelsOverlay: View {
    let placements: [MeetingScheduleLabelPlacement]
    let onSelect: (MeetingBooking) -> Void

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let horizontalInset = MeetingScheduleLabelMetrics.horizontalInset
            let laneGap = MeetingScheduleLabelMetrics.laneGap
            let fullAvailableWidth = max(1, width - horizontalInset * 2)
            let centeredWidth = min(
                max(180, width - 48),
                fullAvailableWidth
            )
            let laneWidth = max(
                1,
                (width - horizontalInset * 2 - laneGap) / 2
            )

            ZStack(alignment: .topLeading) {
                ForEach(placements) { placement in
                    let geometry = labelGeometry(
                        placement: placement,
                        width: width,
                        centeredWidth: centeredWidth,
                        laneWidth: laneWidth
                    )
                    MeetingScheduleConnector(
                        placement: placement,
                        geometry: geometry,
                        totalWidth: width
                    )
                    .allowsHitTesting(false)
                }

                ForEach(placements) { placement in
                    let geometry = labelGeometry(
                        placement: placement,
                        width: width,
                        centeredWidth: centeredWidth,
                        laneWidth: laneWidth
                    )

                    MeetingScheduleLabel(
                        booking: placement.booking,
                        style: placement.style,
                        width: geometry.width
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onTapGesture {
                        guard !placement.booking.id.isEmpty else { return }
                        onSelect(placement.booking)
                    }
                    .accessibilityLabel(
                        placement.booking.id.isEmpty
                            ? "Khung giờ đã được đặt"
                            : "Xem chi tiết cuộc họp \(placement.booking.title.isEmpty ? "đã có lịch" : placement.booking.title)"
                    )
                    .offset(x: geometry.left, y: placement.labelTop)
                }
            }
        }
    }

    private func labelGeometry(
        placement: MeetingScheduleLabelPlacement,
        width: CGFloat,
        centeredWidth: CGFloat,
        laneWidth: CGFloat
    ) -> (left: CGFloat, width: CGFloat) {
        switch placement.lane {
        case .center:
            return ((width - centeredWidth) / 2, centeredWidth)
        case .left:
            return (MeetingScheduleLabelMetrics.horizontalInset, laneWidth)
        case .right:
            return (
                width - MeetingScheduleLabelMetrics.horizontalInset - laneWidth,
                laneWidth
            )
        }
    }
}

struct MeetingScheduleConnector: View {
    let placement: MeetingScheduleLabelPlacement
    let geometry: (left: CGFloat, width: CGFloat)
    let totalWidth: CGFloat

    var body: some View {
        let labelRight = geometry.left + geometry.width
        let labelCenterY = placement.labelTop + MeetingScheduleLabelMetrics.height / 2
        let leftRailX: CGFloat = 4
        let rightRailX = max(4, totalWidth - 4)
        let centerLeftRailX = totalWidth / 2 - 4
        let centerRightRailX = totalWidth / 2 + 4

        let startAnchorX: CGFloat = {
            switch placement.lane {
            case .center, .left: return leftRailX
            case .right: return centerRightRailX
            }
        }()

        let endAnchorX: CGFloat = {
            switch placement.lane {
            case .center, .right: return rightRailX
            case .left: return centerLeftRailX
            }
        }()

        ZStack(alignment: .topLeading) {
            startConnectorPath(
                anchorX: startAnchorX,
                anchorY: placement.startY,
                labelX: geometry.left,
                labelY: labelCenterY
            )
            .stroke(
                placement.style.line.opacity(0.72),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )

            endConnectorPath(
                labelX: labelRight,
                labelY: labelCenterY,
                anchorX: endAnchorX,
                anchorY: placement.endY
            )
            .stroke(
                placement.style.line.opacity(0.72),
                style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round)
            )

            Circle()
                .fill(placement.style.line.opacity(0.88))
                .frame(
                    width: startAnchorX == leftRailX ? 4 : 3.4,
                    height: startAnchorX == leftRailX ? 4 : 3.4
                )
                .position(x: startAnchorX, y: placement.startY)

            Circle()
                .fill(placement.style.line.opacity(0.88))
                .frame(
                    width: endAnchorX == rightRailX ? 4 : 3.4,
                    height: endAnchorX == rightRailX ? 4 : 3.4
                )
                .position(x: endAnchorX, y: placement.endY)
        }
    }

    private func startConnectorPath(
        anchorX: CGFloat,
        anchorY: CGFloat,
        labelX: CGFloat,
        labelY: CGFloat
    ) -> Path {
        let deltaX = labelX - anchorX
        let deltaY = labelY - anchorY
        let radius = min(
            MeetingScheduleLabelMetrics.cornerRadius,
            abs(deltaX),
            abs(deltaY)
        )
        let verticalDirection: CGFloat = deltaY > 0 ? 1 : deltaY < 0 ? -1 : 0
        let horizontalDirection: CGFloat = deltaX > 0 ? 1 : deltaX < 0 ? -1 : 0

        return Path { path in
            path.move(to: CGPoint(x: anchorX, y: anchorY))
            if radius > 0 {
                path.addLine(
                    to: CGPoint(
                        x: anchorX,
                        y: labelY - verticalDirection * radius
                    )
                )
                path.addQuadCurve(
                    to: CGPoint(
                        x: anchorX + horizontalDirection * radius,
                        y: labelY
                    ),
                    control: CGPoint(x: anchorX, y: labelY)
                )
            }
            path.addLine(to: CGPoint(x: labelX, y: labelY))
        }
    }

    private func endConnectorPath(
        labelX: CGFloat,
        labelY: CGFloat,
        anchorX: CGFloat,
        anchorY: CGFloat
    ) -> Path {
        let deltaX = anchorX - labelX
        let deltaY = anchorY - labelY
        let radius = min(
            MeetingScheduleLabelMetrics.cornerRadius,
            abs(deltaX),
            abs(deltaY)
        )
        let horizontalDirection: CGFloat = deltaX > 0 ? 1 : deltaX < 0 ? -1 : 0
        let verticalDirection: CGFloat = deltaY > 0 ? 1 : deltaY < 0 ? -1 : 0

        return Path { path in
            path.move(to: CGPoint(x: labelX, y: labelY))
            if radius > 0 {
                path.addLine(
                    to: CGPoint(
                        x: anchorX - horizontalDirection * radius,
                        y: labelY
                    )
                )
                path.addQuadCurve(
                    to: CGPoint(
                        x: anchorX,
                        y: labelY + verticalDirection * radius
                    ),
                    control: CGPoint(x: anchorX, y: labelY)
                )
            }
            path.addLine(to: CGPoint(x: anchorX, y: anchorY))
        }
    }
}

struct MeetingScheduleLabel: View {
    let booking: MeetingBooking
    let style: MeetingTimelineBookingStyle
    let width: CGFloat

    var body: some View {
        HStack(spacing: 7) {
            Text(
                [booking.title.isEmpty ? "Đã có lịch" : booking.title, booking.organizerName]
                    .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " · ")
            )
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(style.foreground)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 2)

            Text(MeetingPresentation.range(booking))
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(style.meta)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .padding(.horizontal, 11)
        .frame(
            width: width,
            height: MeetingScheduleLabelMetrics.height,
            alignment: .leading
        )
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(style.fill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(style.border.opacity(0.96), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.035), radius: 1.5, y: 0.5)
    }
}

/// Where each booking's label goes on a day timeline: one centred label, or
/// two lanes when labels would overlap, each kept inside the timeline with a
/// connector back to the booking's start and end. Pure geometry, shared by the
/// SwiftUI timeline (iOS 18+) and the UIKit one (iOS 17), so both place every
/// meeting identically.
enum MeetingScheduleLayout {
    struct Slot {
        let item: TimelineBookingItem
        let lane: MeetingScheduleLabelLane
        let startY: CGFloat
        let endY: CGFloat
        var labelTop: CGFloat
    }

    static func slots(
        bookings: [MeetingBooking],
        firstHour: Int,
        lastHour: Int,
        hourHeight: CGFloat
    ) -> [Slot] {
        let timelineHeight = hourHeight * CGFloat(lastHour - firstHour + 1)
        let labelHeight = MeetingScheduleLabelMetrics.height
        let spacing = MeetingScheduleLabelMetrics.spacing
        let inset = MeetingScheduleLabelMetrics.verticalInset
        let latestTop = max(inset, timelineHeight - inset - labelHeight)

        // A booking can appear twice in one response; place it once.
        var seenServerBookingIDs = Set<String>()
        let items: [TimelineBookingItem] = bookings.enumerated().compactMap { index, booking in
            if !booking.id.isEmpty, !seenServerBookingIDs.insert(booking.id).inserted {
                return nil
            }
            return TimelineBookingItem(sourceIndex: index, booking: booking)
        }

        let candidates: [MeetingScheduleLabelCandidate] = items.compactMap { item in
            guard let position = position(item.booking, firstHour: firstHour, lastHour: lastHour, hourHeight: hourHeight) else {
                return nil
            }
            let startY = position.top
            let endY = position.top + position.height
            let eventCenter = (startY + endY) / 2
            let idealTop = min(max(eventCenter - labelHeight / 2, inset), latestTop)
            return MeetingScheduleLabelCandidate(item: item, startY: startY, endY: endY, idealTop: idealTop)
        }
        .sorted {
            if $0.idealTop == $1.idealTop {
                return $0.item.sourceIndex < $1.item.sourceIndex
            }
            return $0.idealTop < $1.idealTop
        }

        var slots: [Slot] = []
        var groupStart = 0
        while groupStart < candidates.count {
            var groupEnd = groupStart + 1
            var groupBottom = candidates[groupStart].idealTop + labelHeight
            while groupEnd < candidates.count, candidates[groupEnd].idealTop < groupBottom + spacing {
                groupBottom = max(groupBottom, candidates[groupEnd].idealTop + labelHeight)
                groupEnd += 1
            }
            let group = Array(candidates[groupStart..<groupEnd])

            if group.count == 1, let candidate = group.first {
                slots.append(Slot(item: candidate.item, lane: .center, startY: candidate.startY,
                                  endY: candidate.endY, labelTop: candidate.idealTop))
            } else {
                var laneBottoms: [CGFloat?] = [nil, nil]
                for (order, candidate) in group.enumerated() {
                    let preferredLane = order.isMultiple(of: 2) ? 0 : 1
                    let alternateLane = 1 - preferredLane
                    func canUse(_ laneIndex: Int) -> Bool {
                        guard let bottom = laneBottoms[laneIndex] else { return true }
                        return candidate.idealTop >= bottom + spacing
                    }
                    let laneIndex: Int
                    if canUse(preferredLane) {
                        laneIndex = preferredLane
                    } else if canUse(alternateLane) {
                        laneIndex = alternateLane
                    } else {
                        let preferredBottom = laneBottoms[preferredLane] ?? -CGFloat.greatestFiniteMagnitude
                        let alternateBottom = laneBottoms[alternateLane] ?? -CGFloat.greatestFiniteMagnitude
                        laneIndex = preferredBottom <= alternateBottom ? preferredLane : alternateLane
                    }
                    let minimumTop = laneBottoms[laneIndex].map { $0 + spacing } ?? inset
                    let labelTop = max(candidate.idealTop, minimumTop)
                    slots.append(Slot(item: candidate.item, lane: laneIndex == 0 ? .left : .right,
                                      startY: candidate.startY, endY: candidate.endY, labelTop: labelTop))
                    laneBottoms[laneIndex] = labelTop + labelHeight
                }
            }
            groupStart = groupEnd
        }
        return keepInside(slots, timelineHeight: timelineHeight)
    }

    /// Shifts each lane so no label leaves the timeline or overlaps another.
    private static func keepInside(_ slots: [Slot], timelineHeight: CGFloat) -> [Slot] {
        var result = slots
        let labelHeight = MeetingScheduleLabelMetrics.height
        let spacing = MeetingScheduleLabelMetrics.spacing
        let inset = MeetingScheduleLabelMetrics.verticalInset
        let maximumBottom = timelineHeight - inset

        for lane in [MeetingScheduleLabelLane.left, .right] {
            let indices = result.indices
                .filter { result[$0].lane == lane }
                .sorted { result[$0].labelTop < result[$1].labelTop }
            guard let firstIndex = indices.first, let lastIndex = indices.last else { continue }

            let overflow = result[lastIndex].labelTop + labelHeight - maximumBottom
            if overflow > 0 {
                for index in indices { result[index].labelTop -= overflow }
            }
            if indices.count > 1 {
                for position in stride(from: indices.count - 2, through: 0, by: -1) {
                    let index = indices[position]
                    let nextIndex = indices[position + 1]
                    let latestWithoutOverlap = result[nextIndex].labelTop - labelHeight - spacing
                    if result[index].labelTop > latestWithoutOverlap {
                        result[index].labelTop = latestWithoutOverlap
                    }
                }
            }
            let underflow = inset - result[firstIndex].labelTop
            if underflow > 0 {
                for index in indices { result[index].labelTop += underflow }
            }
        }
        return result
    }

    /// The booking's vertical extent within the visible hours, if any.
    static func position(
        _ booking: MeetingBooking,
        firstHour: Int,
        lastHour: Int,
        hourHeight: CGFloat
    ) -> (top: CGFloat, height: CGFloat)? {
        guard let start = booking.startDate, let end = booking.endDate else { return nil }
        let calendar = MeetingPresentation.calendar
        let startMinute = calendar.component(.hour, from: start) * 60 + calendar.component(.minute, from: start)
        // A booking that runs past midnight fills the rest of this day; its
        // end time of day alone (00:30) came before its start and hid it.
        let endMinute = calendar.isDate(end, inSameDayAs: start)
            ? calendar.component(.hour, from: end) * 60 + calendar.component(.minute, from: end)
            : 24 * 60
        let visibleStart = max(startMinute, firstHour * 60)
        let visibleEnd = min(endMinute, (lastHour + 1) * 60)
        guard visibleEnd > visibleStart else { return nil }
        return (
            CGFloat(visibleStart - firstHour * 60) / 60 * hourHeight,
            max(CGFloat(visibleEnd - visibleStart) / 60 * hourHeight, 1)
        )
    }

    /// The current-time marker's offset when [day] is today and in range.
    static func currentOffset(day: Date, now: Date, firstHour: Int, lastHour: Int, hourHeight: CGFloat) -> CGFloat? {
        let calendar = MeetingPresentation.calendar
        guard calendar.isDate(day, inSameDayAs: now) else { return nil }
        let hour = calendar.component(.hour, from: now)
        guard hour >= firstHour && hour <= lastHour else { return nil }
        let minute = calendar.component(.minute, from: now)
        return CGFloat(hour - firstHour) * hourHeight + CGFloat(minute) / 60 * hourHeight
    }
}
