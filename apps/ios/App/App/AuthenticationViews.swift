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

struct AuthenticationView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            ZStack {
                // The login screen shares the app's flat ink surface in dark
                // mode; the branded light-mode gradient remains unchanged.
                Group {
                    if colorScheme == .dark {
                        AppTheme.ink
                    } else {
                        LinearGradient(
                            colors: [AppTheme.ink, AppTheme.loginAccent, AppTheme.ink],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                }
                .ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {
                        Image("LoginBrand")
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 248, maxHeight: 158)
                            .frame(maxWidth: .infinity)
                            .shadow(color: AppTheme.red.opacity(0.24), radius: 16, y: 8)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("SUKAVINA GROUP")
                                .font(.caption.weight(.bold))
                                .tracking(3.5)
                                .foregroundColor(.red.opacity(0.9))
                            Text("Chào mừng trở lại")
                                .font(.largeTitle.bold())
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
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

struct LoginForm: View {
    private enum LoginFocus: Hashable {
        case identifier
        case password
    }

    @EnvironmentObject private var session: SessionStore
    @State private var loginId = ""
    @State private var password = ""
    @State private var passwordVisible = false
    @State private var showsForgotPassword = false
    @FocusState private var focusedField: LoginFocus?

    private var canSubmit: Bool {
        !loginId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && !session.isWorking
    }

    private func submitLogin() {
        guard canSubmit else { return }
        Task { _ = await session.signIn(loginId: loginId, password: password) }
    }

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "person.text.rectangle").frame(width: 22).foregroundColor(AppTheme.muted)
                TextField("MSNV", text: $loginId)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focusedField, equals: .identifier)
                    .onSubmit { focusedField = .password }
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(AppTheme.field)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AppTheme.fieldBorder, lineWidth: 1))

            HStack(spacing: 12) {
                Image(systemName: "lock").frame(width: 22).foregroundColor(AppTheme.muted)
                Group {
                    if passwordVisible { TextField("Mật khẩu", text: $password) }
                    else { SecureField("Mật khẩu", text: $password) }
                }
                .textContentType(.password)
                .submitLabel(.go)
                .focused($focusedField, equals: .password)
                .onSubmit(submitLogin)
                Button { passwordVisible.toggle() } label: {
                    Image(systemName: passwordVisible ? "eye.slash" : "eye")
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundColor(AppTheme.muted)
                .accessibilityLabel(passwordVisible ? "Ẩn mật khẩu" : "Hiện mật khẩu")
            }
            .padding(.horizontal, 16)
            .frame(minHeight: 52)
            .background(AppTheme.field)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AppTheme.fieldBorder, lineWidth: 1))
            Button {
                submitLogin()
            } label: {
                HStack {
                    if session.isWorking { ProgressView().tint(.white) }
                    Text("Đăng nhập").fontWeight(.bold)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, minHeight: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundColor(.white)
            .background(AppTheme.red)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(!canSubmit)
            .opacity(loginId.isEmpty || password.isEmpty ? 0.55 : 1)

            HStack {
                Spacer()
                Button {
                    showsForgotPassword = true
                } label: {
                    Label("Quên mật khẩu?", systemImage: "key.horizontal.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(AppTheme.redText)
            }

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
        .sheet(isPresented: $showsForgotPassword) {
            ForgotPasswordView(initialEmployeeCode: loginId)
                .sessionEnvironment(session)
        }
    }
}

private struct ForgotPasswordView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var employeeCode: String
    @State private var otp = ""
    @State private var newPassword = ""
    @State private var confirmation = ""
    @State private var otpSent = false
    @State private var maskedEmail: String?
    @State private var completed = false
    @State private var attemptedSubmit = false
    @State private var formError: String?

    init(initialEmployeeCode: String) {
        _employeeCode = State(initialValue: initialEmployeeCode.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var passwordRuleError: String? { PasswordPolicy.problem(newPassword) }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: completed ? "checkmark.shield.fill" : "key.horizontal.fill")
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundColor(completed ? .green : AppTheme.red)
                        .frame(width: 52, height: 52)
                        .background((completed ? Color.green : AppTheme.red).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Text(completed ? "Đã đặt lại mật khẩu" : "Khôi phục mật khẩu")
                        .font(.title.bold())
                    Text(completed
                         ? "Bạn có thể đăng nhập bằng mật khẩu mới."
                         : "Nhập MSNV. Mã OTP sẽ được gửi tới email đã liên kết với tài khoản.")
                        .foregroundColor(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    if !completed {
                        NativeField(title: "MSNV", text: $employeeCode, icon: "person.text.rectangle")
                            .disabled(otpSent)
                            .onChange(of: employeeCode) { _, _ in formError = nil; session.clearForgotPasswordError() }

                        if otpSent {
                            if let maskedEmail {
                                Label("OTP đã gửi tới \(maskedEmail)", systemImage: "envelope.badge.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(AppTheme.redText)
                            }
                            NativeField(title: "Mã OTP gồm 6 số", text: $otp, icon: "number", keyboard: .numberPad, textContentType: .oneTimeCode)
                                .onChange(of: otp) { _, value in
                                    otp = String(value.filter(\.isNumber).prefix(6))
                                    formError = nil
                                    session.clearForgotPasswordError()
                                }
                            if attemptedSubmit && otp.count != 6 {
                                passwordRuleMessage("Mã OTP phải gồm đủ 6 chữ số.")
                            }
                            NativeSecureField(title: "Mật khẩu mới", text: $newPassword)
                                .onChange(of: newPassword) { _, _ in formError = nil; session.clearForgotPasswordError() }
                            if attemptedSubmit, let passwordRuleError { passwordRuleMessage(passwordRuleError) }
                            NativeSecureField(title: "Nhập lại mật khẩu mới", text: $confirmation)
                                .onChange(of: confirmation) { _, _ in formError = nil; session.clearForgotPasswordError() }
                            if attemptedSubmit && confirmation != newPassword {
                                passwordRuleMessage("Mật khẩu nhập lại không khớp.")
                            }
                        }

                        if let message = formError ?? session.forgotPasswordError {
                            passwordRuleMessage(message)
                        }

                        Button {
                            attemptedSubmit = true
                            formError = nil
                            session.clearForgotPasswordError()
                            Task {
                                if otpSent {
                                    guard otp.count == 6, passwordRuleError == nil, confirmation == newPassword else { return }
                                    if await session.confirmForgotPassword(employeeCode: employeeCode, code: otp, newPassword: newPassword) {
                                        completed = true
                                    }
                                } else if let response = await session.requestForgotPassword(employeeCode: employeeCode) {
                                    if let email = response.maskedEmail, !email.isEmpty {
                                        maskedEmail = email
                                        otpSent = true
                                        attemptedSubmit = false
                                    } else {
                                        formError = "Tài khoản chưa có email liên kết. Vui lòng liên hệ Nhân sự để cập nhật email."
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                if session.isWorking { ProgressView().tint(.white) }
                                Text(otpSent ? "Đặt lại mật khẩu" : "Gửi mã OTP").fontWeight(.bold)
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
                        .disabled(session.isWorking || employeeCode.isEmpty)
                        .opacity(session.isWorking || employeeCode.isEmpty ? 0.55 : 1)
                    } else {
                        Button("Trở lại đăng nhập") { dismiss() }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity, minHeight: 52)
                            .background(AppTheme.red)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
                .padding(22)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Đóng") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func passwordRuleMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundColor(AppTheme.redText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}
