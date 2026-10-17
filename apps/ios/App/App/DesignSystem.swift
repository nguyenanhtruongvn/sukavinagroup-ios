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
    /// For a compact `DatePicker` showing `day`: gives it the width its full
    /// date needs, so it shows "Ngày 18 thg 10, 2026" rather than "18/10/26".
    ///
    /// A compact picker chooses the long or the short date from the width it
    /// is given, and keeps its choice. Re-creating it on a new day alone did
    /// not stop "18/10/26" (1.0.75, attendance request), so its frame is now
    /// at least as wide as its long form, measured in the system font from
    /// the system's Vietnamese medium date, as the picker formats it.
    /// Nothing is drawn in its place: the date is still the picker's own.
    ///
    /// Still re-created on a new day, so a longer date is measured again.
    /// The picker's own width is logged (UIFlowLog "datePicker.width") next
    /// to the width it was given: a picker staying narrower than that did
    /// not take the room, which would show this does not reach it.
    ///
    /// Apply it to the picker alone, with `.labelsHidden()`, and lay it out
    /// in a `CompactDateRow` (or a fallback of its own) so the wider picker
    /// moves under its label instead of overflowing a narrow screen.
    func keepsFullCompactDate(day: Date, includesTime: Bool = false, logName: String) -> some View {
        modifier(FullCompactDate(
            day: VietnamTime.calendar.startOfDay(for: day),
            includesTime: includesTime,
            logName: logName
        ))
    }
}

extension EnvironmentValues {
    /// Where a `keepsFullCompactDate` picker sits in the room it is given:
    /// trailing beside a label, leading under one.
    var compactDateAlignment: Alignment {
        get { self[CompactDateAlignmentKey.self] }
        set { self[CompactDateAlignmentKey.self] = newValue }
    }
}

private struct CompactDateAlignmentKey: EnvironmentKey {
    static let defaultValue: Alignment = .trailing
}

/// See `View.keepsFullCompactDate`.
struct FullCompactDate: ViewModifier {
    let day: Date
    let includesTime: Bool
    let logName: String
    @Environment(\.compactDateAlignment) private var alignment

    func body(content: Content) -> some View {
        let wanted = Self.fullWidth(of: day, includesTime: includesTime)
        return content
            .id(day)
            // The picker's own size, inside the room it is given.
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { log(geometry.size.width, wanted: wanted, cause: "appear") }
                        .onChange(of: geometry.size.width) { _, width in log(width, wanted: wanted, cause: "resize") }
                }
            )
            .frame(minWidth: wanted, alignment: alignment)
    }

    /// The width of `day`'s long form as the compact picker draws it: each
    /// value in its own capsule of body text.
    static func fullWidth(of day: Date, includesTime: Bool) -> CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .body)
        func textWidth(_ text: String) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        // About 11pt of capsule padding a side, and a few points to spare
        // for the picker's own rounding.
        let capsule: CGFloat = 26
        var width = textWidth(longDate.string(from: day)) + capsule
        if includesTime {
            width += 8 + textWidth(VietnamTime.clock.string(from: day)) + capsule
        }
        return width
    }

    /// The system's medium date style in Vietnamese, the long form the
    /// picker shows when it has the room.
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

/// A label and a `keepsFullCompactDate` picker: side by side when the
/// picker's full width fits beside the label, the picker under the label
/// when it does not, never overflowing the row.
struct CompactDateRow<Picker: View>: View {
    let label: String
    @ViewBuilder let picker: () -> Picker

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                labelText
                Spacer(minLength: 8)
                picker()
            }
            VStack(alignment: .leading, spacing: 6) {
                labelText
                picker()
                    .environment(\.compactDateAlignment, .leading)
            }
        }
    }

    /// VoiceOver reads the picker's own label instead.
    private var labelText: some View {
        Text(label)
            .accessibilityHidden(true)
    }
}

