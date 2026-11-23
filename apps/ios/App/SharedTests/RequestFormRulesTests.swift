import XCTest
@testable import SukavinaShared

private struct Employee: RequestRecipient {
    let id: String
    let fullName: String
    let isSelf: Bool
}

private struct TeamPerson: RequestRecipient {
    let id: String
    let fullName: String
    var isSelf = false
    var employeeCode = ""
    var jobTitle: String?
    var teamLeadId: String?
    var teamLevel: Int?
    var teamOrder: Int?
}

final class RequestFormRulesTests: XCTestCase {
    private let calendar = VietnamTime.calendar

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(VietnamTime.date(fromISO8601: value))
    }

    private func draft(_ kind: RequestFormKind, start: Date, end: Date) -> RequestFormRules.Draft {
        RequestFormRules.Draft(
            kind: kind, reason: "Lý do đủ dài để gửi", destination: "", transport: "personal_vehicle",
            distanceText: "", durationMinutesText: 30, start: start, end: end,
            recipientsLoaded: false, selectedRecipientCount: 0
        )
    }

    func testDurationsAreWholeStepsInRange() {
        XCTAssertEqual(RequestFormRules.validDuration(30), 30)
        XCTAssertNil(RequestFormRules.validDuration(32))
        XCTAssertNil(RequestFormRules.validDuration(30.5))
        XCTAssertNil(RequestFormRules.validDuration(0))
        XCTAssertNil(RequestFormRules.validDuration(1440))
        XCTAssertNil(RequestFormRules.validDuration(nil))
    }

    func testOvertimeSnapsToTheStepOnBothVersions() throws {
        // 47 minutes used to become 30 on iOS 17 and 45 on iOS 18.
        let start = try date("2026-11-10T17:00:00+07:00")
        let adjusted = RequestFormRules.overtimeAfterEndChange(start: start, end: start.addingTimeInterval(47 * 60), minutes: 30)
        XCTAssertEqual(adjusted.minutes, 45)
        XCTAssertEqual(adjusted.end, start.addingTimeInterval(45 * 60))
        let backwards = RequestFormRules.overtimeAfterEndChange(start: start, end: start.addingTimeInterval(-60), minutes: 30)
        XCTAssertEqual(backwards.start, start.addingTimeInterval(-60 - 30 * 60))
        let moved = RequestFormRules.overtimeAfterStartChange(start: start, end: start.addingTimeInterval(-60), minutes: 30)
        XCTAssertEqual(moved.end, start.addingTimeInterval(30 * 60))
    }

    func testOvertimeEndFollowsANewStartDay() throws {
        // 16:30–17:00 on 12/11; the start date changes to 11/11 (same time).
        let previousStart = try date("2026-11-12T16:30:00+07:00")
        let end = try date("2026-11-12T17:00:00+07:00")
        let earlier = try date("2026-11-11T16:30:00+07:00")
        let back = RequestFormRules.overtimeAfterStartChange(previousStart: previousStart, start: earlier, end: end, minutes: 30, calendar: calendar)
        XCTAssertEqual(back.end, try date("2026-11-11T17:00:00+07:00"))
        XCTAssertEqual(back.minutes, 30)

        let later = try date("2026-11-14T16:30:00+07:00")
        let forward = RequestFormRules.overtimeAfterStartChange(previousStart: previousStart, start: later, end: end, minutes: 30, calendar: calendar)
        XCTAssertEqual(forward.end, try date("2026-11-14T17:00:00+07:00"))
        XCTAssertEqual(forward.minutes, 30)

        // A new time on the same day still keeps the end and adjusts the length.
        let sameDay = try date("2026-11-12T16:00:00+07:00")
        let earlierTime = RequestFormRules.overtimeAfterStartChange(previousStart: previousStart, start: sameDay, end: end, minutes: 30, calendar: calendar)
        XCTAssertEqual(earlierTime.end, end)
        XCTAssertEqual(earlierTime.minutes, 60)
    }

    func testShiftTimesAndNextSunday() throws {
        let day = try date("2026-11-10T00:00:00+07:00") // Tuesday
        XCTAssertEqual(VietnamTime.clock.string(from: RequestFormRules.shiftStart("08:15", on: day, calendar: calendar)), "08:15")
        // An invalid hour falls back alone; the valid minute is kept (as before).
        XCTAssertEqual(VietnamTime.clock.string(from: RequestFormRules.shiftStart("25:00", on: day, calendar: calendar)), "07:00")
        XCTAssertEqual(VietnamTime.clock.string(from: RequestFormRules.shiftStart("abc", on: day, calendar: calendar)), "07:30")
        XCTAssertEqual(VietnamTime.clock.string(from: RequestFormRules.shiftEnd(nil, on: day, calendar: calendar)), "16:30")
        let sunday = RequestFormRules.nextSunday(from: day, calendar: calendar)
        XCTAssertEqual(VietnamTime.dayKey.string(from: sunday), "2026-11-15")
        XCTAssertEqual(RequestFormRules.nextSunday(from: sunday, calendar: calendar), sunday)
    }

    func testKindDefaults() throws {
        let now = try date("2026-11-10T09:12:00+07:00")
        let business = try XCTUnwrap(RequestFormRules.defaults(for: .business, now: now, currentStart: now, workStart: nil, workEnd: nil, calendar: calendar))
        XCTAssertEqual(business.end.timeIntervalSince(business.start), 3600)
        let overtime = try XCTUnwrap(RequestFormRules.defaults(for: .overtime, now: now, currentStart: now, workStart: nil, workEnd: "17:00", calendar: calendar))
        XCTAssertEqual(VietnamTime.clock.string(from: overtime.start), "17:00")
        XCTAssertEqual(overtime.durationMinutes, 30)
        XCTAssertNil(RequestFormRules.defaults(for: .attendance, now: now, currentStart: now, workStart: nil, workEnd: nil, calendar: calendar))
    }

    func testLateAndEarlyFollowTheShift() throws {
        let day = try date("2026-11-10T13:00:00+07:00")
        let late = RequestFormRules.submissionDates(kind: .late, start: day, end: day, day: day, durationMinutes: 30, workStart: "08:00", workEnd: "17:00", calendar: calendar)
        XCTAssertEqual(VietnamTime.clock.string(from: late.start), "08:00")
        XCTAssertEqual(VietnamTime.clock.string(from: late.end), "08:30")
        let early = RequestFormRules.submissionDates(kind: .early, start: day, end: day, day: day, durationMinutes: 45, workStart: "08:00", workEnd: "17:00", calendar: calendar)
        XCTAssertEqual(VietnamTime.clock.string(from: early.start), "16:15")
        XCTAssertEqual(VietnamTime.clock.string(from: early.end), "17:00")
    }

    func testMissingRequirementOrderAndRules() throws {
        let start = try date("2026-11-10T09:00:00+07:00")
        let end = start.addingTimeInterval(3600)
        var business = draft(.business, start: start, end: end)
        XCTAssertEqual(RequestFormRules.missingRequirement(business, calendar: calendar), "Nhập nơi công tác để gửi đơn.")
        business.destination = "Hà Nội"
        XCTAssertEqual(RequestFormRules.missingRequirement(business, calendar: calendar), "Nhập quãng đường khi đi bằng xe cá nhân.")
        business.distanceText = "12,5"
        XCTAssertNil(RequestFormRules.missingRequirement(business, calendar: calendar))

        XCTAssertEqual(RequestFormRules.missingRequirement(draft(.sunday, start: start, end: end), calendar: calendar), "Ngày bắt đầu phải là Chủ nhật.")
        XCTAssertEqual(RequestFormRules.missingRequirement(draft(.overtime, start: end, end: start), calendar: calendar), "Giờ kết thúc phải sau giờ bắt đầu.")

        var late = draft(.late, start: start, end: end)
        late.durationMinutesText = 32
        XCTAssertEqual(RequestFormRules.missingRequirement(late, calendar: calendar), "Thời lượng phải từ 5 phút đến 23 giờ 55 phút, theo bước 5 phút.")

        var leave = draft(.leave, start: start, end: end)
        leave.recipientsLoaded = true
        XCTAssertEqual(RequestFormRules.missingRequirement(leave, calendar: calendar), "Chọn ít nhất một người tạo đơn.")
        leave.selectedRecipientCount = 1
        leave.reason = "ngắn"
        XCTAssertEqual(RequestFormRules.missingRequirement(leave, calendar: calendar), "Nội dung đơn cần tối thiểu 10 ký tự.")
        leave.reason = "Lý do đủ dài để gửi"
        leave.end = start.addingTimeInterval(-60)
        XCTAssertEqual(RequestFormRules.missingRequirement(leave, calendar: calendar), "Thời gian kết thúc phải sau thời gian bắt đầu.")
    }

    func testSameKindOverlapIsShownBeforeSending() throws {
        let existing = RequestFormRules.ExistingRequest(
            kind: "overtime",
            start: try date("2026-11-12T17:00:00+07:00"),
            end: try date("2026-11-12T19:00:00+07:00"),
            approved: false
        )
        var overtime = draft(.overtime, start: try date("2026-11-12T18:00:00+07:00"), end: try date("2026-11-12T20:00:00+07:00"))
        overtime.existingRequests = [existing]
        overtime.reason = ""
        // Shown even before a reason is typed: the time is what must change.
        XCTAssertEqual(
            RequestFormRules.missingRequirement(overtime, calendar: calendar),
            "Trùng giờ với đơn làm thêm 17:00–19:00 ngày 12/11 (đang chờ duyệt)."
        )
        // An overnight request names both days.
        XCTAssertEqual(
            RequestFormRules.overlapMessage(.init(
                kind: "overtime", start: try date("2026-11-12T22:00:00+07:00"), end: try date("2026-11-13T02:00:00+07:00"), approved: false
            )),
            "Trùng giờ với đơn làm thêm 22:00 12/11 – 02:00 13/11 (đang chờ duyệt)."
        )

        var approved = existing
        approved.approved = true
        overtime.existingRequests = [approved]
        XCTAssertTrue(RequestFormRules.missingRequirement(overtime, calendar: calendar)?.contains("(đã duyệt)") == true)

        // Back-to-back is allowed, as on the server.
        overtime.reason = "Lý do đủ dài để gửi"
        overtime.start = try date("2026-11-12T19:00:00+07:00")
        overtime.end = try date("2026-11-12T21:00:00+07:00")
        XCTAssertNil(RequestFormRules.missingRequirement(overtime, calendar: calendar))

        // Sunday work is stored as overtime and follows the same rule.
        var sunday = draft(.sunday, start: try date("2026-11-15T08:00:00+07:00"), end: try date("2026-11-15T12:00:00+07:00"))
        sunday.existingRequests = [.init(kind: "overtime", start: try date("2026-11-15T07:30:00+07:00"), end: try date("2026-11-15T16:30:00+07:00"), approved: true)]
        XCTAssertTrue(RequestFormRules.missingRequirement(sunday, calendar: calendar)?.hasPrefix("Trùng giờ với đơn làm thêm") == true)
        // Only for the user's own request.
        sunday.includesSelf = false
        XCTAssertNil(RequestFormRules.missingRequirement(sunday, calendar: calendar))

        // Every kind: a leave may not overlap another leave...
        var leave = draft(.leave, start: try date("2026-11-12T13:00:00+07:00"), end: try date("2026-11-12T16:30:00+07:00"))
        leave.existingRequests = [.init(kind: "leave", start: try date("2026-11-12T07:30:00+07:00"), end: try date("2026-11-12T16:30:00+07:00"), approved: true)]
        XCTAssertEqual(
            RequestFormRules.missingRequirement(leave, calendar: calendar),
            "Trùng giờ với đơn xin nghỉ 07:30–16:30 ngày 12/11 (đã duyệt)."
        )
        // ...but different kinds may share hours.
        leave.existingRequests = [existing, .init(kind: "gate", start: try date("2026-11-12T13:00:00+07:00"), end: try date("2026-11-12T14:00:00+07:00"), approved: true)]
        XCTAssertNil(RequestFormRules.missingRequirement(leave, calendar: calendar))

        // The same zero-length time is a duplicate.
        let point = try date("2026-11-12T10:00:00+07:00")
        var gate = draft(.gate, start: point, end: point)
        gate.existingRequests = [.init(kind: "gate", start: point, end: point, approved: false)]
        XCTAssertEqual(
            RequestFormRules.missingRequirement(gate, calendar: calendar),
            "Trùng giờ với đơn ra cổng 10:00–10:00 ngày 12/11 (đang chờ duyệt)."
        )
    }

    func testBusinessFieldsOnlyForBusiness() {
        let leave = RequestFormRules.businessFields(kind: .leave, destination: "X", transport: "personal_vehicle", distanceText: "3", lunchMeal: true, dinnerMeal: true)
        XCTAssertNil(leave.destination)
        XCTAssertNil(leave.transport)
        XCTAssertNil(leave.distanceKm)
        XCTAssertNil(leave.lunchMeal)
        let business = RequestFormRules.businessFields(kind: .business, destination: " Hà Nội ", transport: "grab", distanceText: "3,5", lunchMeal: true, dinnerMeal: false)
        XCTAssertEqual(business.destination, "Hà Nội")
        XCTAssertEqual(business.transport, "grab")
        XCTAssertEqual(business.distanceKm, 3.5)
        XCTAssertEqual(business.dinnerMeal, false)
    }

    func testTextHelpers() {
        XCTAssertEqual(RequestFormRules.numberText(12), "12")
        XCTAssertEqual(RequestFormRules.numberText(12.5), "12.5")
        XCTAssertEqual(RequestFormRules.durationReason(kindTitle: "Đi trễ", minutes: 90, reason: "Kẹt xe"), "Đi trễ: 1 giờ 30 phút. Kẹt xe")
    }

    func testRecipientSummaryAndToggle() {
        let people = [
            Employee(id: "me", fullName: "Tôi", isSelf: true),
            Employee(id: "a", fullName: "An", isSelf: false),
            Employee(id: "b", fullName: "Bình", isSelf: false),
        ]
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: people, selected: [], loaded: false, initialized: false), "Tôi")
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: people, selected: [], loaded: true, initialized: false), "Tôi")
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: people, selected: [], loaded: true, initialized: true), "Chưa chọn người")
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: people, selected: ["me", "a", "b"], loaded: true, initialized: true), "Tất cả")
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: people, selected: ["me", "a"], loaded: true, initialized: true), "Tôi, An")
        let team = teamPeople()
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: team, selected: ["me", "dan", "luan", "thin"], loaded: true, initialized: true), "Tôi và 3 người")
        XCTAssertEqual(RequestFormRules.recipientSummary(employees: team, selected: ["dan", "luan", "thin", "quan"], loaded: true, initialized: true), "4 người")

        let first = RequestFormRules.toggle("a", employees: people, selected: ["me"], hasChosenManagedEmployee: false)
        XCTAssertEqual(first.selected, ["a"])
        XCTAssertTrue(first.hasChosenManagedEmployee)
        let second = RequestFormRules.toggle("me", employees: people, selected: first.selected, hasChosenManagedEmployee: true)
        XCTAssertEqual(second.selected, ["a", "me"])
        let removed = RequestFormRules.toggle("a", employees: people, selected: second.selected, hasChosenManagedEmployee: true)
        XCTAssertEqual(removed.selected, ["me"])

        // "Tạo đơn cho" only for someone who may create requests for others.
        XCTAssertTrue(RequestFormRules.offersOtherRecipients(employees: people, loaded: true))
        XCTAssertFalse(RequestFormRules.offersOtherRecipients(employees: people, loaded: false))
        XCTAssertFalse(RequestFormRules.offersOtherRecipients(employees: people.filter(\.isSelf), loaded: true))

        // Two-line names (upper case here) share rows; order is kept otherwise.
        let paired = RequestFormRules.pairedRows(Array("aBcDefG")) { $0.isUppercase }.map { String($0) }
        XCTAssertEqual(paired, ["ac", "BD", "ef", "G"])
        XCTAssertEqual(RequestFormRules.pairedRows(Array("abcD")) { $0.isUppercase }.map { String($0) }, ["ab", "cD"])

        // Reports are approved at once; only the user's own request waits.
        XCTAssertNil(RequestFormRules.groupRoutingNote(employees: people, selected: ["me"], loaded: true))
        XCTAssertNil(RequestFormRules.groupRoutingNote(employees: people, selected: ["a"], loaded: false))
        XCTAssertEqual(
            RequestFormRules.groupRoutingNote(employees: people, selected: ["me", "a", "b"], loaded: true),
            "Đơn của 2 nhân viên được duyệt ngay · đơn của bạn gửi quản lý cấp trên duyệt."
        )
        XCTAssertEqual(
            RequestFormRules.groupRoutingNote(employees: people, selected: ["a"], loaded: true),
            "Đơn của 1 nhân viên được duyệt ngay và báo cho quản lý cấp trên của bạn."
        )
    }

    // MARK: Picker by team

    /// Me, then two teams (Dắn above Luân above Thìn; Quân alone) and
    /// filler people heading their own teams, past the threshold.
    private func teamPeople() -> [TeamPerson] {
        var people = [
            TeamPerson(id: "me", fullName: "Hữu", isSelf: true),
            TeamPerson(id: "dan", fullName: "Phạm Thanh Dắn", employeeCode: "00007", teamLeadId: "dan", teamLevel: 1, teamOrder: 0),
            TeamPerson(id: "thin", fullName: "Đào Văn Thìn", employeeCode: "01307", teamLeadId: "dan", teamLevel: 3, teamOrder: 2),
            TeamPerson(id: "luan", fullName: "Trần Minh Luân", employeeCode: "01465", teamLeadId: "dan", teamLevel: 2, teamOrder: 1),
            TeamPerson(id: "quan", fullName: "Trần Minh Quân", employeeCode: "00005", teamLeadId: "quan", teamLevel: 1, teamOrder: 3),
        ]
        for index in 0..<10 {
            people.append(TeamPerson(id: "p\(index)", fullName: "Người \(index)", teamLeadId: "p\(index)", teamLevel: 1, teamOrder: 10 + index))
        }
        return people
    }

    func testTeamsGroupInChainOrderWithDepth() throws {
        let teams = try XCTUnwrap(RequestFormRules.recipientTeams(teamPeople()))
        XCTAssertEqual(teams.map(\.lead.id).prefix(2), ["dan", "quan"])
        XCTAssertEqual(teams[0].members.map(\.person.id), ["luan", "thin"])
        XCTAssertEqual(teams[0].members.map(\.depth), [1, 2])
        XCTAssertEqual(teams[0].everyone.map(\.id), ["dan", "luan", "thin"])
        XCTAssertTrue(teams[1].members.isEmpty)
        XCTAssertFalse(teams.contains { $0.lead.isSelf })
    }

    func testTeamsOnlyForManyPeopleFromANewServer() {
        let people = teamPeople()
        XCTAssertNil(RequestFormRules.recipientTeams(Array(people.prefix(5))))
        let old = people.map { TeamPerson(id: $0.id, fullName: $0.fullName, isSelf: $0.isSelf) }
        XCTAssertNil(RequestFormRules.recipientTeams(old))
    }

    func testPersonWhoseLeadIsMissingHeadsATeam() throws {
        var people = teamPeople()
        people.removeAll { $0.id == "dan" }
        let teams = try XCTUnwrap(RequestFormRules.recipientTeams(people))
        XCTAssertTrue(teams.contains { $0.lead.id == "luan" })
        XCTAssertTrue(teams.contains { $0.lead.id == "thin" })
    }

    func testTeamTickChoosesWholeTeamThenNobody() {
        let people = teamPeople()
        let team = ["dan", "luan", "thin"]
        // The first team replaces the default "Tôi".
        var result = RequestFormRules.toggleTeam(team, employees: people, selected: ["me"], hasChosenManagedEmployee: false)
        XCTAssertEqual(result.selected, Set(team))
        XCTAssertEqual(RequestFormRules.teamSelection(team, selected: result.selected), .all)
        result = RequestFormRules.toggleTeam(["quan"], employees: people, selected: result.selected, hasChosenManagedEmployee: true)
        XCTAssertEqual(result.selected, Set(team + ["quan"]))
        result = RequestFormRules.toggleTeam(team, employees: people, selected: result.selected, hasChosenManagedEmployee: true)
        XCTAssertEqual(result.selected, ["quan"])
        XCTAssertEqual(RequestFormRules.teamSelection(team, selected: ["luan"]), .some)
        XCTAssertEqual(RequestFormRules.teamSelection(team, selected: []), .none)
    }

    func testSearchIgnoresAccentsAndFindsCodes() {
        let people = teamPeople()
        XCTAssertEqual(RequestFormRules.searchRecipients(people, query: "dan").map(\.id), ["dan"])
        XCTAssertEqual(RequestFormRules.searchRecipients(people, query: "DAO van").map(\.id), ["thin"])
        XCTAssertEqual(RequestFormRules.searchRecipients(people, query: "01465").map(\.id), ["luan"])
        XCTAssertEqual(RequestFormRules.searchRecipients(people, query: "  ").count, people.count)
        XCTAssertEqual(RequestFormRules.teamCaption(of: people[3], in: people), "Nhóm Phạm Thanh Dắn")
        XCTAssertNil(RequestFormRules.teamCaption(of: people[1], in: people))
    }

    func testCaptionsShowTheRealJobTitle() throws {
        var people = teamPeople()
        people[1].jobTitle = "Quản đốc"
        people[3].jobTitle = " Công nhân "
        XCTAssertEqual(RequestFormRules.personCaption(people[1], in: people, searching: false), "Quản đốc")
        XCTAssertEqual(RequestFormRules.personCaption(people[3], in: people, searching: true), "Công nhân · Nhóm Phạm Thanh Dắn")
        XCTAssertNil(RequestFormRules.personCaption(people[2], in: people, searching: false))
        let team = try XCTUnwrap(RequestFormRules.recipientTeams(people)?.first)
        XCTAssertEqual(RequestFormRules.teamSubtitle(team, picked: 0, state: .none), "Quản đốc · 3 người")
        XCTAssertEqual(RequestFormRules.teamSubtitle(team, picked: 1, state: .some), "Quản đốc · 3 người · đã chọn 1")
    }
}
