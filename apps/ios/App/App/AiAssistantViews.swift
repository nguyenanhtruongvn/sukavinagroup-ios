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

struct AiAssistantMessage: Identifiable {
    let id = UUID()
    let role: String
    let content: String
    let contextID: String?

    var isUser: Bool { role.lowercased() == "user" }
}

struct AiAssistantOrbView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            sphere
            // Only the moving layers are redrawn each frame. The timeline
            // stops with Reduce Motion and whenever the app is not active
            // (scenePhase is fed by ScenePhaseBridge in AppDelegate).
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion || scenePhase != .active)) { timeline in
                motionLayers(seconds: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Static glass sphere with its glow, drawn once.
    private var sphere: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 0.98, green: 1.0, blue: 1.0),
                        Color(red: 0.77, green: 0.93, blue: 1.0),
                        Color(red: 0.42, green: 0.67, blue: 0.91),
                        Color(red: 0.31, green: 0.39, blue: 0.69),
                        Color(red: 0.14, green: 0.20, blue: 0.43)
                    ],
                    center: .topLeading,
                    startRadius: 0,
                    endRadius: size * 0.56
                )
            )
            .frame(width: size * 0.80, height: size * 0.80)
            .overlay {
                Circle()
                    .stroke(Color.cyan.opacity(0.34), lineWidth: max(0.7, size * 0.006))
                    .padding(size * 0.10)
            }
            .shadow(color: Color.cyan.opacity(0.22), radius: size * 0.13)
    }

    private func motionLayers(seconds: Double) -> some View {
        let turn = { (period: Double) in seconds.truncatingRemainder(dividingBy: period) / period }
        let coreAngle = turn(5.4) * Double.pi * 2
        let orbitAngle = turn(10.8) * 360
        let reverseAngle = -turn(14.8) * 360
        // Gentle breathing of the core and of the rings' brightness.
        let breath = (sin(turn(2.45) * Double.pi * 2) + 1) / 2
        let pulse = CGFloat(0.94 + breath * 0.08)
        let coreRadius = size * 0.065
        let coreOffset = CGSize(
            width: CGFloat(cos(coreAngle)) * coreRadius,
            height: CGFloat(sin(coreAngle)) * coreRadius
        )

        return ZStack {
            Ellipse()
                .stroke(Color.blue.opacity(0.36 + breath * 0.12), lineWidth: max(0.8, size * 0.012))
                .frame(width: size * 0.92, height: size * 0.43)
                .rotationEffect(.degrees(orbitAngle))

            Ellipse()
                .stroke(Color.cyan.opacity(0.28 + breath * 0.12), lineWidth: max(0.7, size * 0.009))
                .frame(width: size * 0.80, height: size * 0.58)
                .rotationEffect(.degrees(56 + reverseAngle))

            Ellipse()
                .stroke(Color.white.opacity(0.20), lineWidth: max(0.6, size * 0.006))
                .frame(width: size * 0.46, height: size * 0.78)
                .rotationEffect(.degrees(18 + orbitAngle * 0.35))

            // Core with its glow baked into the gradient (no per-frame shadow).
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            .white,
                            Color(red: 0.78, green: 0.96, blue: 1.0),
                            Color(red: 0.36, green: 0.84, blue: 0.98),
                            Color.cyan.opacity(0.32),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size * 0.17
                    )
                )
                .frame(width: size * 0.34 * pulse, height: size * 0.34 * pulse)
                .offset(coreOffset)

            Circle()
                .fill(Color.white.opacity(0.92))
                .frame(width: size * 0.032, height: size * 0.032)
                .offset(x: coreOffset.width - size * 0.012, y: coreOffset.height - size * 0.014)
        }
        .frame(width: size, height: size)
    }
}

struct AiAssistantTypingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.22)) { timeline in
            let activeDot = reduceMotion
                ? -1
                : Int((timeline.date.timeIntervalSinceReferenceDate / 0.28).rounded(.down)) % 3

            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(AppTheme.muted.opacity(index == activeDot ? 0.95 : 0.42))
                        .frame(width: 7, height: 7)
                        .scaleEffect(index == activeDot ? 1.18 : 0.86)
                        .offset(y: index == activeDot ? -2 : 0)
                        .animation(.easeInOut(duration: 0.18), value: activeDot)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppTheme.card)
            .clipShape(Capsule())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trợ lý AI đang nhập")
    }
}

