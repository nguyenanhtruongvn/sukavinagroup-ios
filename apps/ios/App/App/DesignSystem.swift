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

extension View {
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

/// A label and a date or time field on one row, as a labelled DatePicker
/// lays out. The field keeps its full width; a long label wraps instead.
struct CompactDateRow<Picker: View>: View {
    let label: String
    @ViewBuilder let picker: () -> Picker

    var body: some View {
        HStack {
            Text(label)
                .lineLimit(2)
                // VoiceOver reads the field's own label instead.
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            picker()
                .fixedSize()
        }
    }
}

/// A date, time, or date and time field: each value in the system's
/// tertiary fill, as the compact picker shows it ("18 thg 10, 2026",
/// "08:30"), and each its own button (`DatePopoverButton`): the date opens
/// Apple's calendar in a popover, the time Apple's time wheels.
///
/// It was Apple's compact picker. Its bubble takes the input focus when
/// it opens, so a keyboard left open by a text field closed; the system
/// popover, as Thời lượng opens, leaves the keyboard open (1.0.89). The
/// values are set as text, so a date is never cut to its short form
/// ("18/10/26"), which the compact picker fell back to whenever its frame
/// was narrower than its long form.
struct DatePopoverField: View {
    @Binding var selection: Date
    let mode: UIDatePicker.Mode
    var minimum: Date? = nil
    let accessibilityLabel: String

    var body: some View {
        // The time before the date, as Vietnamese writes it ("08:30 ngày
        // 18/10/2026") and as Apple's compact picker showed them in vi_VN.
        HStack(spacing: 6) {
            if mode != .date {
                valueBox(
                    VietnamTime.clock.string(from: selection),
                    mode: .time,
                    label: mode == .time ? accessibilityLabel : "\(accessibilityLabel), giờ"
                )
            }
            if mode != .time {
                valueBox(Self.longDate.string(from: selection), mode: .date, label: accessibilityLabel)
            }
        }
        .fixedSize()
    }

    /// One value and the button over it that opens its own popover: `.date`
    /// keeps the time of `selection`, `.time` keeps its day.
    private func valueBox(_ text: String, mode: UIDatePicker.Mode, label: String) -> some View {
        Text(text)
            .font(.body)
            .monospacedDigit()
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
            .overlay(DatePopoverButton(
                selection: $selection,
                mode: mode,
                minimum: minimum,
                accessibilityLabel: label,
                accessibilityValue: text
            ))
    }

    /// The system's medium date style in Vietnamese, the compact picker's
    /// long form.
    private static let longDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = VietnamTime.locale
        formatter.calendar = VietnamTime.calendar
        formatter.timeZone = VietnamTime.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// A drawn field or tile's whole area as a button that opens Apple's
/// popover with Apple's calendar (a date) or wheels (a time)
/// (`DatePopoverControl`). Put it in the face's `.overlay`; it is
/// transparent.
struct DatePopoverButton: UIViewRepresentable {
    @Binding var selection: Date
    /// `.time` keeps the day of `selection`; `.date` keeps its time.
    var mode: UIDatePicker.Mode = .time
    var minuteInterval = 1
    /// Earliest and latest value offered.
    var minimum: Date? = nil
    var maximum: Date? = nil
    let accessibilityLabel: String
    /// What the face shows ("06:30", "1 giờ 30 phút"), for VoiceOver.
    let accessibilityValue: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> DatePopoverControl {
        let control = DatePopoverControl()
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        apply(to: control)
        return control
    }

    func updateUIView(_ control: DatePopoverControl, context: Context) {
        context.coordinator.selection = $selection
        apply(to: control)
    }

    private func apply(to control: DatePopoverControl) {
        control.mode = mode
        control.minuteInterval = minuteInterval
        control.minimumDate = minimum
        control.maximumDate = maximum
        if control.date != selection { control.date = selection }
        control.accessibilityLabel = accessibilityLabel
        control.accessibilityValue = accessibilityValue
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<Date>

        init(selection: Binding<Date>) {
            self.selection = selection
        }

        @objc func changed(_ control: DatePopoverControl) {
            if selection.wrappedValue != control.date { selection.wrappedValue = control.date }
        }
    }
}

/// A transparent button over a whole drawn field or tile (Bắt đầu, Thời
/// lượng, Giờ vào / Giờ ra, every date). A tap anywhere on it opens Apple's
/// popover from it, holding Apple's calendar for a date or its wheels for
/// a time (UIDatePicker); every change is sent as `.valueChanged`. In
/// `.time` mode the hour and minute are set on the day of `date`; in
/// `.date` mode the day is set at the time of `date`. Used by SwiftUI (`DatePopoverButton`, iOS 18) and
/// UIKit (LegacyMeetingRoomsUIKit, iOS 17) alike.
///
/// Apple offers no way to open the compact picker's own bubble from code:
/// it opens only for a touch inside its small capsule. Every way of
/// stretching that capsule over a tile (stretched, scaled, touches handed
/// over, moved under the finger, laid invisibly in front) depended on how
/// iOS routes touches inside Apple's control, and failed in turn
/// (02708ca … 1.0.88). A button that is the tile, opening the system
/// popover, depends on nothing of the kind.
///
/// - The popover is the system's (`UIPopoverPresentationController`, kept
///   a popover on iPhone), anchored to the field.
/// - From an open popover, a tap on another field closes it at once and
///   opens that field's: the other fields pass touches through the
///   popover. A tap on its own field or anywhere else only closes it, as
///   any popover.
/// - A tap on a field while a popover is still closing opens the field's
///   popover once the closing transition ends (its own completion, no
///   timer).
/// - A keyboard left open by a text field stays open.
final class DatePopoverControl: UIControl {
    var mode: UIDatePicker.Mode = .time
    var minuteInterval = 1
    var minimumDate: Date?
    var maximumDate: Date?
    /// The value shown; in `.time` mode also the day the chosen hour and
    /// minute are set on, in `.date` mode the time the chosen day keeps.
    var date = Date() {
        didSet {
            if let picker = popover?.picker, picker.date != date { picker.date = date }
        }
    }

