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

@available(iOS 17.0, *)
struct SukavinaAppView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = SessionStore()

    var body: some View {
        ZStack {
            Group {
                switch session.state {
                case .restoring:
                    NativeLaunchView()
                case .signedOut:
                    AuthenticationView()
                        .environmentObject(session)
                case .signedIn:
                    if session.profile?.accountType == "CANTEEN" && session.profile?.employeeCode != "DEMO" {
                        CanteenScannerView()
                            .environmentObject(session)
                    } else {
                        EmployeePortalView()
                            .environmentObject(session)
                    }
                }
            }

            if let message = session.errorMessage {
                Color.black.opacity(0.38)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { session.dismissError() }

                ElegantAppAlert(
                    title: session.errorTitle,
                    message: message,
                    offersSettings: session.errorOffersSettings,
                    dismiss: { session.dismissError() }
                )
                .padding(.horizontal, 22)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .task { await session.restore() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                session.appBecameActive()
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: session.errorMessage)
    }
}

@available(iOS 17.0, *)
struct ElegantAppAlert: View {
    let title: String
    let message: String
    let offersSettings: Bool
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(AppTheme.red.opacity(0.12))
                    Image(systemName: alertIcon)
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundColor(AppTheme.red)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text(message)
                        .font(.system(size: 14.5, weight: .regular))
                        .foregroundColor(AppTheme.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundColor(AppTheme.muted)
                        .frame(width: 30, height: 30)
                        .background(AppTheme.field)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Đóng")
            }

            if offersSettings {
                Button {
                    dismiss()
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                } label: {
                    Label("Mở Cài đặt", systemImage: "gearshape.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.plain)
                .foregroundColor(.white)
                .background(
                    LinearGradient(colors: [AppTheme.red, AppTheme.deepRed], startPoint: .leading, endPoint: .trailing)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            } else {
                Button(title == "Kiểm tra kết nối Internet" ? "Đóng" : "Đã hiểu", action: dismiss)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 48)
                    .background(AppTheme.red)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .buttonStyle(.plain)
            }
        }
        .padding(20)
        .adaptiveGlassSurface(cornerRadius: 24, tint: AppTheme.red.opacity(0.06))
        .shadow(color: .black.opacity(0.24), radius: 22, y: 10)
        .frame(maxWidth: 370)
    }

    private var alertIcon: String {
        if offersSettings { return "antenna.radiowaves.left.and.right.slash" }
        if title == "Kiểm tra kết nối Internet" { return "wifi.slash" }
        if title == "Cần cập nhật email" { return "envelope.badge.fill" }
        return "exclamationmark.shield.fill"
    }
}

@available(iOS 17.0, *)
struct NativeLaunchView: View {
    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            VStack(spacing: 20) {
                Image("AppIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 150, height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
                ProgressView().tint(AppTheme.red)
                Text("SUKAVINA")
                    .font(.caption.weight(.semibold))
                    .tracking(4)
                    .foregroundColor(AppTheme.muted)
            }
        }
    }
}

@available(iOS 17.0, *)
struct AuthenticationView: View {
    @EnvironmentObject private var session: SessionStore

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [AppTheme.ink, AppTheme.loginAccent, AppTheme.ink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ).ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("SUKAVINA GROUP")
                                .font(.caption.weight(.bold))
                                .tracking(3.5)
                                .foregroundColor(.red.opacity(0.9))
                            Text("Chào mừng trở lại")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                            Text("Thông tin công việc của bạn, trong một ứng dụng native gọn gàng.")
                                .foregroundColor(AppTheme.muted)
                        }

                        LoginForm()
                        .padding(20)
                        .background(AppTheme.card.opacity(0.96))
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 24, style: .continuous)
                                .stroke(AppTheme.cardBorder, lineWidth: 1)
                        )
                        .shadow(color: AppTheme.deepRed.opacity(0.14), radius: 24, y: 12)
                    }
                    .padding(22)
                }
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(.stack)
    }
}

