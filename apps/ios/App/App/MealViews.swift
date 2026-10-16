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

struct MealQRCodeCard: View {
    let token: String
    // Rendered once per token. As a computed property the QR code (and a new
    // CIContext) was regenerated on every redraw, i.e. every countdown second.
    @State private var image: UIImage?

    private static let renderContext = CIContext()

    private static func makeImage(for token: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(token.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 9, y: 9)),
              let cgImage = renderContext.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    var body: some View {
        VStack(spacing: 10) {
            Text("MÃ QR NHẬN MÓN")
                .font(.caption.bold()).tracking(1.2).foregroundColor(AppTheme.muted)
            Group {
                if let image {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                } else {
                    Color.white
                }
            }
            .frame(width: 210, height: 210)
            .padding(12)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .task(id: token) { image = Self.makeImage(for: token) }
            Text("Đưa mã này cho nhân viên nhà ăn quét. Mã chỉ dùng cho suất ăn hôm nay.")
                .font(.caption).foregroundColor(AppTheme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct MealQRCodeAccessCard: View {
    // Only calls session methods: must not redraw on every session change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @State private var issued: MealQrIssueResponse?
    /// Wall-clock expiry for the countdown text, drawn by the system.
    @State private var expiresAt: Date?
    // Expiry on the continuous clock, used to hide the code. Decrementing a
    // counter after each one-second sleep drifted and stopped in the
    // background, so the code could stay on screen after it had expired.
    @State private var deadline: ContinuousClock.Instant?
    @State private var isExpiringSoon = false
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 12) {
            if let issued, let expiresAt {
                MealQRCodeCard(token: issued.token)
                // Text(timerInterval:) counts down on its own, like the Live
                // Activity: no per-second state update or app wake-up.
                (Text("Mã tự ẩn sau ") + Text(timerInterval: min(Date(), expiresAt)...expiresAt, countsDown: true))
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(isExpiringSoon ? .red : AppTheme.muted)
                    .monospacedDigit()
            } else {
                Button {
                    Task { await issueCode() }
                } label: {
                    HStack(spacing: 9) {
                        if isLoading { ProgressView().tint(.white) }
                        Image(systemName: "qrcode")
                        Text(isLoading ? "Đang tạo mã..." : "Lấy mã nhận món")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppTheme.red)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                Text("Mỗi mã chỉ có hiệu lực trong thời gian ngắn và sẽ thay đổi ở lần lấy tiếp theo.")
                    .font(.caption)
                    .foregroundColor(AppTheme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .task(id: issued?.token) {
            guard issued != nil, let deadline else { return }
            let clock = ContinuousClock()
            // Two wake-ups per code: turn the countdown red 5 s before expiry,
            // then hide the code.
            try? await Task.sleep(until: deadline - .seconds(5), clock: clock)
            guard !Task.isCancelled else { return }
            isExpiringSoon = true
            try? await Task.sleep(until: deadline, clock: clock)
            guard !Task.isCancelled else { return }
            issued = nil
            expiresAt = nil
            isExpiringSoon = false
        }
    }

    @MainActor
    private func issueCode() async {
        isLoading = true
        defer { isLoading = false }
        guard let response = await session.issueMealQRCode() else { return }
        let lifetime = max(1, response.expiresInSeconds)
        deadline = ContinuousClock.now + .seconds(lifetime)
        expiresAt = Date().addingTimeInterval(TimeInterval(lifetime))
        isExpiringSoon = lifetime <= 5
        issued = response
    }
}

struct CanteenScannerView: View {
    @EnvironmentObject private var session: SessionStore
    @State private var scanning = true
    @State private var result: MealScanResponse?

    var body: some View {
        ZStack {
            AppTheme.ink.ignoresSafeArea()
            VStack(spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("NHÀ ĂN SUKAVINA").font(.caption.bold()).tracking(1.4).foregroundColor(AppTheme.redText)
                        Text("Quét mã nhận món").font(.title2.bold())
                    }
                    Spacer()
                    if (session.profile?.employeeCode ?? "").uppercased() != "DEMO" {
                        Button("Đăng xuất") { session.signOut() }
                            .font(.subheadline.weight(.semibold)).foregroundColor(AppTheme.redText)
                    }
                }

                if let result {
                    VStack(spacing: 16) {
                        Image(systemName: result.alreadyReceived ? "exclamationmark.circle.fill" : "checkmark.seal.fill")
                            .font(.system(size: 54, weight: .bold))
                            .foregroundColor(result.alreadyReceived ? .orange : .green)
                        Text(result.alreadyReceived ? "Suất ăn đã được xác nhận" : "Xác nhận suất ăn thành công")
                            .font(.title3.bold()).multilineTextAlignment(.center)
                        VStack(spacing: 10) {
                            scannerResultLine("Nhân viên", result.fullName)
                            scannerResultLine("MSNV", result.employeeCode)
                            scannerResultLine("Phòng ban", result.department)
                            scannerResultLine("Loại món", result.choice == "water" ? "Món nước" : "Món chay")
                            scannerResultLine("Tên món", result.mealName?.isEmpty == false ? result.mealName! : "Chưa cập nhật")
                        }
                        .padding(16).background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 18))
                        Button {
                            self.result = nil
                            scanning = true
                        } label: {
                            Label("Quét mã tiếp theo", systemImage: "qrcode.viewfinder")
                                .font(.headline).foregroundColor(.white)
                                .frame(maxWidth: .infinity).padding(.vertical, 15)
                                .background(AppTheme.red).clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .padding(20)
                    .background(AppTheme.card.opacity(0.94))
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                } else {
                    QRScannerView(isActive: scanning) { code in
                        scanning = false
                        Task {
                            if let response = await session.scanMealQRCode(code) {
                                UINotificationFeedbackGenerator().notificationOccurred(
                                    response.alreadyReceived ? .warning : .success
                                )
                                result = response
                            } else {
                                try? await Task.sleep(for: .seconds(1))
                                scanning = true
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(AppTheme.red.opacity(0.75), lineWidth: 2)
                            .padding(36)
                    }
                    Text("Đưa camera vào mã QR trên điện thoại của người nhận món.")
                        .font(.subheadline).foregroundColor(AppTheme.muted).multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
        }
    }

    private func scannerResultLine(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundColor(AppTheme.muted); Spacer(); Text(value).fontWeight(.semibold) }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    let isActive: Bool
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> MealScannerViewController {
        let controller = MealScannerViewController()
        controller.onCode = onCode
        return controller
    }

    func updateUIViewController(_ controller: MealScannerViewController, context: Context) {
        controller.onCode = onCode
        controller.setScanning(isActive)
    }
}

final class MealScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    private let captureSession = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var configured = false
    private var handlingCode = false
    /// startRunning/stopRunning block for a noticeable time. Apple requires a
    /// single serial queue for them: never the main thread (a scan used to
    /// stop the session there) and never a concurrent queue (start and stop
    /// could race).
    private let sessionQueue = DispatchQueue(label: "net.sukavinagroup.canteen-scanner.session")

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        prepareCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func prepareCamera() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureCamera()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async { if granted { self?.configureCamera() } else { self?.showCameraUnavailable() } }
            }
        default: showCameraUnavailable()
        }
    }

    private func configureCamera() {
        guard !configured,
              let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(input) else { showCameraUnavailable(); return }
        captureSession.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard captureSession.canAddOutput(output) else { showCameraUnavailable(); return }
        captureSession.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: captureSession)
        preview.videoGravity = .resizeAspectFill
        view.layer.insertSublayer(preview, at: 0)
        previewLayer = preview
        configured = true
        sessionQueue.async { [captureSession] in captureSession.startRunning() }
    }

    func setScanning(_ active: Bool) {
        handlingCode = !active
        guard configured else { return }
        sessionQueue.async { [captureSession] in
            if active && !captureSession.isRunning { captureSession.startRunning() }
            if !active && captureSession.isRunning { captureSession.stopRunning() }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !handlingCode,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        handlingCode = true
        sessionQueue.async { [captureSession] in captureSession.stopRunning() }
        onCode?(value)
    }

    private func showCameraUnavailable() {
        let label = UILabel()
        label.text = "Không thể sử dụng camera. Hãy cho phép Camera trong Cài đặt."
        label.textColor = .white
        label.numberOfLines = 0
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }
}
