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
        picker.addTarget(context.coordinator, action: #selector(Coordinator.opened(_:)), for: .editingDidBegin)
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
        // A time alone has no long and short form.
        let longForm = mode == .time ? 0 : CompactDateWidthLog.fullWidth(of: selection, includesTime: mode != .date)
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

        /// Its bubble opens (logged; a keyboard left open stays).
        @objc func opened(_ picker: UIDatePicker) {
            UIFlowLog.record("datePicker.open", picker.accessibilityLabel ?? "")
        }
    }
}

/// A drawn time tile's whole area as a button that opens Apple's popover
/// with Apple's time wheels (`TimePopoverControl`). Put it in the tile's
/// `.overlay`; it is transparent. Only the hour and minute are taken from
/// the wheels; the day of `selection` stays.
struct TimePopoverButton: UIViewRepresentable {
    @Binding var selection: Date
    var minuteInterval = 1
    /// Earliest and latest time the wheels offer (on the day of `selection`).
    var minimum: Date? = nil
    var maximum: Date? = nil
    let accessibilityLabel: String
    /// What the tile shows ("06:30", "1 giờ 30 phút"), for VoiceOver.
    let accessibilityValue: String

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeUIView(context: Context) -> TimePopoverControl {
        let control = TimePopoverControl()
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        apply(to: control)
        return control
    }

    func updateUIView(_ control: TimePopoverControl, context: Context) {
        context.coordinator.selection = $selection
        apply(to: control)
    }

    private func apply(to control: TimePopoverControl) {
        control.name = accessibilityLabel
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

        @objc func changed(_ control: TimePopoverControl) {
            if selection.wrappedValue != control.date { selection.wrappedValue = control.date }
        }
    }
}

/// A transparent button over a whole drawn time tile (Bắt đầu, Thời lượng,
/// Giờ vào / Giờ ra). A tap anywhere on it opens Apple's popover from the
/// tile, holding Apple's time wheels (UIDatePicker); every turn of the
/// wheels is sent as `.valueChanged`, the hour and minute set on the day
/// of `date`. Used by SwiftUI (`TimePopoverButton`, iOS 18) and UIKit
/// (LegacyMeetingRoomsUIKit, iOS 17) alike.
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
///   a popover on iPhone), anchored to the tile.
/// - From an open popover, a tap on another time tile closes it at once
///   and opens that tile's: the other tiles pass touches through the
///   popover. A tap on its own tile or anywhere else only closes it, as
///   any popover.
/// - A tap on a tile while a popover is still closing opens the tile's
///   popover once the closing transition ends (its own completion, no
///   timer).
/// - A keyboard left open by a text field stays open.
/// - debug.log: timePopover.open / .switch / .afterClose / .close /
///   .blocked.
final class TimePopoverControl: UIControl {
    var name = "tile"
    var minuteInterval = 1
    var minimumDate: Date?
    var maximumDate: Date?
    /// The time shown, and the day the chosen hour and minute are set on.
    var date = Date() {
        didSet {
            if let wheels = popover?.picker, wheels.date != date { wheels.date = date }
        }
    }

    private weak var popover: TimePopoverController?

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
        guard let other = presented as? TimePopoverController else {
            // Something else is on screen (a confirmation): leave it be.
            UIFlowLog.record("timePopover.blocked", "\(name) presented=\(String(describing: type(of: presented)))")
            return
        }
        if other.isBeingDismissed {
            // Closing already, from a tap outside it a moment ago: open this
            // one the moment it is gone, so that tap is not lost.
            UIFlowLog.record("timePopover.afterClose", "\(other.sourceName) -> \(name)")
            other.transitionCoordinator?.animate(alongsideTransition: nil) { [weak self, weak presenter] _ in
                guard let self, let presenter, presenter.presentedViewController == nil else { return }
                self.present(from: presenter)
            }
            return
        }
        // Another tile's popover, let through to here: close it now, then
        // open this one, so one tap moves from tile to tile.
        UIFlowLog.record("timePopover.switch", "\(other.sourceName) -> \(name)")
        other.dismiss(animated: false) { [weak self, weak presenter] in
            guard let self, let presenter else { return }
            self.present(from: presenter)
        }
    }

    private func present(from presenter: UIViewController) {
        let controller = TimePopoverController(sourceName: name)
        let wheels = controller.picker
        wheels.datePickerMode = .time
        wheels.preferredDatePickerStyle = .wheels
        wheels.minuteInterval = minuteInterval
        wheels.timeZone = VietnamTime.timeZone
        wheels.calendar = VietnamTime.calendar
        wheels.locale = VietnamTime.locale
        wheels.minimumDate = minimumDate
        wheels.maximumDate = maximumDate
        wheels.date = date
        wheels.accessibilityLabel = accessibilityLabel
        wheels.addTarget(self, action: #selector(wheelsChanged(_:)), for: .valueChanged)

        controller.modalPresentationStyle = .popover
        if let popover = controller.popoverPresentationController {
            popover.sourceView = self
            popover.sourceRect = bounds
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = controller
            popover.passthroughViews = otherTimeTiles()
        }
        self.popover = controller
        presenter.present(controller, animated: true)
        UIFlowLog.record("timePopover.open", name)
    }

    @objc private func wheelsChanged(_ wheels: UIDatePicker) {
        let calendar = VietnamTime.calendar
        let time = calendar.dateComponents([.hour, .minute], from: wheels.date)
        let chosen = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: date) ?? date
        guard chosen != date else { return }
        date = chosen
        sendActions(for: .valueChanged)
    }

    /// The other time tiles on screen, which a tap may reach through this
    /// tile's popover.
    private func otherTimeTiles() -> [UIView] {
        guard let window else { return [] }
        var tiles: [UIView] = []
        func collect(_ view: UIView) {
            if let tile = view as? TimePopoverControl, tile !== self { tiles.append(tile) }
            view.subviews.forEach(collect)
        }
        collect(window)
        return tiles
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

/// The popover's content: Apple's time wheels at their own size.
final class TimePopoverController: UIViewController, UIPopoverPresentationControllerDelegate {
    let picker = UIDatePicker()
    let sourceName: String

    init(sourceName: String) {
        self.sourceName = sourceName
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

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
        let fitted = picker.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        preferredContentSize = CGSize(
            width: max(fitted.width, 240),
            height: fitted.height > 100 ? fitted.height : 216
        )
    }

    /// A popover on iPhone too, not a sheet.
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
        .none
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        UIFlowLog.record("timePopover.close", sourceName)
    }
}
