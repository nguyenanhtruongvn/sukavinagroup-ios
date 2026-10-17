import UIKit
import SwiftUI
import Security
import UserNotifications
import Network
import LocalAuthentication
import WidgetKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import WebKit

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Hệ thống"
        case .light: return "Sáng"
        case .dark: return "Tối"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
enum AttendanceMonthDisplayMode: String, CaseIterable, Identifiable {
    case compact
    case full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compact: return "Thu gọn"
        case .full: return "Đầy đủ"
        }
    }
}
enum AppTheme {
    static let red = Color(red: 0.91, green: 0.12, blue: 0.16)
    static let deepRed = Color(red: 0.45, green: 0.04, blue: 0.07)
    static let ink = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1) : UIColor(red: 0.906, green: 0.914, blue: 0.929, alpha: 1)
    })
    static let card = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.12, green: 0.12, blue: 0.15, alpha: 1) : UIColor.white
    })
    static let muted = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.66, green: 0.65, blue: 0.68, alpha: 1) : UIColor(red: 0.36, green: 0.35, blue: 0.38, alpha: 1)
    })
    static let loginAccent = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(red: 0.45, green: 0.04, blue: 0.07, alpha: 0.72) : UIColor.white
    })
    static let field = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.055) : UIColor.white
    })
    static let fieldBorder = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor(red: 0.63, green: 0.66, blue: 0.71, alpha: 0.42)
    })
    static let cardBorder = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.08) : UIColor(red: 0.31, green: 0.34, blue: 0.39, alpha: 0.12)
    })
    static let biometricFill = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white.withAlphaComponent(0.075) : UIColor.white
    })
    static let biometricForeground = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor.white : UIColor(red: 0.68, green: 0.07, blue: 0.10, alpha: 1)
    })

    /// Brand red for text: `red` itself is about 4:1 on white. Icons and
    /// fills keep `red`.
    static let redText = text(red)

    /// `base` used as text, readable (4.5:1) on both the card and the page
    /// background in the current appearance. Pass `chipAlpha` when the text
    /// sits on a pill tinted with the same colour. Mirrors Android `asText()`.
    static func text(_ base: Color, chipAlpha: Double = 0) -> Color {
        let baseColor = UIColor(base), cardColor = UIColor(card), inkColor = UIColor(ink)
        return Color(UIColor { traits in
            let hue = SRGB(baseColor.resolvedColor(with: traits))
            let readable = [cardColor, inkColor].reduce(hue) { result, background in
                let backdrop = hue.composited(over: SRGB(background.resolvedColor(with: traits)), alpha: chipAlpha)
                return result.readable(on: backdrop)
            }
            return UIColor(red: readable.red, green: readable.green, blue: readable.blue, alpha: 1)
        })
    }
}

extension SRGB {
    init(_ color: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(red: Double(red), green: Double(green), blue: Double(blue))
    }
}

/// This UIKit bridge corrects the extra bottom inset introduced by the native
/// paged attendance view on iOS 18 and later.  It must not be instantiated on
/// iOS 17: mutating a hosting scroll view while SwiftUI is laying it out can
/// cause a recursive layout pass there.
@available(iOS 18.0, *)
final class AttendanceScrollInsetNeutralizingView: UIView {
    private weak var managedScrollView: UIScrollView?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        resolveAndApply()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        resolveAndApply()
    }

    private func resolveAndApply() {
        if managedScrollView == nil {
            var candidate = superview
            while let view = candidate {
                if let scrollView = view as? UIScrollView {
                    managedScrollView = scrollView
                    break
                }
                candidate = view.superview
            }
        }
        guard let scrollView = managedScrollView else { return }
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.automaticallyAdjustsScrollIndicatorInsets = false
        if scrollView.contentInset.bottom != 0 {
            var inset = scrollView.contentInset
            inset.bottom = 0
            scrollView.contentInset = inset
        }
        if scrollView.verticalScrollIndicatorInsets.bottom != 0 {
            var inset = scrollView.verticalScrollIndicatorInsets
            inset.bottom = 0
            scrollView.verticalScrollIndicatorInsets = inset
        }
    }
}