@available(iOS 17.0, *)
struct LoginForm: View {
    @EnvironmentObject private var session: SessionStore
    @State private var loginId = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 16) {
            NativeField(title: "MSNV", text: $loginId, icon: "person.text.rectangle")
            NativeSecureField(title: "Mật khẩu", text: $password)
            Button {
                Task { _ = await session.signIn(loginId: loginId, password: password) }
            } label: {
                HStack {
                    if session.isWorking { ProgressView().tint(.white) }
                    Text("Đăng nhập").fontWeight(.bold)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .background(AppTheme.red)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(loginId.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || session.isWorking)
            .opacity(loginId.isEmpty || password.isEmpty ? 0.55 : 1)

            if session.biometricsEnabled {
                HStack(spacing: 12) {
                    Rectangle().fill(AppTheme.fieldBorder).frame(height: 1)
                    Text("hoặc").font(.caption).foregroundColor(AppTheme.muted)
                    Rectangle().fill(AppTheme.fieldBorder).frame(height: 1)
                }

                Button {
                    Task { _ = await session.signInWithBiometrics() }
                } label: {
                    Label("Đăng nhập bằng \(session.biometricName)", systemImage: session.biometricIcon)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.biometricForeground)
                .background(AppTheme.biometricFill)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(AppTheme.biometricForeground.opacity(0.22), lineWidth: 1)
                )
                .shadow(color: AppTheme.deepRed.opacity(0.08), radius: 10, y: 4)
                .disabled(session.isWorking)
            }
        }
    }
}

@available(iOS 17.0, *)
struct RegistrationForm: View {
    @State private var employeeCode = ""
    @State private var fullName = ""
    @State private var phone = ""
    @State private var email = ""
    @State private var password = ""
    @State private var isWorking = false
    @State private var verification: VerificationContext?
    @State private var message: String?

    var body: some View {
        VStack(spacing: 16) {
            NativeField(title: "Mã nhân viên", text: $employeeCode, icon: "number")
            NativeField(title: "Họ và tên", text: $fullName, icon: "person")
            NativeField(title: "Số điện thoại (không bắt buộc)", text: $phone, icon: "phone", keyboard: .phonePad)
            NativeField(title: "Địa chỉ Gmail", text: $email, icon: "envelope", keyboard: .emailAddress)
            NativeSecureField(title: "Mật khẩu từ 6 ký tự", text: $password)

            Button("Đăng ký và nhận mã") {
                Task { await register() }
            }
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundColor(.white)
            .background(AppTheme.red)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(!isValid || isWorking)
            .opacity(isValid ? 1 : 0.55)

            if let message {
                Text(message).font(.footnote).foregroundColor(AppTheme.muted)
            }
        }
        .sheet(item: $verification) { context in
            VerificationView(context: context)
        }
    }

    private var isValid: Bool {
        !employeeCode.trimmingCharacters(in: .whitespaces).isEmpty &&
        !fullName.trimmingCharacters(in: .whitespaces).isEmpty &&
        email.lowercased().hasSuffix("@gmail.com") && password.count >= 6
    }

    private func register() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result: RegistrationResponse = try await APIClient.shared.request(
                "auth/register",
                method: "POST",
                body: RegisterBody(
                    employeeCode: employeeCode,
                    fullName: fullName,
                    phoneNumber: phone.isEmpty ? nil : phone,
                    gmailEmail: email,
                    password: password
                )
            )
            message = result.message
            verification = VerificationContext(employeeCode: result.employeeCode, email: email.lowercased())
        } catch {
            message = error.localizedDescription
        }
    }
}

struct VerificationContext: Identifiable {
    let employeeCode: String
    let email: String
    var id: String { employeeCode + email }
}

@available(iOS 17.0, *)
struct VerificationView: View {
    let context: VerificationContext
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @State private var message: String
    @State private var isWorking = false

    init(context: VerificationContext) {
        self.context = context
        _message = State(initialValue: "Nhập mã gồm 6 chữ số đã gửi tới \(context.email).")
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                Image(systemName: "envelope.badge.shield.half.filled")
                    .font(.system(size: 48))
                    .foregroundColor(AppTheme.red)
                Text("Xác minh Gmail").font(.title.bold())
                Text(message).multilineTextAlignment(.center).foregroundColor(AppTheme.muted)
                TextField("000000", text: $code)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .padding()
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Button("Xác minh") { Task { await verify() } }
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .background(AppTheme.red)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .disabled(code.count != 6 || isWorking)
                Button("Gửi lại mã") { Task { await resend() } }
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(24)
            .background(AppTheme.ink.ignoresSafeArea())
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } } }
        }
    }

    private func verify() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result: MessageResponse = try await APIClient.shared.request(
                "auth/verify-email",
                method: "POST",
                body: VerifyBody(employeeCode: context.employeeCode, gmailEmail: context.email, code: code)
            )
            message = result.message
            code = ""
        } catch { message = error.localizedDescription }
    }

    private func resend() async {
        isWorking = true
        defer { isWorking = false }
        do {
            let result: MessageResponse = try await APIClient.shared.request(
                "auth/resend-verification",
                method: "POST",
                body: ResendBody(employeeCode: context.employeeCode, gmailEmail: context.email)
            )
            message = result.message
        } catch { message = error.localizedDescription }
    }
}
