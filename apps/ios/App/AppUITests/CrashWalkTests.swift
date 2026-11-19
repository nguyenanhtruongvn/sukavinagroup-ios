import XCTest

/// Read-only crash walk: signs in with the test account from the CI secrets,
/// opens every tab, sheet, form and picker, taps the buttons that only switch
/// or open something, and closes again. It never taps a control that sends or
/// changes data (send, confirm, approve, cancel a request, order a meal,
/// change password, sign out, delete). After every step the app must still
/// be running; each step keeps a screenshot.
final class CrashWalkTests: XCTestCase {
    private var app: XCUIApplication!
    private var step = 0

    /// Labels this walk must never tap, even if a lookup would match them.
    private let forbidden = [
        "Gửi đơn", "Gửi", "Xác nhận", "Duyệt", "Hủy đơn", "Hủy lịch", "Bỏ lịch", "Kết thúc", "Tiếp tục họp",
        "Đổi mật khẩu", "Đăng xuất", "Yêu cầu xóa tài khoản", "Xóa vĩnh viễn", "Xóa tất cả", "Xóa",
        "Món nước", "Món chay", "Món thường", "Tăng ca", "Đặt món", "Quét mã nhận món", "Hoàn tất", "Tiếp tục đặt",
    ]

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // System permission prompts (notifications, Face ID) must not block the walk.
        addUIInterruptionMonitor(withDescription: "System alert") { alert in
            for title in ["Allow", "Cho phép", "OK", "Don’t Allow", "Không cho phép", "Not Now", "Để sau"] {
                let button = alert.buttons[title]
                if button.exists { button.tap(); return true }
            }
            return false
        }
    }

    func testOpenEveryScreenWithoutSending() throws {
        app.launch()
        signInIfNeeded()
        pause(4) // let the sign-in transition finish before touching the tabs
        check("signed in")

        home()
        requests()
        meetings()
        notifications()
        account()
        rotationAndBackground()
    }

    // MARK: - Screens

    private func home() {
        openTab("Trang chủ")
        if tapIfPresent("Bảng công") {
            check("Bảng công")
            if let month = firstStaticText(containing: "Tháng "), tapSafely(month) { pause(2.5); check("Bảng công: a month"); goBack() }
            goBack()
        }
        openTab("Trang chủ")
        if tapIfPresent("Chấm công hôm nay") {
            check("Chấm công hôm nay")
            _ = tapIfPresent("Tháng trước"); check("Chấm công: previous month")
            _ = tapIfPresent("Tháng sau"); check("Chấm công: next month")
            goBack()
        }
        openTab("Trang chủ")
        if tapIfPresent("Thực đơn hôm nay") {
            check("Thực đơn hôm nay")
            app.swipeUp(); check("Thực đơn: scroll")
            close()
        }
        openTab("Trang chủ")
        if tapIfPresent("Trợ lý AI") {
            check("Trợ lý AI: open (nothing sent)")
            close()
        }
        check("Trang chủ: back")
    }

    private func requests() {
        openTab("Đơn từ")
        for filter in ["Chờ duyệt", "Đã duyệt", "Từ chối", "Đã hủy", "Tất cả"] {
            if tapIfPresent(filter, exactButtonOnly: true) { check("Đơn từ: filter \(filter)") }
        }
        app.swipeUp(); check("Đơn từ: scroll")
        app.swipeDown()
        if tapIfPresent("Tạo đơn mới") {
            check("Tạo đơn mới: open")
            for kind in ["Xin nghỉ", "Công tác", "Đi trễ", "Về sớm", "Làm thêm giờ", "Làm chủ nhật", "Ra cổng", "Xác nhận giờ công"] {
                if tapIfPresent(kind, exactButtonOnly: false, allowForbiddenPrefix: kind == "Xác nhận giờ công") {
                    check("Tạo đơn mới: \(kind)")
                    if kind == "Công tác" {
                        for vehicle in ["Grab", "Xe công ty", "Xe cá nhân"] where tapIfPresent(vehicle) { check("Công tác: \(vehicle)") }
                    }
                }
            }
            if tapIfPresent("Tạo đơn cho") { check("Tạo đơn cho: picker"); close() }
            app.swipeUp(); check("Tạo đơn mới: scroll")
            close()
            check("Tạo đơn mới: closed")
        }
    }

    private func meetings() {
        openTab("Phòng họp")
        for day in ["Ngày mai", "Hôm nay"] where tapIfPresent(day) { check("Phòng họp: \(day)") }
        if tapIfPresent("Lịch của tôi") {
            check("Phòng họp: Lịch của tôi")
            dismissOverlays(); check("Lịch của tôi: closed")
        }
        if tapIfPresent("Xem lịch") { check("Phòng họp: timeline"); close() }
        if tapIfPresent("Đặt phòng") {
            check("Đặt phòng: form")
            for duration in ["15 phút", "45 phút", "1 giờ", "30 phút"] where tapIfPresent(duration) { check("Đặt phòng: \(duration)") }
            app.swipeUp(); check("Đặt phòng: scroll")
            close()
            check("Đặt phòng: closed")
        }
    }

    private func notifications() {
        openTab("Thông báo")
        for title in ["Chúc mừng năm mới", "Chúc mừng Giáng sinh", "Chúc mừng sinh nhật"] {
            guard let row = firstStaticText(containing: title), tapSafely(row) else { continue }
            pause(3)
            check("Thẻ chúc: \(title)")
            // Close by tapping outside the card.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap(); pause(1.5)
            check("Thẻ chúc: closed")
        }
        app.swipeUp(); check("Thông báo: scroll")
    }

    private func account() {
        openTab("Tài khoản")
        for mode in ["Tối", "Sáng", "Hệ thống"] where tapIfPresent(mode, exactButtonOnly: true) { check("Giao diện: \(mode)") }
        app.swipeUp()
        for page in ["Chính sách quyền riêng tư", "Hỗ trợ người dùng", "Hướng dẫn xóa tài khoản"] {
            if tapIfPresent(page, allowForbiddenPrefix: true) {
                check("Tài khoản: \(page)")
                goBack()
                openTab("Tài khoản"); app.swipeUp()
            }
        }
        check("Tài khoản: done")
    }

    private func rotationAndBackground() {
        XCUIDevice.shared.orientation = .landscapeLeft; pause(2); check("landscape")
        for tab in ["Trang chủ", "Đơn từ", "Phòng họp", "Thông báo", "Tài khoản"] { openTab(tab) }
        XCUIDevice.shared.orientation = .portrait; pause(2); check("portrait")
        XCUIDevice.shared.press(.home); pause(2)
        app.activate(); pause(3); check("back from background")
    }

    // MARK: - Helpers

    private func signInIfNeeded() {
        let code = app.textFields["MSNV"]
        let tabs = app.tabBars.firstMatch
        // The first launch on a fresh simulator can take a while: wait for
        // either the sign-in form or the signed-in tabs.
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline && !code.exists && !tabs.exists { pause(1) }
        guard code.exists else {
            XCTAssertTrue(tabs.exists, "Neither the sign-in form nor the tabs appeared within 90 s.")
            return
        }
        let env = ProcessInfo.processInfo.environment
        guard let employee = env["SUKAVINA_TEST_EMPLOYEE_CODE"], !employee.isEmpty,
              let password = env["SUKAVINA_TEST_PASSWORD"], !password.isEmpty else {
            XCTFail("Test account secrets are missing (SUKAVINA_TEST_EMPLOYEE_CODE / SUKAVINA_TEST_PASSWORD).")
            return
        }
        code.tap(); code.typeText(employee)
        let secure = app.secureTextFields["Mật khẩu"]
        let field = secure.exists ? secure : app.textFields["Mật khẩu"]
        field.tap(); field.typeText(password)
        app.buttons["Đăng nhập"].firstMatch.tap()
        let home = app.tabBars.buttons["Trang chủ"]
        if !home.waitForExistence(timeout: 30) {
            app.tap() // let an interruption monitor handle a pending system alert
        }
        XCTAssertTrue(home.waitForExistence(timeout: 30), "Did not reach the home screen after signing in (wrong password or a forced password change?).")
    }

    private func openTab(_ name: String) {
        dismissOverlays()
        for _ in 0..<15 {
            if tapSafely(app.tabBars.buttons[name].firstMatch) || tapSafely(app.buttons[name].firstMatch) { break }
            pause(1)
        }
        pause(2)
        check("tab \(name)")
    }

    @discardableResult
    private func tapIfPresent(_ label: String, exactButtonOnly: Bool = false, allowForbiddenPrefix: Bool = false) -> Bool {
        if !allowForbiddenPrefix {
            precondition(!forbidden.contains(where: { label == $0 || label.hasPrefix($0 + " ") }), "Refusing to tap \(label)")
        }
        let candidates: [XCUIElement] = exactButtonOnly
            ? [app.buttons[label], app.segmentedControls.buttons[label]]
            : [app.buttons[label], app.staticTexts[label], app.cells.staticTexts[label], app.otherElements[label]]
        for element in candidates where tapSafely(element.firstMatch) {
            pause(2)
            return true
        }
        // Not found: name what is on screen (short button labels only, no
        // digits, so no personal data reaches the public CI log).
        let visible = app.buttons.allElementsBoundByIndex.prefix(60)
            .map(\.label)
            .filter { !$0.isEmpty && $0.count <= 28 && $0.rangeOfCharacter(from: .decimalDigits) == nil }
        print("WALK: not found '\(label)'; buttons: \(Array(Set(visible)).sorted().joined(separator: ", "))")
        return false
    }

    private func firstStaticText(containing text: String) -> XCUIElement? {
        let match = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        if match.exists { return match }
        let direct = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        return direct.exists ? direct : nil
    }

    /// Closes sheets such as "Lịch của tôi" that would cover the tabs.
    private func dismissOverlays() {
        for _ in 0..<3 {
            let closer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Đóng")).firstMatch
            guard tapSafely(closer) else { return }
            pause(1.2)
        }
    }

    /// Closes a sheet, dialog or pushed screen without sending anything.
    private func close() {
        let closer = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Đóng")).firstMatch
        if tapSafely(closer) { pause(1.5); return }
        for title in ["Đóng", "Hủy", "Quay lại", "Close", "Cancel", "Xong"] {
            if tapSafely(app.buttons[title].firstMatch) { pause(1.5); return }
        }
        goBack()
    }

    private func goBack() {
        if tapSafely(app.navigationBars.buttons.element(boundBy: 0)) || tapSafely(app.buttons["Quay lại"].firstMatch) {
            // went back
        } else {
            app.swipeDown(velocity: .fast)
        }
        pause(1.5)
    }

    /// Taps an element by the centre of its frame if it is on screen now.
    /// Unlike element.tap(), this never fails the test when the element moves
    /// or disappears during a transition, and never scrolls on its own.
    @discardableResult
    private func tapSafely(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        let screen = app.frame
        guard !frame.isEmpty, frame.minX.isFinite, frame.minY.isFinite, screen.intersects(frame) else { return false }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard screen.contains(point) else { return false }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y)).tap()
        return true
    }

    private func pause(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func check(_ name: String) {
        step += 1
        print("WALK: step \(step) \(name)")
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = String(format: "%02d %@", step, name)
        shot.lifetime = .keepAlways
        add(shot)
        XCTAssertEqual(app.state, .runningForeground, "App is not running after step \(step): \(name)")
    }
}