    private weak var popover: DatePopoverController?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button
        addTarget(self, action: #selector(tapped), for: .touchUpInside)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func tapped() {
        guard let presenter = nearestViewController() else { return }
        guard let presented = presenter.presentedViewController else {
            present(from: presenter)
            return
        }
        guard let other = presented as? DatePopoverController else {
            // Something else is on screen (a confirmation): leave it be.
            return
        }
        if other.isBeingDismissed {
            // Closing already, from a tap outside it a moment ago: open this
            // one the moment it is gone, so that tap is not lost.
            other.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self, weak presenter] _ in
                guard let self, let presenter, presenter.presentedViewController == nil else { return }
                self.present(from: presenter)
            }
            return
        }
        // Another field's popover, let through to here: close it now, then
        // open this one, so one tap moves from field to field.
        other.dismiss(animated: false) { [weak self, weak presenter] in
            guard let self, let presenter else { return }
            self.present(from: presenter)
        }
    }

    private func present(from presenter: UIViewController) {
        let controller = DatePopoverController()
        let picker = controller.picker
        picker.datePickerMode = mode
        // A day on Apple's calendar; a time, or a date and time, on its wheels.
        picker.preferredDatePickerStyle = mode == .date ? .inline : .wheels
        picker.minuteInterval = minuteInterval
        picker.timeZone = VietnamTime.timeZone
        picker.calendar = VietnamTime.calendar
        picker.locale = VietnamTime.locale
        picker.minimumDate = minimumDate
        picker.maximumDate = maximumDate
        picker.date = date
        picker.accessibilityLabel = accessibilityLabel
        picker.addTarget(self, action: #selector(pickerChanged(_:)), for: .valueChanged)

        controller.modalPresentationStyle = .popover
        if let popover = controller.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = bounds
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = controller
            popover.passthroughViews = otherFields()
        }
        self.popover = controller
        presenter.present(controller, animated: true)
    }

    @objc private func pickerChanged(_ picker: UIDatePicker) {
        let calendar = VietnamTime.calendar
        let chosen: Date
        switch mode {
        case .time:
            let time = calendar.dateComponents([.hour, .minute], from: picker.date)
            chosen = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: date) ?? date
        case .date:
            let time = calendar.dateComponents([.hour, .minute, .second], from: date)
            chosen = calendar.date(
                bySettingHour: time.hour ?? 0,
                minute: time.minute ?? 0,
                second: time.second ?? 0,
                of: picker.date
            ) ?? picker.date
        default:
            chosen = picker.date
        }
        guard chosen != date else { return }
        date = chosen
        sendActions(for: .valueChanged)
    }

    /// The other date and time fields on screen, which a tap may reach
    /// through this field's popover.
    private func otherFields() -> [UIView] {
        guard let window else { return [] }
        var fields: [UIView] = []
        func collect(_ view: UIView) {
            if let field = view as? DatePopoverControl, field !== self { fields.append(field) }
            view.subviews.forEach(collect)
        }
        collect(window)
        return fields
    }

    private func nearestViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}

/// The popover's content: Apple's calendar or wheels at their own size.
final class DatePopoverController: UIViewController, UIPopoverPresentationControllerDelegate {
    let picker = UIDatePicker()

    override func viewDidLoad() {
        super.viewDidLoad()
        picker.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: view.topAnchor),
            picker.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            picker.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        if picker.preferredDatePickerStyle == .inline {
            // Apple's calendar, at the width it is laid out for on iPhone.
            let fitted = picker.systemLayoutSizeFitting(
                CGSize(width: 320, height: 0),
                withHorizontalFittingPriority: .required,
                verticalFittingPriority: .fittingSizeLevel
            )
            preferredContentSize = CGSize(width: 320, height: fitted.height > 200 ? fitted.height : 360)
        } else {
            let fitted = picker.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            preferredContentSize = CGSize(
                width: max(fitted.width, 240),
                height: fitted.height > 100 ? fitted.height : 216
            )
        }
    }

    /// A popover on iPhone too, not a sheet.
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }
}