@available(iOS 18.0, *)
struct AttendanceScrollInsetNeutralizer: UIViewRepresentable {
    func makeUIView(context: Context) -> AttendanceScrollInsetNeutralizingView {
        AttendanceScrollInsetNeutralizingView(frame: .zero)
    }

    func updateUIView(_ uiView: AttendanceScrollInsetNeutralizingView, context: Context) {}
}

struct PortalPageTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// The header of a tab page that stays in place while only the page's
/// content scrolls beneath it. The title sits where the scrolling tabs put
/// theirs ("Trang chủ", "Tài khoản": 20 pt below the safe area and from the
/// edges), so every tab title has the same size and position. 12 pt, the
/// "Đơn từ" value, left it ~7 pt higher: that page gains extra top space
/// from its container, a pinned inset does not.
struct PortalPinnedHeader<Accessory: View>: View {
    let title: String
    let background: Color
    @ViewBuilder var accessory: () -> Accessory

    init(_ title: String, background: Color = AppTheme.ink, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.title = title
        self.background = background
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PortalPageTitle(title)
            accessory()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Opaque, so rows scrolled underneath do not show through.
        .background(background.ignoresSafeArea(edges: .top))
    }
}

struct AdaptiveGlassSurface: ViewModifier {
    let cornerRadius: CGFloat
    var tint: Color? = nil
    var interactive = false
    var legacyFill = AppTheme.card
    var legacyOpacity = 1.0

    @ViewBuilder
    func body(content: Content) -> some View {
        // Do not reference the iOS 26 Liquid Glass APIs from the app binary.
        // Xcode 26 can turn that reference into a required SwiftUICore.framework
        // dependency even inside an availability check, which prevents the app
        // from launching on iOS 15–17.  This adaptive surface intentionally uses
        // the same supported material treatment on every OS version instead.
        content
            .background(legacyFill.opacity(legacyOpacity))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

extension View {
    func adaptiveGlassSurface(
        cornerRadius: CGFloat,
        tint: Color? = nil,
        interactive: Bool = false,
        legacyFill: Color = AppTheme.card,
        legacyOpacity: Double = 1
    ) -> some View {
        modifier(
            AdaptiveGlassSurface(
                cornerRadius: cornerRadius,
                tint: tint,
                interactive: interactive,
                legacyFill: legacyFill,
                legacyOpacity: legacyOpacity
            )
        )
    }

    @ViewBuilder
    func hidesPortalBottomScrollEdgeEffect() -> some View {
        // scrollEdgeEffectHidden is also an iOS 26-only SwiftUI API. Keep the
        // cross-version behaviour here so the app never gains a hard link to a
        // framework that is absent on older iOS releases.
        self
            .scrollIndicators(.hidden)
            .ignoresSafeArea(.container, edges: .bottom)
    }

    @ViewBuilder
    func adaptivePortalTabBarBackground() -> some View {
        // Keep the tab-bar backdrop in UIKit (AppDelegate).  Referencing the
        // iOS 26 SwiftUI tab-bar appearance path makes Xcode 26 emit a strong
        // SwiftUICore dependency, which causes a launch crash on iOS 17.
        // Returning the view unchanged keeps the layout stable and lets the
        // native UITabBarAppearance supply the same adaptive material surface.
        self
    }

}

extension View {
    /// Logs a compact date picker's own width next to the width its long
    /// date needs (UIFlowLog "datePicker.width"). The long form is about
    /// twice as wide as "18/10/26", so debug.log shows which one appeared,
    /// and when. Apply it to the picker alone.
    func logsCompactDateWidth(day: Date, includesTime: Bool = false, logName: String) -> some View {
        modifier(CompactDateWidthLog(
            day: VietnamTime.calendar.startOfDay(for: day),
            includesTime: includesTime,
            logName: logName
        ))
    }
}

/// See `View.logsCompactDateWidth`.
struct CompactDateWidthLog: ViewModifier {
    let day: Date
    let includesTime: Bool
    let logName: String

    func body(content: Content) -> some View {
        let wanted = Self.fullWidth(of: day, includesTime: includesTime)
        return content.background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { log(geometry.size.width, wanted: wanted, cause: "appear") }
                    .onChange(of: geometry.size.width) { _, width in log(width, wanted: wanted, cause: "resize") }
            }
        )
    }

