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
struct ProfileView: View {
    private enum LegalPage: String, Identifiable {
        case privacy
        case support
        case deletion

        var id: String { rawValue }
    }

    @EnvironmentObject private var session: SessionStore
    @AppStorage("sukavina.appearanceMode") private var appearanceMode = AppAppearanceMode.system.rawValue
    @AppStorage("sukavina.attendanceMonthDisplayMode") private var attendanceMonthDisplayMode = AttendanceMonthDisplayMode.compact.rawValue
    @State private var showDelete = false
    @State private var showPasswordChange = false
    @State private var showPasswordChangeLimit = false
    @State private var legalPage: LegalPage?
    @State private var showSignOutConfirmation = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 22) {
                    PortalPageTitle("Tài khoản")
                    ZStack {
                        Circle().fill(AppTheme.red.opacity(0.18)).frame(width: 96, height: 96)
                        Text(initials).font(.title.bold()).foregroundColor(AppTheme.red)
                    }
                    Text(session.profile?.name ?? "Nhân viên").font(.title2.bold())
                    Text(session.profile?.employeeCode ?? "").font(.subheadline.monospaced()).foregroundColor(AppTheme.muted)

                    accountSectionTitle("THÔNG TIN TÀI KHOẢN")
                    VStack(spacing: 0) {
                        ProfileLine(label: "Vai trò", value: session.profile?.role ?? "")
                        Divider().padding(.leading, 18)
                        ProfileLine(label: "Loại tài khoản", value: accountType)
                    }
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                    accountSectionTitle("GIAO DIỆN")
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 9) {
                            Label("Chế độ hiển thị", systemImage: "circle.lefthalf.filled")
                                .font(.headline)
                            Text("Chọn giao diện sáng, tối hoặc theo cài đặt hệ thống.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                            Picker("Chế độ hiển thị", selection: $appearanceMode) {
                                ForEach(AppAppearanceMode.allCases) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        Divider()

                        VStack(alignment: .leading, spacing: 9) {
                            Label("Xem chấm công tháng", systemImage: "calendar")
                                .font(.headline)
                            Text("Bản đầy đủ hiển thị giờ vào và giờ ra ngay trong từng ô ngày.")
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                            Picker("Xem chấm công tháng", selection: $attendanceMonthDisplayMode) {
                                ForEach(AttendanceMonthDisplayMode.allCases) { mode in
                                    Text(mode.title).tag(mode.rawValue)
                                }
                            }
                            .pickerStyle(.segmented)
                        }
                    }
                    .padding(18)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    accountSectionTitle("BẢO MẬT")
                    Button {
                        if !isDemoAccount && !session.hasLinkedEmail { session.presentMissingEmailForPasswordChange() }
                        else if !isDemoAccount && passwordChangedThisMonth { showPasswordChangeLimit = true }
                        else { showPasswordChange = true }
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "key.fill").foregroundColor(AppTheme.red).frame(width: 30)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Đổi mật khẩu").font(.headline).foregroundColor(.primary)
                                Text(passwordChangeDescription)
                                    .font(.caption).foregroundColor(AppTheme.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").foregroundColor(AppTheme.muted)
                        }.padding(18)
                    }
                    .buttonStyle(.plain)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    HStack(spacing: 14) {
                        Image(systemName: session.biometricIcon)
                            .font(.title3)
                            .foregroundColor(AppTheme.red)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Đăng nhập bằng \(session.biometricName)")
                                .font(.headline)
                            Text("Dùng sinh trắc học thay cho mật khẩu ở lần đăng nhập sau.")
                                .font(.caption)
                                .foregroundColor(AppTheme.muted)
                        }
                        Spacer(minLength: 8)
                        Toggle("", isOn: Binding(
                            get: { session.biometricsEnabled },
                            set: { enabled in
                                Task { await session.setBiometricLogin(enabled: enabled) }
                            }
                        ))
                        .labelsHidden()
                        .tint(AppTheme.red)
                    }
                    .padding(18)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    accountSectionTitle("QUYỀN RIÊNG TƯ & HỖ TRỢ")
                    VStack(spacing: 0) {
                        Button {
                            legalPage = .privacy
                        } label: {
                            accountLink(icon: "hand.raised.fill", title: "Chính sách quyền riêng tư", opensExternally: false)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 58)
                        Button {
                            legalPage = .support
                        } label: {
                            accountLink(icon: "questionmark.circle.fill", title: "Hỗ trợ người dùng", opensExternally: false)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 58)
                        Button {
                            legalPage = .deletion
                        } label: {
                            accountLink(icon: "person.crop.circle.badge.minus", title: "Hướng dẫn xóa tài khoản", opensExternally: false)
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading, 58)
                        Button {
                            guard let settingsURL = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
                            UIApplication.shared.open(settingsURL)
                        } label: {
                            accountLink(icon: "bell.badge.fill", title: "Cài đặt thông báo")
                        }
                        .buttonStyle(.plain)
                    }
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                    accountSectionTitle("PHIÊN ĐĂNG NHẬP")
                    Button {
                        showSignOutConfirmation = true
                    } label: {
                        Label("Đăng xuất", systemImage: "rectangle.portrait.and.arrow.right")
                            .font(.headline)
                            .foregroundColor(AppTheme.red)
                    }
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 16))

                    if (session.profile?.protected != true || session.profile?.employeeCode == "DEMO") && session.profile?.accountType != "SUPER_ADMIN" {
                        accountSectionTitle("VÙNG NGUY HIỂM")
                        Button("Yêu cầu xóa tài khoản", role: .destructive) { showDelete = true }
                            .font(.footnote.weight(.semibold))
                    }
                }
                .padding(20)
                .padding(.bottom, 90)
            }
            .hidesPortalBottomScrollEdgeEffect()
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .alert("Xóa tài khoản vĩnh viễn?", isPresented: $showDelete) {
                Button("Hủy", role: .cancel) {}
                Button("Xóa vĩnh viễn", role: .destructive) {
                    Task { _ = await session.deleteAccount() }
                }
            } message: {
                Text("Thao tác này không thể hoàn tác. Tài khoản, dữ liệu cá nhân, đơn từ, lựa chọn món và dữ liệu ứng dụng liên quan sẽ bị xóa. Hồ sơ chấm công hoặc hồ sơ lao động bắt buộc có thể vẫn được lưu theo chính sách Công ty.")
            }
        }
        .navigationViewStyle(.stack)
        .sheet(isPresented: $showPasswordChange) {
            PasswordChangeView().environmentObject(session)
        }
        .sheet(item: $legalPage) { page in
            NativeLegalView(page: {
                switch page {
                case .privacy: return .privacy
                case .support: return .support
                case .deletion: return .deletion
                }
            }())
        }
        .alert("Chưa thể đổi mật khẩu", isPresented: $showPasswordChangeLimit) {
            Button("Đã hiểu", role: .cancel) {}
        } message: {
            Text("Bạn chỉ được đổi mật khẩu một lần mỗi tháng. Bạn có thể đổi lại từ ngày 01/\(nextPasswordChangeMonth).")
        }
        .alert("Xác nhận đăng xuất?", isPresented: $showSignOutConfirmation) {
            Button("Hủy", role: .cancel) {}
            Button("Đăng xuất", role: .destructive) { session.signOut() }
        } message: {
            Text("Bạn sẽ cần đăng nhập lại để tiếp tục sử dụng Sukavina trên thiết bị này.")
        }
    }

    private var initials: String {
        let words = (session.profile?.name ?? "NV").split(separator: " ")
        return words.suffix(2).compactMap(\.first).map(String.init).joined().uppercased()
    }
    private var accountType: String {
        switch session.profile?.accountType {
        case "SUPER_ADMIN": return "Quản trị viên tổng"
        case "ADMIN": return "Quản trị viên"
        default: return "Nhân viên"
        }
    }
    private var passwordChangedThisMonth: Bool {
        if isAdminAccount { return false }
        guard let changedAt = session.profile?.passwordChangedAt else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        return calendar.isDate(changedAt, equalTo: Date(), toGranularity: .month)
    }
    private var isAdminAccount: Bool {
        session.profile?.accountType == "ADMIN" || session.profile?.accountType == "SUPER_ADMIN"
    }
    private var isDemoAccount: Bool {
        session.profile?.accountType == "DEMO" || session.profile?.employeeCode.uppercased() == "DEMO"
    }

    private var passwordChangeDescription: String {
        isDemoAccount
            ? "Xác nhận bằng mật khẩu hiện tại, không giới hạn số lần đổi."
            : isAdminAccount
            ? "Xác thực OTP qua email, không giới hạn số lần đổi."
            : "Xác thực OTP qua email, tối đa một lần mỗi tháng."
    }
    private func accountSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .tracking(1.2)
            .foregroundColor(AppTheme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 2)
    }
    private func accountLink(icon: String, title: String, opensExternally: Bool = true) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).foregroundColor(AppTheme.red).frame(width: 26)
            Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
            Spacer()
            Image(systemName: opensExternally ? "arrow.up.right" : "chevron.right")
                .font(.caption.bold())
                .foregroundColor(AppTheme.muted)
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 52)
    }
    private var nextPasswordChangeMonth: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh") ?? .current
        let next = calendar.date(byAdding: .month, value: 1, to: Date()) ?? Date()
        return next.formatted(.dateTime.month(.twoDigits).year())
    }
}

