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

@available(iOS 17.0, *)
struct MeetingTimelineBookingStyle {
    let fill: Color
    let border: Color
    let foreground: Color
    let meta: Color
    let line: Color
}

@available(iOS 17.0, *)
enum MeetingScheduleLabelLane: Equatable {
    case center, left, right
}

@available(iOS 17.0, *)
enum MeetingScheduleLabelMetrics {
    static let height: CGFloat = 36
    static let spacing: CGFloat = 8
    static let verticalInset: CGFloat = 4
    static let horizontalInset: CGFloat = 16
    static let laneGap: CGFloat = 22
    static let cornerRadius: CGFloat = 5
}

@available(iOS 17.0, *)
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

@available(iOS 17.0, *)
struct MeetingScheduleLabelCandidate {
    let item: TimelineBookingItem
    let startY: CGFloat
    let endY: CGFloat
    let idealTop: CGFloat
}

@available(iOS 17.0, *)
struct MeetingScheduleLabelPlacement: Identifiable {
    let id: String
    let booking: MeetingBooking
    let style: MeetingTimelineBookingStyle
    let lane: MeetingScheduleLabelLane
    let startY: CGFloat
    let endY: CGFloat
    var labelTop: CGFloat
}

@available(iOS 17.0, *)
struct MeetingTimeline: View {
    let bookings: [MeetingBooking]
    let date: Date
    let onSelect: (MeetingBooking) -> Void

    private let firstHour = 6
    private let lastHour = 23
    private let hourHeight: CGFloat = 72

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
                    if let currentOffset = currentOffset(at: clock.date) {
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

    private var timelineBookings: [TimelineBookingItem] {
        var seenServerBookingIDs = Set<String>()
        return bookings.enumerated().compactMap { index, booking in
            if !booking.id.isEmpty, !seenServerBookingIDs.insert(booking.id).inserted {
                return nil
            }
            return TimelineBookingItem(sourceIndex: index, booking: booking)
        }
    }

    private var labelPlacements: [MeetingScheduleLabelPlacement] {
        let labelHeight = MeetingScheduleLabelMetrics.height
        let spacing = MeetingScheduleLabelMetrics.spacing
        let inset = MeetingScheduleLabelMetrics.verticalInset
        let latestTop = max(inset, timelineHeight - inset - labelHeight)

        let candidates: [MeetingScheduleLabelCandidate] = timelineBookings.compactMap { item in
            guard let position = bookingPosition(item.booking) else { return nil }
            let startY = position.top
            let endY = position.top + position.height
            let eventCenter = (startY + endY) / 2
            let idealTop = min(
                max(eventCenter - labelHeight / 2, inset),
                latestTop
            )
            return MeetingScheduleLabelCandidate(
                item: item,
                startY: startY,
                endY: endY,
                idealTop: idealTop
            )
        }
        .sorted {
            if $0.idealTop == $1.idealTop {
                return $0.item.sourceIndex < $1.item.sourceIndex
            }
            return $0.idealTop < $1.idealTop
        }

        var placements: [MeetingScheduleLabelPlacement] = []
        var groupStart = 0

        while groupStart < candidates.count {
            var groupEnd = groupStart + 1
            var groupBottom = candidates[groupStart].idealTop + labelHeight

            while groupEnd < candidates.count,
                  candidates[groupEnd].idealTop < groupBottom + spacing {
                groupBottom = max(
                    groupBottom,
                    candidates[groupEnd].idealTop + labelHeight
                )
                groupEnd += 1
            }

            let group = Array(candidates[groupStart..<groupEnd])

            if group.count == 1, let candidate = group.first {
                placements.append(
                    MeetingScheduleLabelPlacement(
                        id: candidate.item.id,
                        booking: candidate.item.booking,
                        style: bookingStyle(for: candidate.item.booking),
                        lane: .center,
                        startY: candidate.startY,
                        endY: candidate.endY,
                        labelTop: candidate.idealTop
                    )
                )
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
                    let lane: MeetingScheduleLabelLane = laneIndex == 0 ? .left : .right

                    placements.append(
                        MeetingScheduleLabelPlacement(
                            id: candidate.item.id,
                            booking: candidate.item.booking,
                            style: bookingStyle(for: candidate.item.booking),
                            lane: lane,
                            startY: candidate.startY,
                            endY: candidate.endY,
                            labelTop: labelTop
                        )
                    )
                    laneBottoms[laneIndex] = labelTop + labelHeight
                }
            }

            groupStart = groupEnd
        }

        return keepPlacementsInsideTimeline(placements)
    }

