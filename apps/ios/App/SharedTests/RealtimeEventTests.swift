import XCTest
@testable import SukavinaShared

final class RealtimeEventTests: XCTestCase {
    func testInboxChangeIsScopedToItsOwner() {
        let line = #"data: {"type":"inbox_changed","employeeCodes":["NV001"]}"#
        XCTAssertEqual(RealtimeEvent(line: line, employeeCode: "NV001")?.changes, [.inbox])
        XCTAssertNil(RealtimeEvent(line: line, employeeCode: "NV002"))
    }

    func testPayloadWithoutChangeIsIgnored() {
        XCTAssertNil(RealtimeEvent(line: #"data: {"type":"connected"}"#, employeeCode: "NV001"))
        XCTAssertNil(RealtimeEvent(line: #"data: {"type":"heartbeat"}"#, employeeCode: "NV001"))
    }

    func testEveryChangeKindIsRecognised() {
        let event = RealtimeEvent(
            line: "data: attendance_changed,request_changed,meal_changed,meeting_changed,content_changed",
            employeeCode: "NV001"
        )
        XCTAssertEqual(event?.changes, [.attendance, .request, .meal, .meeting, .content])
    }

    func testEventsScopedToOtherEmployeesAreIgnored() {
        XCTAssertNil(RealtimeEvent(
            line: #"data: {"type":"attendance_changed","employeeCodes":["NV002"]}"#,
            employeeCode: "NV001"
        ))
        XCTAssertNil(RealtimeEvent(
            line: #"data: {"type":"attendance_changed","employeeCodes":["NV002"]}"#,
            employeeCode: nil
        ))
        XCTAssertEqual(RealtimeEvent(
            line: #"data: {"type":"attendance_changed","employeeCodes":["nv001","NV002"]}"#,
            employeeCode: "NV001"
        )?.changes, [.attendance])
    }

    func testUnscopedEventIsCompanyWide() {
        XCTAssertEqual(
            RealtimeEvent(line: #"data: {"type":"attendance_changed"}"#, employeeCode: "NV001")?.changes,
            [.attendance]
        )
    }

    func testOwnEmployeeChangeAlsoMeansOwnProfile() {
        // The server's JSON form; the code used to keep a trailing quote.
        XCTAssertEqual(
            RealtimeEvent(line: #"data: {"type":"employee_changed:NV001"}"#, employeeCode: "nv001")?.changes,
            [.employee, .ownProfile]
        )
        XCTAssertEqual(
            RealtimeEvent(line: #"data: {"type":"employee_changed:NV002"}"#, employeeCode: "NV001")?.changes,
            [.employee]
        )
        XCTAssertEqual(
            RealtimeEvent(line: #"data: {"type":"employee_changed"}"#, employeeCode: "NV001")?.changes,
            [.employee]
        )
    }

    func testAiAssistantSettingsAreNotDataChanges() {
        let disabled = RealtimeEvent(line: #"data: {"type":"ai_assistant_settings_changed_disabled"}"#, employeeCode: "NV001")
        XCTAssertEqual(disabled?.aiAssistantEnabled, false)
        XCTAssertEqual(disabled?.changes, [])
        let enabled = RealtimeEvent(line: #"data: {"type":"ai_assistant_settings_changed_enabled"}"#, employeeCode: "NV001")
        XCTAssertEqual(enabled?.aiAssistantEnabled, true)
    }
}