    /// Roughly the width of `day`'s long form as the compact picker draws
    /// it: each value in its own capsule of body text.
    static func fullWidth(of day: Date, includesTime: Bool) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .body)
        func textWidth(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let capsule: CGFloat = 26
        var width = textWidth(longDate.string(from: day)) + capsule
        if includesTime {
            width += 8 + textWidth(VietnamTime.clock.string(from: day)) + capsule
        }
        return width
    }

    /// The system's medium date style in Vietnamese, the long form.
    private static let longDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = VietnamTime.locale
        formatter.calendar = VietnamTime.calendar
        formatter.timeZone = VietnamTime.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private func log(_ width: CGFloat, wanted: CGFloat, cause: String) {
        UIFlowLog.record(
            "datePicker.width",
            "\(logName) w=\(Int(width.rounded())) wanted=\(Int(wanted.rounded())) \(cause)"
        )
    }
}

/// A label and a compact date picker on one row, as a labelled DatePicker
/// lays out. The picker keeps its full width; a long label wraps instead.
///
/// One layout only: a picker swapped in by a layout change is a new one
/// (see `SystemCompactDatePicker`).
struct CompactDateRow<Picker: View>: View {
    let label: String
    @ViewBuilder let picker: () -> Picker

    var body: some View {
        HStack {
            Text(label)
                .lineLimit(2)
                // VoiceOver reads the picker's own label instead.
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            picker()
                .fixedSize()
        }
    }
}

/// Apple's compact date picker (UIDatePicker) that keeps the full date
/// ("18 thg 10, 2026", not "18/10/26").
///
/// The compact picker draws its short form whenever its frame is
/// narrower than its long form, and SwiftUI's DatePicker takes the width
/// it measures when it is created, which fits today's date only. Đi trễ
/// and Về sớm open on today, so they fit; any other day can be a few
/// points wider in proportional digits ("attendanceDate w=185
/// wanted=188", debug.log 1.0.79) and was shortened. Moving a new picker
/// to its date after it appeared did not help either (1.0.81, Ngày chấm
/// công).
///
/// So the width is not left to the picker: `sizeThatFits` gives it at
/// least the width of its date's long form, worked out from the text
/// (`CompactDateWidthLog.fullWidth`), with a few points to spare. A wider
/// frame only leaves room before the picker, which sits at its trailing
/// edge.
struct SystemCompactDatePicker: UIViewRepresentable {
    @Binding var selection: Date
    let mode: UIDatePicker.Mode
    var minimum: Date? = nil
    let accessibilityLabel: String

    /// Room left beyond the computed long form, against rounding.
    private static let spare: CGFloat = 8

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> UIDatePicker {
        let picker = UIDatePicker()
        picker.preferredDatePickerStyle = .compact
        picker.datePickerMode = mode
        picker.timeZone = VietnamTime.timeZone
        picker.calendar = VietnamTime.calendar
        picker.locale = VietnamTime.locale
        picker.minimumDate = minimum
        picker.date = selection
        picker.accessibilityLabel = accessibilityLabel
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return picker
    }