@available(iOS 17.0, *)
struct NativeLegalView: View {
    enum Page {
        case privacy
        case support
        case deletion
    }

    @Environment(\.dismiss) private var dismiss
    let page: Page

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(AppTheme.red.opacity(0.15))
                            .frame(width: 62, height: 62)
                        Image(systemName: page == .privacy ? "hand.raised.fill" : page == .support ? "questionmark.bubble.fill" : "person.crop.circle.badge.minus")
                            .font(.title2)
                            .foregroundColor(AppTheme.red)
                    }
                    Text(page == .privacy ? "Quyền riêng tư tại Sukavina" : page == .support ? "Chúng tôi có thể hỗ trợ gì?" : "Kiểm soát tài khoản của bạn")
                        .font(.title2.bold())
                    Text(page == .privacy ? "Cập nhật lần cuối: 29/07/2026" : page == .support ? "Hỗ trợ dành riêng cho nhân viên Sukavina" : "Hướng dẫn dành cho tài khoản nội bộ")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.muted)

                    if page == .privacy {
                        legalSection("Ứng dụng nội bộ", "Sukavina chỉ dành cho nhân viên và người được Công ty ủy quyền. Tài khoản do Công ty tạo, cấp và quản lý; ứng dụng không có đăng ký công khai.")
                        legalSection("Dữ liệu được xử lý", "Hệ thống xử lý hồ sơ công việc, thông tin liên hệ, chấm công, đơn từ, lựa chọn suất ăn, thông báo và dữ liệu bảo mật cần thiết để vận hành.")
                        legalSection("Không quảng cáo hoặc theo dõi", "Sukavina không hiển thị quảng cáo, không bán dữ liệu và không theo dõi người dùng giữa các ứng dụng hoặc website. Ứng dụng không truy cập vị trí, danh bạ, camera hoặc micro.")
                        legalSection("Sinh trắc học", "Face ID và Touch ID được xử lý trên thiết bị. Sukavina chỉ nhận kết quả xác thực, không nhận hoặc lưu khuôn mặt, vân tay hay mẫu sinh trắc học.")
                        legalSection("Lưu trữ và quyền của nhân viên", "Dữ liệu được bảo vệ bằng HTTPS và giới hạn truy cập theo tài khoản. Nhân viên có thể yêu cầu xem, sửa hoặc xóa dữ liệu trong phạm vi cho phép; hồ sơ bắt buộc có thể được lưu theo quy định.")
                    } else if page == .support {
                        legalSection("Liên hệ hỗ trợ", "Email: group@sukavina.com")
                        legalSection("Khi báo lỗi", "Vui lòng cung cấp mã nhân viên, mô tả sự cố, thời điểm xảy ra và ảnh chụp màn hình nếu có.")
                        legalSection("Bảo vệ tài khoản", "Không gửi mật khẩu hoặc mã OTP cho bất kỳ ai, kể cả khi yêu cầu hỗ trợ.")
                        legalSection("Xóa tài khoản", "Bạn có thể gửi yêu cầu trong tab Tài khoản. Nếu không thể đăng nhập, hãy gửi yêu cầu từ email đã liên kết tới group@sukavina.com.")
                    } else {
                        legalSection("Xóa trong ứng dụng", "Quay lại tab Tài khoản, chọn “Yêu cầu xóa tài khoản” ở cuối trang, đọc kỹ cảnh báo rủi ro và xác nhận thao tác.")
                        legalSection("Không thể đăng nhập", "Gửi yêu cầu từ email đã liên kết tới group@sukavina.com. Hãy cung cấp họ tên và mã nhân viên, không gửi mật khẩu hoặc mã OTP.")
                        legalSection("Dữ liệu được xử lý", "Tài khoản ứng dụng và dữ liệu không còn cần thiết sẽ bị xóa. Hồ sơ lao động, chấm công hoặc dữ liệu bắt buộc có thể được giữ theo chính sách Công ty và quy định áp dụng.")
                        legalSection("Lưu ý", "Xóa tài khoản là thao tác không thể hoàn tác. Hãy liên hệ Nhân sự nếu bạn chỉ cần sửa thông tin hồ sơ.")
                    }
                }
                .padding(22)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle(page == .privacy ? "Chính sách quyền riêng tư" : page == .support ? "Hỗ trợ" : "Xóa tài khoản")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Đóng") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundColor(AppTheme.red)
                }
            }
        }
    }

    private func legalSection(_ title: String, _ content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(content)
                .font(.subheadline)
                .foregroundColor(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

@available(iOS 17.0, *)
struct PasswordChangeView: View {
    @EnvironmentObject private var session: SessionStore
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var otpSent = false
    @State private var completed = false
    @State private var attemptedSubmit = false

    private var isDemoAccount: Bool {
        session.profile?.accountType == "DEMO" || session.profile?.employeeCode.uppercased() == "DEMO"
    }

    private var currentPasswordError: String? {
        guard isDemoAccount,
              let message = session.passwordChangeError,
              message.localizedCaseInsensitiveContains("Mật khẩu hiện tại") else { return nil }
        return message
    }

    private var reusedPasswordError: String? {
        guard isDemoAccount,
              let message = session.passwordChangeError,
              message.localizedCaseInsensitiveContains("Mật khẩu mới phải khác") else { return nil }
        return message
    }

    private var regularAccountError: String? {
        guard !isDemoAccount else { return nil }
        return session.passwordChangeError
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(AppTheme.red.opacity(0.14)).frame(width: 58, height: 58)
                            Image(systemName: "key.fill").font(.title2).foregroundColor(AppTheme.red)
                        }
                        Text("Bảo vệ tài khoản").font(.title2.bold())
                        Text(isDemoAccount
                             ? "Nhập mật khẩu hiện tại trước khi thiết lập mật khẩu mới."
                             : "Xác minh email trước khi thiết lập mật khẩu mới.")
                            .font(.subheadline).foregroundColor(AppTheme.muted)
                    }

                    if !isDemoAccount { HStack(spacing: 10) {
                        stepBadge(number: 1, title: "Nhận OTP", active: true)
                        Rectangle().fill(otpSent ? AppTheme.red : AppTheme.fieldBorder).frame(height: 2)
                        stepBadge(number: 2, title: "Mật khẩu mới", active: otpSent)
                    } }

                    if !isDemoAccount { VStack(alignment: .leading, spacing: 14) {
                        Label(otpSent ? "OTP đã gửi tới \(email)" : (isDemoAccount ? "Xác minh qua Thông báo" : "Xác minh qua email"), systemImage: isDemoAccount ? "bell.badge.fill" : "envelope.badge.fill")
                            .font(.headline).foregroundColor(AppTheme.red)
                        Text(otpSent
                             ? "Mã gồm 6 số và có hiệu lực trong 10 phút."
                             : (isDemoAccount
                                ? "Mã OTP giả định sẽ được gửi vào mục Thông báo và có hiệu lực trong 10 phút."
                                : "Mã OTP sẽ được gửi tới email liên kết. Nếu chưa có email, vui lòng liên hệ Nhân sự để cập nhật."))
                            .font(.subheadline).foregroundColor(AppTheme.muted)
                    }
                    .padding(18).background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 20).stroke(AppTheme.cardBorder)) }

                    if otpSent || isDemoAccount {
                        VStack(spacing: 14) {
                            if isDemoAccount {
                                NativeSecureField(title: "Mật khẩu hiện tại", text: $currentPassword)
                                    .onChange(of: currentPassword) { _ in session.clearPasswordChangeError() }
                                if attemptedSubmit && currentPassword.isEmpty {
                                    validationMessage("Vui lòng nhập mật khẩu hiện tại.")
                                }
                                if let currentPasswordError {
                                    Label(currentPasswordError, systemImage: "exclamationmark.circle.fill")
                                        .font(.caption).foregroundColor(AppTheme.red).frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else {
                                NativeField(title: "Mã OTP gồm 6 số", text: $code, icon: "number", keyboard: .numberPad, textContentType: .oneTimeCode)
                                    .onChange(of: code) { _, value in
                                        code = String(value.filter(\.isNumber).prefix(6))
                                        session.clearPasswordChangeError()
                                    }
                                if attemptedSubmit && code.count != 6 {
                                    validationMessage("Mã OTP phải gồm đủ 6 chữ số.")
                                }
                            }
                            NativeSecureField(title: "Mật khẩu mới, ít nhất 6 ký tự gồm chữ và số", text: $newPassword)
                                .onChange(of: newPassword) { _ in session.clearPasswordChangeError() }
                            if let reusedPasswordError {
                                Label(reusedPasswordError, systemImage: "exclamationmark.circle.fill")
                                    .font(.caption).foregroundColor(AppTheme.red).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            NativeSecureField(title: "Nhập lại mật khẩu mới", text: $confirmPassword)
                            if attemptedSubmit && newPassword != confirmPassword {
                                validationMessage("Mật khẩu nhập lại không khớp.")
                            }
                            if attemptedSubmit, let passwordRuleError {
                                validationMessage(passwordRuleError)
                            }
                            if let regularAccountError {
                                Label(regularAccountError, systemImage: "exclamationmark.circle.fill")
                                    .font(.caption).foregroundColor(AppTheme.red).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(18).background(AppTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }

                    Button {
                        attemptedSubmit = true
                        if isDemoAccount {
                            guard canConfirm else { return }
                            Task {
                                if await session.confirmPasswordChange(currentPassword: currentPassword, newPassword: newPassword) { completed = true }
                            }
                        } else if otpSent {
                            guard canConfirm else { return }
                            Task {
                                if await session.confirmPasswordChange(code: code, newPassword: newPassword) { completed = true }
                            }
                        } else {
                            Task {
                                if let response = await session.requestPasswordChange() {
                                    email = response.email
                                    otpSent = true
                                }
                            }
                        }
                    } label: {
                        HStack {
                            if session.isWorking { ProgressView().tint(.white) }
                            Text(isDemoAccount || otpSent ? "Xác nhận đổi mật khẩu" : "Gửi mã OTP").fontWeight(.bold)
                            Spacer()
                            Image(systemName: isDemoAccount || otpSent ? "checkmark.shield.fill" : "arrow.right")
                        }.padding(.horizontal, 18).frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.plain).foregroundColor(.white).background(AppTheme.red)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .disabled(session.isWorking)
                    .opacity(session.isWorking ? 0.55 : 1)
                }
                .padding(22)
            }
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("Đổi mật khẩu")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Đóng") { dismiss() } } }
            .alert("Đổi mật khẩu thành công", isPresented: $completed) {
                Button("Hoàn tất") { dismiss() }
            }
        }.navigationViewStyle(.stack)
    }

    private var canConfirm: Bool {
        (isDemoAccount ? !currentPassword.isEmpty : (code.count == 6 && code.allSatisfy(\.isNumber))) &&
            isPasswordValid && newPassword == confirmPassword
    }

    private var isPasswordValid: Bool {
        newPassword.count >= 6 &&
            newPassword.rangeOfCharacter(from: .letters) != nil &&
            newPassword.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private var passwordRuleError: String? {
        if newPassword.count < 6 { return "Mật khẩu phải có ít nhất 6 ký tự." }
        if newPassword.rangeOfCharacter(from: .letters) == nil { return "Mật khẩu phải có ít nhất một chữ cái." }
        if newPassword.rangeOfCharacter(from: .decimalDigits) == nil { return "Mật khẩu phải có ít nhất một chữ số." }
        return nil
    }

    private func validationMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle.fill")
            .font(.caption)
            .foregroundColor(AppTheme.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func stepBadge(number: Int, title: String, active: Bool) -> some View {
        HStack(spacing: 7) {
            Text("\(number)").font(.caption.bold()).foregroundColor(active ? .white : AppTheme.muted)
                .frame(width: 25, height: 25).background(active ? AppTheme.red : AppTheme.field)
                .clipShape(Circle())
            Text(title).font(.caption.weight(.semibold)).foregroundColor(active ? .primary : AppTheme.muted)
        }.fixedSize()
    }
}

@available(iOS 17.0, *)
struct ProfileLine: View {
    let label: String
    let value: String
    var body: some View {
        HStack {
            Text(label).foregroundColor(AppTheme.muted)
            Spacer()
            Text(value).fontWeight(.medium)
        }.padding(18)
    }
}

@available(iOS 17.0, *)
struct NativeField: View {
    let title: String
    @Binding var text: String
    let icon: String
    var keyboard: UIKeyboardType = .default
    var textContentType: UITextContentType? = nil

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundColor(AppTheme.muted)
            TextField(title, text: $text)
                .keyboardType(keyboard)
                .textContentType(textContentType)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(AppTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AppTheme.fieldBorder, lineWidth: 1))
    }
}

@available(iOS 17.0, *)
struct NativeSecureField: View {
    let title: String
    @Binding var text: String
    @State private var visible = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock").frame(width: 22).foregroundColor(AppTheme.muted)
            Group {
                if visible { TextField(title, text: $text) }
                else { SecureField(title, text: $text) }
            }
            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye")
            }.foregroundColor(AppTheme.muted)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .background(AppTheme.field)
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(AppTheme.fieldBorder, lineWidth: 1))
    }
}

