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

/// Apple's compact DatePicker that keeps the full date ("Ngày 18 thg 10,
/// 2026", not "18/10/26").
///
/// debug.log proved three things about the compact DatePicker. A new one
/// is sized for today's date, whatever date it is given: 185pt for a date
/// and 259pt for a date and time, so a later, wider date did not fit and
/// was shortened (1.0.79: "Bắt đầu w=259 wanted=268" on Sunday). It is
/// right when it does show today. And a picker already on screen widens
/// itself when its date changes, by the employee or by code ("resize
/// w=189 wanted=188").
///
/// So this picker is never created with any date but now: it starts on
/// the current time, the date it is sized for, and moves to its real date
/// as soon as it appears, through the change that it handles correctly.
/// It is SwiftUI's own DatePicker throughout; nothing is drawn in its
/// place.
struct SystemCompactDatePicker: View {
    @Binding var selection: Date
    let mode: UIDatePicker.Mode
    var minimum: Date? = nil
    let accessibilityLabel: String

    /// What the picker shows: now at first, then always `selection`.
    @State private var shown = Date()
    /// Until the first move to `selection`, nothing the picker reports is
    /// the employee's choice (it may only clamp now into its range).
    @State private var synced = false

    var body: some View {
        picker
            .labelsHidden()
            .datePickerStyle(.compact)
            .environment(\.timeZone, VietnamTime.timeZone)
            .environment(\.calendar, VietnamTime.calendar)
            .environment(\.locale, VietnamTime.locale)
            .onAppear {
                synced = true
                if shown != selection { shown = selection }
            }
            .onChange(of: selection) { _, value in
                if shown != value { shown = value }
            }
    }

    private var components: DatePickerComponents {
        mode == .date ? .date : [.date, .hourAndMinute]
    }

    private var shownBinding: Binding<Date> {
        Binding(
            get: { shown },
            set: { value in
                shown = value
                if synced, value != selection { selection = value }
            }
        )
    }

    @ViewBuilder
    private var picker: some View {
        if let minimum {
            DatePicker(accessibilityLabel, selection: shownBinding, in: minimum..., displayedComponents: components)
        } else {
            DatePicker(accessibilityLabel, selection: shownBinding, displayedComponents: components)
        }
    }
}

/// Holds a compact UIDatePicker scaled to fill its bounds, so its whole
/// area, not just its small capsule, opens the picker. Put under a drawn
/// tile that takes no touches: the tile shows the value, a tap anywhere on
/// it opens Apple's own picker bubble. Used by the booking form on iOS 18
/// (MeetingBookingSheet) and iOS 17 (LegacyMeetingRoomsUIKit).
final class TileFillingPickerView: UIView {
    let picker = UIDatePicker()
    private var loggedLayout = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(picker)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let natural = naturalSize()
        guard natural.width > 0, natural.height > 0, bounds.width > 0, bounds.height > 0 else {
            picker.transform = .identity
            picker.frame = bounds
            return
        }
        picker.bounds = CGRect(origin: .zero, size: natural)
        picker.center = CGPoint(x: bounds.midX, y: bounds.midY)
        picker.transform = CGAffineTransform(
            scaleX: bounds.width / natural.width,
            y: bounds.height / natural.height
        )
    }

    /// The picker's own, unscaled size. Its `intrinsicContentSize` alone
    /// left the tile answering taps on a small capsule in its middle only,
    /// so it is first sized to fit, as UIKit sizes a compact picker; a
    /// height the size of a wheel (216pt) is not the compact one and is
    /// skipped. What was found is logged ("tilePicker.size").
    private func naturalSize() -> CGSize {
        picker.transform = .identity
        picker.sizeToFit()
        let fitted = picker.bounds.size
        let intrinsic = picker.intrinsicContentSize
        let natural: CGSize
        if fitted.width > 0, fitted.height > 0, fitted.height < 100 {
            natural = fitted
        } else if intrinsic.width > 0, intrinsic.height > 0, intrinsic.height < 100 {
            natural = intrinsic
        } else {
            natural = .zero
        }
        let line = "fitted=\(Int(fitted.width))x\(Int(fitted.height)) intrinsic=\(Int(intrinsic.width))x\(Int(intrinsic.height)) tile=\(Int(bounds.width))x\(Int(bounds.height))"
        if line != loggedLayout {
            loggedLayout = line
            UIFlowLog.record("tilePicker.size", line)
        }
        return natural
    }
}