    func updateUIView(_ picker: UIDatePicker, context: Context) {
        context.coordinator.selection = $selection
        if picker.minimumDate != minimum { picker.minimumDate = minimum }
        if picker.date != selection {
            picker.date = selection
            // The long form of the new date may be wider: measure again.
            picker.invalidateIntrinsicContentSize()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView picker: UIDatePicker, context: Context) -> CGSize? {
        let fitted = picker.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let longForm = CompactDateWidthLog.fullWidth(of: selection, includesTime: mode != .date)
        let width = max(fitted.width, longForm) + Self.spare
        let height = (20...80).contains(fitted.height) ? fitted.height : 34
        // Which of the two set the width: if the picker's own measure is
        // always at least the long form, the estimate and spare can go.
        let line = "\(accessibilityLabel) fitted=\(Int(fitted.width.rounded())) longForm=\(Int(longForm.rounded())) intrinsic=\(Int(picker.intrinsicContentSize.width.rounded())) frame=\(Int(picker.bounds.width.rounded()))"
        if line != context.coordinator.lastSizeLog {
            context.coordinator.lastSizeLog = line
            UIFlowLog.record("datePicker.fit", line)
        }
        return CGSize(width: ceil(width), height: ceil(height))
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Date>
        var lastSizeLog = ""

        init(selection: Binding<Date>) {
            self.selection = selection
        }

        @objc func changed(_ picker: UIDatePicker) {
            if selection.wrappedValue != picker.date { selection.wrappedValue = picker.date }
        }
    }
}

/// Apple's compact time picker under a drawn tile, taking every tap on
/// it, so a tap anywhere on the tile opens Apple's own time bubble. Put it in
/// the tile's background and give the tile `.allowsHitTesting(false)`.
/// Only the hour and minute are taken from the picker; the day stays.
/// UIDatePicker because SwiftUI's DatePicker cannot set a minute interval.
struct TileFillingTimePicker: UIViewRepresentable {
    @Binding var selection: Date
    var minuteInterval = 1
    /// Earliest and latest time the bubble offers (on the day of `selection`).
    var minimum: Date? = nil
    var maximum: Date? = nil
    let accessibilityLabel: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> TileFillingPickerView {
        let view = TileFillingPickerView()
        view.name = accessibilityLabel
        let picker = view.picker
        picker.datePickerMode = .time
        picker.minuteInterval = minuteInterval
        picker.timeZone = VietnamTime.timeZone
        picker.calendar = VietnamTime.calendar
        picker.locale = VietnamTime.locale
        picker.minimumDate = minimum
        picker.maximumDate = maximum
        picker.date = selection
        picker.accessibilityLabel = accessibilityLabel
        picker.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        return view
    }

    func updateUIView(_ view: TileFillingPickerView, context: Context) {
        context.coordinator.selection = $selection
        if view.picker.minimumDate != minimum { view.picker.minimumDate = minimum }
        if view.picker.maximumDate != maximum { view.picker.maximumDate = maximum }
        if view.picker.date != selection { view.picker.date = selection }
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Date>

        init(selection: Binding<Date>) {
            self.selection = selection
        }

        @objc func changed(_ picker: UIDatePicker) {
            let calendar = VietnamTime.calendar
            let time = calendar.dateComponents([.hour, .minute], from: picker.date)
            let current = selection.wrappedValue
            selection.wrappedValue = calendar.date(
                bySettingHour: time.hour ?? 0,
                minute: time.minute ?? 0,
                second: 0,
                of: current
            ) ?? current
        }
    }
}

/// Holds a compact UIDatePicker at its own size under a drawn tile, so a
/// tap anywhere on the tile, not only on the picker's small capsule,
/// opens Apple's picker bubble. Put under a drawn face that takes no
/// touches. Used by the booking Bắt đầu tile (MeetingBookingSheet on iOS
/// 18, LegacyMeetingRoomsUIKit on iOS 17) and the Giờ vào / Giờ ra cards.
///
/// What did not work:
/// - stretching the picker to the tile (02708ca): its capsule stays at the
///   trailing edge, so only taps near the chevron opened it;
/// - scaling it about three times over the tile (c37b077): taps worked,
///   but Apple places the bubble from the picker's frame, so it came from
///   an oversized frame and did not open as Apple's does;
/// - handing a tap elsewhere on the tile to the capsule (5f7e64d): the
///   capsule ignores a touch that is not inside it.
///
/// So the picker keeps its own size and rests where the time is drawn,
/// centred along the tile's bottom; when a touch lands elsewhere on the
/// tile, the picker first moves just far enough to be under the finger.
/// The touch is then a real tap inside Apple's capsule, and the bubble
/// opens from the capsule at its own size, as Apple's does.
///
/// The picker is only given a tap it can act on. Its bubble is presented
/// by the sheet, and the sheet presents one thing at a time: a tap while
/// the Thời lượng menu was still on screen (presented
/// _UIContextMenuActionsOnlyViewController) made the picker report its
/// bubble open although none could be presented, and it then never
/// reported it closed, so it counted itself open and ignored the next tap
/// (debug.log, 1.0.85). So a touch that lands on the tile while the sheet
/// presents anything but a date bubble is kept from the picker: it only
/// closes what is open, as a tap outside a menu does. The menu cannot be
/// closed sooner from here: dismissing it, even unanimated, left it
/// presented for that touch (1.0.86, "after=_UIContextMenu...").
/// A date bubble already open is left to Apple: from it, a tap on another
/// time tile opens that one, and a tap on its own tile closes it.
/// Touches, kept touches and the bubble opening and closing are logged
/// ("tilePicker.*").
final class TileFillingPickerView: UIView {
    let picker = UIDatePicker()
    /// Names the tile in debug.log.
    var name = "tile"