extension View {
    /// Shows `content` in a popover pointing at this view, presented by UIKit
    /// rather than SwiftUI's `.popover`. Use it for popovers inside a sheet.
    ///
    /// SwiftUI's `.popover`, nested in a sheet, closed the sheet on the tap
    /// that opened it (request composer, debug.log on iOS 27). The app hosts
    /// its SwiftUI root in a UIHostingController that is a child of the root
    /// view controller (`AppDelegate.mountRootView`), and SwiftUI appears to
    /// present the popover from the controller already presenting the sheet,
    /// dismissing the sheet to make room; that mechanism is inferred, not
    /// traced. Here a child controller embedded in the sheet presents the
    /// popover, so UIKit presents it from the sheet; the sheet stayed open
    /// when tested on iOS 27.
    ///
    /// `logName` labels the popover in UIFlowLog.
    func anchoredPopover<Content: View>(
        isPresented: Binding<Bool>,
        logName: String,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        background(AnchoredPopover(isPresented: isPresented, logName: logName, content: content))
    }
}

/// See `View.anchoredPopover`.
struct AnchoredPopover<Content: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let logName: String
    let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let anchor = UIViewController()
        anchor.view.backgroundColor = .clear
        // Taps belong to the view in front of it.
        anchor.view.isUserInteractionEnabled = false
        return anchor
    }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.logName = logName
        coordinator.onDismiss = { isPresented = false }

        if let host = coordinator.host {
            if isPresented {
                // Keeps the popover showing the form's current values.
                host.rootView = content()
            } else {
                coordinator.host = nil
                host.dismiss(animated: true)
            }
            return
        }
        guard isPresented, !coordinator.waitingToPresent else { return }
        present(from: anchor, coordinator: coordinator)
    }

    /// Presents the popover now, or as soon as UIKit has finished fading out
    /// the previous one. The anchor drops its highlight as a fade starts
    /// (`presentationControllerWillDismiss`), so a quick second tap often
    /// lands mid-fade, when UIKit cannot present yet. Dropping that tap made
    /// the field look unresponsive; it now waits for the fade instead.
    private func present(from anchor: UIViewController, coordinator: Coordinator) {
        guard anchor.view.window != nil else {
            UIFlowLog.record("popover.skipped", "\(logName) notInWindow")
            DispatchQueue.main.async { isPresented = false }
            return
        }
        if let busy = anchor.presentedViewController {
            if busy.isBeingDismissed, let transition = busy.transitionCoordinator {
                UIFlowLog.record("popover.deferred", logName)
                coordinator.waitingToPresent = true
                transition.animate(alongsideTransition: nil) { [weak anchor] _ in
                    // Next turn of the run loop, once UIKit has let go of
                    // the old popover.
                    DispatchQueue.main.async {
                        coordinator.waitingToPresent = false
                        guard let anchor, isPresented, coordinator.host == nil else { return }
                        present(from: anchor, coordinator: coordinator)
                    }
                }
            } else {
                UIFlowLog.record("popover.skipped", "\(logName) busy")
                DispatchQueue.main.async { isPresented = false }
            }
            return
        }

        let host = UIHostingController(rootView: content())
        host.modalPresentationStyle = .popover
        host.preferredContentSize = host.sizeThatFits(in: CGSize(width: 360, height: 520))
        if let popover = host.popoverPresentationController {
            popover.sourceView = anchor.view
            popover.sourceRect = anchor.view.bounds
            popover.permittedArrowDirections = [.up, .down]
            popover.delegate = coordinator
        }
        coordinator.host = host
        UIFlowLog.record("popover.present", logName)
        anchor.present(host, animated: true)
    }

    static func dismantleUIViewController(_ anchor: UIViewController, coordinator: Coordinator) {
        coordinator.host?.dismiss(animated: false)
        coordinator.host = nil
    }

    @MainActor
    final class Coordinator: NSObject, UIPopoverPresentationControllerDelegate {
        var host: UIHostingController<Content>?
        /// A tap arrived while the previous popover was fading out; it
        /// presents when the fade ends. Keeps updates meanwhile from queuing
        /// it twice.
        var waitingToPresent = false
        var logName = ""
        var onDismiss: () -> Void = {}

        /// A popover on iPhone too, rather than the sheet UIKit adapts it to.
        func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
            .none
        }

        /// Tapping outside the popover closes it. The state is released here,
        /// as the fade starts: `presentationControllerDidDismiss` runs only
        /// once the fade has finished, which left the anchor highlighted for a
        /// visible beat after the popover was gone. A popover closed by a tap
        /// outside cannot be cancelled midway, unlike a swiped sheet.
        func presentationControllerWillDismiss(_ presentationController: UIPresentationController) {
            UIFlowLog.record("popover.willDismiss", logName)
            host = nil
            onDismiss()
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            UIFlowLog.record("popover.dismissed", logName)
        }
    }
}
