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

#if DEBUG
@available(iOS 17.0, *)
struct SukavinaPreviewContainer: View {
    @StateObject private var session: SessionStore
    private let mode: SessionStore.State

    init(mode: SessionStore.State) {
        self.mode = mode
        let previewSession = SessionStore()
        previewSession.state = mode
        if mode == .signedIn {
            previewSession.profile = Profile(
                id: "preview", employeeCode: "SKV-001", name: "Nguyễn Văn A",
                role: "Nhân viên", accountType: "EMPLOYEE", permissions: [], protected: false,
                email: "preview@sukavinagroup.net", passwordChangedAt: nil
            )
            previewSession.dashboard = Dashboard(
                employeeCode: "SKV-001", fullName: "Nguyễn Văn A", role: "Nhân sự vận hành",
                remainingLeaveDays: 8, attendanceStatus: "Đã ghi nhận", payrollStatus: "Đã cập nhật",
                name: "Nguyễn Văn A", workStartTime: "07:30", workEndTime: "16:30",
                attendanceRecords: [], contentItems: []
            )
        }
        _session = StateObject(wrappedValue: previewSession)
    }

    var body: some View {
        Group {
            switch mode {
            case .restoring: NativeLaunchView()
            case .signedOut: AuthenticationView().environmentObject(session)
            case .signedIn: EmployeePortalView().environmentObject(session)
            }
        }
    }
}

@available(iOS 17.0, *)
struct SukavinaAppPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            SukavinaPreviewContainer(mode: .signedOut)
                .previewDisplayName("Đăng nhập")
            SukavinaPreviewContainer(mode: .signedIn)
                .previewDisplayName("Trang chủ nhân viên")
            SukavinaPreviewContainer(mode: .restoring)
                .previewDisplayName("Khởi động")
        }
    }
}
#endif