    private var centerX: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!
    private static let restingBottom: CGFloat = -6
    /// The touch being hit-tested, and whether it goes to the picker:
    /// UIKit can hit-test one touch more than once.
    private var touchTimestamp: TimeInterval = -1
    private var touchGoesToPicker = true
    private var loggedLayout = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        picker.preferredDatePickerStyle = .compact
        picker.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        centerX = picker.centerXAnchor.constraint(equalTo: centerXAnchor)
        bottom = picker.bottomAnchor.constraint(equalTo: bottomAnchor, constant: Self.restingBottom)
        // Only if the picker reports no size of its own: a compact time picker's.
        let width = picker.widthAnchor.constraint(equalToConstant: 80)
        let height = picker.heightAnchor.constraint(equalToConstant: 34)
        width.priority = .fittingSizeLevel
        height.priority = .fittingSizeLevel
        NSLayoutConstraint.activate([centerX, bottom, width, height])
        picker.addTarget(self, action: #selector(bubbleOpened), for: .editingDidBegin)
        picker.addTarget(self, action: #selector(bubbleClosed), for: .editingDidEnd)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func bubbleOpened() {
        UIFlowLog.record("tilePicker.open", name)
    }

    @objc private func bubbleClosed() {
        UIFlowLog.record("tilePicker.close", name)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, !isHidden, self.point(inside: point, with: event) else { return nil }
        if let event, event.type == .touches, event.timestamp != touchTimestamp {
            touchTimestamp = event.timestamp
            touchGoesToPicker = clearPresentation(forTouchAt: point)
        }
        guard touchGoesToPicker else { return self }
        moveCapsule(under: point)
        let inPicker = convert(point, to: picker)
        return picker.hitTest(inPicker, with: event) ?? picker
    }

    /// Whether a new touch can go to the picker: nothing but a date bubble
    /// is presented.
    private func clearPresentation(forTouchAt point: CGPoint) -> Bool {
        let presented = nearestViewController()?.presentedViewController
        let free = presented == nil || Self.isDateBubble(presented)
        UIFlowLog.record(
            "tilePicker.touch",
            "\(name) at=\(Int(point.x)),\(Int(point.y)) presented=\(Self.typeName(presented)) toPicker=\(free)"
        )
        return free
    }

    private static func isDateBubble(_ controller: UIViewController?) -> Bool {
        guard let controller, !controller.isBeingDismissed else { return false }
        return typeName(controller).contains("DatePicker")
    }

    private static func typeName(_ controller: UIViewController?) -> String {
        controller.map { String(describing: type(of: $0)) } ?? "none"
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }

    /// Moves the picker from its resting place just far enough that
    /// `point` lies inside it, with a little margin.
    private func moveCapsule(under point: CGPoint) {
        let size = picker.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let margin: CGFloat = 6
        let resting = CGRect(
            x: (bounds.width - size.width) / 2,
            y: bounds.height + Self.restingBottom - size.height,
            width: size.width,
            height: size.height
        )
        func shift(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
            if value - margin < low { return value - margin - low }
            if value + margin > high { return value + margin - high }
            return 0
        }
        let dx = shift(point.x, resting.minX, resting.maxX)
        let dy = shift(point.y, resting.minY, resting.maxY)
        guard centerX.constant != dx || bottom.constant != Self.restingBottom + dy else { return }
        centerX.constant = dx
        bottom.constant = Self.restingBottom + dy
        layoutIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let line = "picker=\(Int(picker.bounds.width))x\(Int(picker.bounds.height)) tile=\(Int(bounds.width))x\(Int(bounds.height))"
        if line != loggedLayout {
            loggedLayout = line
            UIFlowLog.record("tilePicker.size", line)
        }
    }
}