extension String {
    var safeHTMLText: String {
        let maximumCharacters = 750_000
        var output = String()
        output.reserveCapacity(Swift.min(count, maximumCharacters))
        var tag = String()
        var isInsideTag = false
        var written = 0

        for character in self {
            if written >= maximumCharacters {
                output.append("\n\n[Nội dung đã được rút gọn để bảo đảm ứng dụng hoạt động ổn định.]")
                break
            }
            if character == "<" {
                isInsideTag = true
                tag.removeAll(keepingCapacity: true)
                continue
            }
            if isInsideTag {
                if character == ">" {
                    isInsideTag = false
                    let name = tag.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                    if name.hasPrefix("br") || name.hasPrefix("/p") || name.hasPrefix("/div") ||
                        name.hasPrefix("/li") || name.hasPrefix("/h") || name.hasPrefix("hr") {
                        if output.last != "\n" { output.append("\n") }
                    } else if name.hasPrefix("/td") || name.hasPrefix("/th") {
                        output.append(" | ")
                    } else if name.hasPrefix("li") {
                        if output.last != "\n" { output.append("\n") }
                        output.append("• ")
                    }
                } else if tag.count < 80 {
                    tag.append(character)
                }
                continue
            }
            output.append(character)
            written += 1
        }

        let decoded = output
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        var lines: [String] = []
        var previousWasEmpty = false
        for rawLine in decoded.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if !previousWasEmpty && !lines.isEmpty { lines.append("") }
                previousWasEmpty = true
            } else {
                lines.append(line)
                previousWasEmpty = false
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var readingChunks: [String] {
        let maximumChunkLength = 1_800
        var chunks: [String] = []
        for paragraph in components(separatedBy: "\n\n") where !paragraph.isEmpty {
            var remainder = paragraph[...]
            while remainder.count > maximumChunkLength {
                let tentativeEnd = remainder.index(remainder.startIndex, offsetBy: maximumChunkLength)
                let split = remainder[..<tentativeEnd].lastIndex(of: " ") ?? tentativeEnd
                chunks.append(String(remainder[..<split]))
                remainder = remainder[split...].drop(while: { $0 == " " })
            }
            if !remainder.isEmpty { chunks.append(String(remainder)) }
        }
        return chunks.isEmpty ? [self] : chunks
    }
}