    private func keepPlacementsInsideTimeline(
        _ placements: [MeetingScheduleLabelPlacement]
    ) -> [MeetingScheduleLabelPlacement] {
        var result = placements
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
                for index in indices {
                    result[index].labelTop -= overflow
                }
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
                for index in indices {
                    result[index].labelTop += underflow
                }
            }
        }

        return result
    }

    private func currentOffset(at now: Date) -> CGFloat? {
        guard MeetingPresentation.calendar.isDate(date, inSameDayAs: now) else { return nil }
        let hour = MeetingPresentation.calendar.component(.hour, from: now)
        guard hour >= firstHour && hour <= lastHour else { return nil }
        let minute = MeetingPresentation.calendar.component(.minute, from: now)
        return CGFloat(hour - firstHour) * hourHeight + CGFloat(minute) / 60 * hourHeight
    }

    private func bookingPosition(_ booking: MeetingBooking) -> (top: CGFloat, height: CGFloat)? {
        guard let start = MeetingPresentation.date(from: booking.startsAt),
              let end = MeetingPresentation.date(from: booking.endsAt) else { return nil }

        let startMinute = MeetingPresentation.calendar.component(.hour, from: start) * 60
            + MeetingPresentation.calendar.component(.minute, from: start)
        let endMinute = MeetingPresentation.calendar.component(.hour, from: end) * 60
            + MeetingPresentation.calendar.component(.minute, from: end)
        let visibleStart = max(startMinute, firstHour * 60)
        let visibleEnd = min(endMinute, (lastHour + 1) * 60)

        guard visibleEnd > visibleStart else { return nil }

        return (
            CGFloat(visibleStart - firstHour * 60) / 60 * hourHeight,
            max(CGFloat(visibleEnd - visibleStart) / 60 * hourHeight, 1)
        )
    }

    private func bookingStyle(for booking: MeetingBooking) -> MeetingTimelineBookingStyle {
        if booking.isOwner == true {
            // Organiser: richer green pastel, still soft on a light schedule.
            return MeetingTimelineBookingStyle(
                fill: Color(red: 220.0 / 255.0, green: 239.0 / 255.0, blue: 226.0 / 255.0),
                border: Color(red: 143.0 / 255.0, green: 198.0 / 255.0, blue: 160.0 / 255.0),
                foreground: Color(red: 46.0 / 255.0, green: 106.0 / 255.0, blue: 67.0 / 255.0),
                meta: Color(red: 92.0 / 255.0, green: 127.0 / 255.0, blue: 104.0 / 255.0),
                line: Color(red: 166.0 / 255.0, green: 207.0 / 255.0, blue: 178.0 / 255.0)
            )
        }

        if booking.isMine == true {
            // Invitee: calm blue pastel, distinct from organiser green.
            return MeetingTimelineBookingStyle(
                fill: Color(red: 220.0 / 255.0, green: 233.0 / 255.0, blue: 250.0 / 255.0),
                border: Color(red: 142.0 / 255.0, green: 180.0 / 255.0, blue: 232.0 / 255.0),
                foreground: Color(red: 49.0 / 255.0, green: 92.0 / 255.0, blue: 145.0 / 255.0),
                meta: Color(red: 96.0 / 255.0, green: 126.0 / 255.0, blue: 167.0 / 255.0),
                line: Color(red: 168.0 / 255.0, green: 195.0 / 255.0, blue: 232.0 / 255.0)
            )
        }

        // Unrelated: neutral grey pastel, readable but intentionally quieter.
        return MeetingTimelineBookingStyle(
            fill: Color(red: 229.0 / 255.0, green: 231.0 / 255.0, blue: 235.0 / 255.0),
            border: Color(red: 184.0 / 255.0, green: 190.0 / 255.0, blue: 199.0 / 255.0),
            foreground: Color(red: 89.0 / 255.0, green: 97.0 / 255.0, blue: 109.0 / 255.0),
            meta: Color(red: 119.0 / 255.0, green: 127.0 / 255.0, blue: 137.0 / 255.0),
            line: Color(red: 195.0 / 255.0, green: 200.0 / 255.0, blue: 207.0 / 255.0)
        )
    }
}

@available(iOS 17.0, *)
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

@available(iOS 17.0, *)
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

@available(iOS 17.0, *)
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
                .font(.system(size: 9, weight: .medium, design: .monospaced))
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