struct AiAssistantInputField: UIViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    let onFocusChanged: (Bool) -> Void
    let onSend: () -> Void

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AiAssistantInputField

        init(parent: AiAssistantInputField) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text ?? ""
            parent.updateHeight(for: textView)
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChanged(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChanged(false)
        }

        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            if replacement == "\n" {
                parent.onSend()
                return false
            }
            return true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(frame: .zero)
        view.delegate = context.coordinator
        view.accessibilityLabel = "Nhập câu hỏi"
        view.returnKeyType = .send
        view.enablesReturnKeyAutomatically = true
        view.autocapitalizationType = .sentences
        view.autocorrectionType = .yes
        view.spellCheckingType = .default
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.showsVerticalScrollIndicator = false
        view.showsHorizontalScrollIndicator = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
        }
        updateHeight(for: uiView)
    }

    private func updateHeight(for textView: UITextView) {
        guard textView.bounds.width > 0 else { return }
        let measured = textView.sizeThatFits(
            CGSize(width: textView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        let nextHeight = min(max(measured, 42), 104)
        textView.isScrollEnabled = measured > 104

        guard abs(height - nextHeight) > 0.5 else { return }
        DispatchQueue.main.async {
            height = nextHeight
        }
    }
}

struct AiAssistantChatView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss

    @State private var messages: [AiAssistantMessage] = []
    @State private var draft = ""
    @State private var contextID: String?
    @State private var isLoadingHistory = true
    @State private var isSending = false
    @State private var historyLoaded = false
    @State private var inlineError: String?
    @State private var scrollToLatestRequest = 0
    @State private var isInputFocused = false
    @State private var inputHeight: CGFloat = 42

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        if isLoadingHistory {
                            ProgressView("Đang tải cuộc trò chuyện…")
                                .font(.footnote)
                                .foregroundStyle(AppTheme.muted)
                                .padding(.top, 28)
                        } else if messages.isEmpty {
                            VStack(spacing: 12) {
                                AiAssistantOrbView(size: 58)
                                Text("Bạn cần hỗ trợ gì?")
                                    .font(.headline)
                                Text("Hỏi về thông tin nội bộ Sukavina hoặc dữ liệu tài khoản của bạn.")
                                    .font(.subheadline)
                                    .foregroundStyle(AppTheme.muted)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 30)
                            .padding(.top, 38)
                        }

                        ForEach(messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }

                        if isSending {
                            HStack {
                                AiAssistantTypingIndicator()
                                Spacer()
                            }
                            .padding(.horizontal, 4)
                            .id("assistant-typing")
                        }

                        Color.clear
                            .frame(height: 1)
                            .id("assistant-bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(AppTheme.ink)
                .scrollDismissesKeyboard(.never)
                .onChange(of: messages.count) { _, _ in
                    scrollToLatest(using: proxy)
                }
                .onChange(of: isSending) { _, _ in
                    scrollToLatest(using: proxy)
                }
                .onChange(of: scrollToLatestRequest) { _, _ in
                    scrollToLatest(using: proxy)
                }
            }

            inputBar
                .onChange(of: inputHeight) { _, _ in
                    guard isInputFocused else { return }
                    requestScrollToLatest()
                }
        }
        .background(AppTheme.ink.ignoresSafeArea())
        .task { await loadHistoryIfNeeded() }
        .onChange(of: session.aiAssistantMobileEnabled) { _, enabled in
            if !enabled {
                UIFlowLog.record("sheet.selfDismiss", "dashboard.aiAssistant cause=assistantDisabled")
                dismiss()
            }
        }
        .interactiveDismissDisabled(isSending)
    }

    private var header: some View {
        HStack(spacing: 12) {
            AiAssistantOrbView(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Trợ lý AI")
                    .font(.headline)
                Text("Tra cứu nội bộ và thông tin của bạn")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 36, height: 36)
                    .background(Color.primary.opacity(0.07), in: Circle())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Đóng Trợ lý AI")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(AppTheme.card)
    }

    private var inputBar: some View {
        VStack(spacing: 7) {
            if let inlineError {
                Text(inlineError)
                    .font(.caption)
                    .foregroundStyle(AppTheme.redText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(alignment: .bottom, spacing: 10) {
                ZStack(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Nhập câu hỏi…")
                            .font(.body)
                            .foregroundStyle(Color.secondary.opacity(0.72))
                            .padding(.top, 10)
                            .allowsHitTesting(false)
                    }

                    AiAssistantInputField(
                        text: $draft,
                        height: $inputHeight,
                        onFocusChanged: { focused in
                            isInputFocused = focused
                            if focused {
                                requestScrollToLatest()
                            }
                        },
                        onSend: {
                            submitDraft()
                        }
                    )
                }
                .frame(height: inputHeight)
                .padding(.horizontal, 14)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                Button {
                    submitDraft()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 42, height: 42)
                        .background(canSend ? AppTheme.red : Color.secondary.opacity(0.35), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(!canSend)
                .accessibilityLabel("Gửi câu hỏi")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSending &&
        session.aiAssistantMobileEnabled
    }

    private var latestAssistantMessageID: UUID? {
        messages.last(where: { !$0.isUser })?.id
    }

    private func submitDraft() {
        guard canSend else { return }

        Task { @MainActor in
            await sendMessage()
            if isInputFocused {
                requestScrollToLatest()
            }
        }
    }

    private func requestScrollToLatest() {
        scrollToLatestRequest += 1

        // The visible chat height changes while the keyboard animates in.
        // Scroll once more after that resize so the newest bubble stays above
        // the keyboard instead of being hidden underneath it.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 280_000_000)
            guard isInputFocused else { return }
            scrollToLatestRequest += 1
        }
    }

    private func scrollToLatest(using proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.22)) {
            proxy.scrollTo("assistant-bottom", anchor: .bottom)
        }
    }

    @ViewBuilder
    private func messageBubble(_ message: AiAssistantMessage) -> some View {
        VStack(spacing: 4) {
            HStack(alignment: .bottom) {
                if message.isUser { Spacer(minLength: 54) }

                Text(message.content)
                    .font(.body)
                    .foregroundStyle(message.isUser ? Color.white : Color.primary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(message.isUser ? AppTheme.red : AppTheme.card)
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: 17,
                            bottomLeadingRadius: message.isUser ? 17 : 5,
                            bottomTrailingRadius: message.isUser ? 5 : 17,
                            topTrailingRadius: 17
                        )
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(
                        maxWidth: 300,
                        alignment: message.isUser ? .trailing : .leading
                    )
                    .textSelection(.enabled)

                if !message.isUser { Spacer(minLength: 54) }
            }
            if !message.isUser && message.id == latestAssistantMessageID && !isSending {
                Text("Trợ lý AI có thể mắc lỗi. Hãy kiểm tra thông tin quan trọng.")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @MainActor
    private func loadHistoryIfNeeded() async {
        guard !historyLoaded else { return }
        historyLoaded = true
        isLoadingHistory = true
        defer { isLoadingHistory = false }

        do {
            let history = try await session.loadAiAssistantHistory()
            messages = history.map {
                AiAssistantMessage(
                    role: $0.role,
                    content: $0.content,
                    contextID: $0.contextId
                )
            }
            contextID = history.reversed().compactMap { $0.contextId }.first
        } catch {
            inlineError = error.localizedDescription
        }
    }

    @MainActor
    private func sendMessage() async {
        let message = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !isSending, session.aiAssistantMobileEnabled else { return }

        inlineError = nil
        draft = ""
        messages.append(
            AiAssistantMessage(role: "user", content: message, contextID: contextID)
        )
        isSending = true
        defer { isSending = false }

        do {
            let response = try await session.askAiAssistant(
                message: message,
                contextID: contextID
            )
            if let newContext = response.contextId {
                contextID = newContext
            }
            messages.append(
                AiAssistantMessage(
                    role: "assistant",
                    content: response.answer,
                    contextID: response.contextId
                )
            )
        } catch {
            inlineError = error.localizedDescription
        }
    }
}
