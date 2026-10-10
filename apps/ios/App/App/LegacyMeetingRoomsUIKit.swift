import UIKit
import SwiftUI
import Combine

// iOS 17.6.1 aborts in SwiftUI/AttributeGraph metadata construction when
// entering the complex meeting-room view (TestFlight 109/110). Keep the
// entire iOS 17 room/navigation/booking path native UIKit; iOS 18+ retains
// the existing SwiftUI implementation without any change.
@available(iOS 17.0, *)
struct LegacyMeetingRoomsUIKitView: UIViewControllerRepresentable {
    let session: SessionStore

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: LegacyMeetingRoomsController(session: session))
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

@available(iOS 17.0, *)
@MainActor
private enum LegacyMeetingUI {
    static func date(_ text: String) -> Date? { MeetingPresentation.date(from: text) }
    static func time(_ text: String) -> String { MeetingPresentation.time(text) }
    static func sameDay(_ booking: MeetingBooking, _ day: Date) -> Bool {
        guard let start = date(booking.startsAt) else { return false }
        return MeetingPresentation.calendar.isDate(start, inSameDayAs: day)
    }
    static func message(_ title: String, _ body: String, from controller: UIViewController) {
        let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đóng", style: .default))
        controller.present(alert, animated: true)
    }
}

@available(iOS 17.0, *)
@MainActor
private final class LegacyMeetingRoomsController: UITableViewController {
    private let session: SessionStore
    private var cancellables = Set<AnyCancellable>()
    private let daySelector = UISegmentedControl(items: ["Hôm nay", "Ngày mai"])
    private var day = Date()

    init(session: SessionStore) {
        self.session = session
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Phòng họp"
        tableView.backgroundColor = .systemGroupedBackground
        daySelector.selectedSegmentIndex = 0
        daySelector.addTarget(self, action: #selector(dayChanged), for: .valueChanged)
        navigationItem.titleView = daySelector
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "calendar"),
            style: .plain, target: self, action: #selector(openMyMeetings)
        )
        session.$meetingRooms.combineLatest(session.$meetingBookings)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in self?.tableView.reloadData() }
            .store(in: &cancellables)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        fetch()
    }

    private func fetch() {
        let shift = daySelector.selectedSegmentIndex
        day = MeetingPresentation.calendar.date(byAdding: .day, value: shift, to: Date()) ?? Date()
        Task { await session.refreshMeetingSchedule(date: day) }
        tableView.reloadData()
    }
    @objc private func dayChanged() { fetch() }

    @objc private func openMyMeetings() {
        navigationController?.pushViewController(
            LegacyMeetingScheduleController(session: session, room: nil, day: day), animated: true
        )
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        session.meetingRooms.count
    }
    override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let room = session.meetingRooms[path.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        let now = Date()
        let occupied = session.meetingBookings.contains { booking in
            guard booking.roomId == room.id, LegacyMeetingUI.sameDay(booking, day),
                  let start = LegacyMeetingUI.date(booking.startsAt),
                  let end = LegacyMeetingUI.date(booking.endsAt) else { return false }
            return booking.status != "cancelled" && start <= now && now < end
        }
        cell.textLabel?.text = room.name
        cell.textLabel?.font = .preferredFont(forTextStyle: .headline)
        cell.detailTextLabel?.text = "\(room.capacity) chỗ · \(occupied ? "Đang họp" : "Xem lịch phòng")"
        cell.detailTextLabel?.textColor = occupied ? .systemRed : .secondaryLabel
        let button = UIButton(type: .system)
        button.setTitle("Đặt phòng", for: .normal)
        button.tag = path.row
        button.frame = CGRect(x: 0, y: 0, width: 100, height: 44)
        button.addTarget(self, action: #selector(bookFromRow(_:)), for: .touchUpInside)
        cell.accessoryView = button
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        tableView.deselectRow(at: path, animated: true)
        guard session.meetingRooms.indices.contains(path.row) else { return }
        navigationController?.pushViewController(
            LegacyMeetingScheduleController(session: session, room: session.meetingRooms[path.row], day: day),
            animated: true
        )
    }
    @objc private func bookFromRow(_ button: UIButton) {
        guard session.meetingRooms.indices.contains(button.tag) else { return }
        navigationController?.pushViewController(
            LegacyMeetingBookingController(session: session, room: session.meetingRooms[button.tag], day: day),
            animated: true
        )
    }
}

@available(iOS 17.0, *)
@MainActor
private final class LegacyMeetingScheduleController: UITableViewController {
    private let session: SessionStore
    private let room: MeetingRoom?
    private let day: Date
    private var cancellable: AnyCancellable?
    private var bookings: [MeetingBooking] {
        session.meetingBookings.filter { meeting in
            meeting.status != "cancelled" && LegacyMeetingUI.sameDay(meeting, day)
                && (room == nil ? (meeting.isMine ?? false) : meeting.roomId == room?.id)
        }.sorted { $0.startsAt < $1.startsAt }
    }
    init(session: SessionStore, room: MeetingRoom?, day: Date) {
        self.session = session; self.room = room; self.day = day
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = room?.name ?? "Lịch của tôi"
        if room != nil {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "Đặt phòng", style: .plain, target: self, action: #selector(book)
            )
        }
        cancellable = session.$meetingBookings.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tableView.reloadData() }
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await session.refreshMeetingSchedule(date: day) }
    }
    @objc private func book() {
        guard let room else { return }
        navigationController?.pushViewController(
            LegacyMeetingBookingController(session: session, room: room, day: day), animated: true
        )
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        bookings.count
    }
    override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let meeting = bookings[path.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = meeting.title.isEmpty ? "Cuộc họp" : meeting.title
        cell.detailTextLabel?.text = "\(LegacyMeetingUI.time(meeting.startsAt)) – \(LegacyMeetingUI.time(meeting.endsAt)) · \(meeting.attendeeCount) người"
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        tableView.deselectRow(at: path, animated: true)
        let meeting = bookings[path.row]
        guard let selectedRoom = room ?? session.meetingRooms.first(where: { $0.id == meeting.roomId }) else { return }
        navigationController?.pushViewController(
            LegacyMeetingDetailController(session: session, room: selectedRoom, meeting: meeting), animated: true
        )
    }
}

@available(iOS 17.0, *)
@MainActor
private final class LegacyMeetingBookingController: UIViewController {
    private let session: SessionStore
    private let room: MeetingRoom
    private let day: Date
    private let topic = UITextField()
    private let kind = UISegmentedControl(items: ["Nội bộ", "Tiếp khách"])
    private let start = UIDatePicker()
    private let durationButton = UIButton(type: .system)
    private var durationMinutes = 30
    private let inviteButton = UIButton(type: .system)
    private let confirm = UIButton(type: .system)
    private var invited = Set<String>()
    private var submitting = false

    init(session: SessionStore, room: MeetingRoom, day: Date) {
        self.session = session; self.room = room; self.day = day
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Đặt phòng · \(room.name)"
        view.backgroundColor = .systemGroupedBackground
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let fields = UIStackView()
        fields.axis = .vertical; fields.spacing = 16
        fields.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(fields)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            fields.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 18),
            fields.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -18),
            fields.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            fields.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            fields.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -36)
        ])
        func label(_ value: String) -> UILabel {
            let label = UILabel()
            label.text = value; label.numberOfLines = 0
            label.font = .preferredFont(forTextStyle: .headline)
            return label
        }
        fields.addArrangedSubview(label("\(room.capacity) chỗ · \(room.location)"))
        fields.addArrangedSubview(label("Loại cuộc họp"))
        kind.selectedSegmentIndex = 0
        fields.addArrangedSubview(kind)
        fields.addArrangedSubview(label("Nội dung cuộc họp"))
        topic.placeholder = "Ví dụ: Họp kế hoạch tuần"
        topic.borderStyle = .roundedRect
        fields.addArrangedSubview(topic)
        fields.addArrangedSubview(label("Bắt đầu"))
        start.datePickerMode = .dateAndTime
        start.preferredDatePickerStyle = .compact
        start.locale = Locale(identifier: "vi_VN")
        let calendar = MeetingPresentation.calendar
        let dateStart = calendar.startOfDay(for: day)
        start.minimumDate = max(dateStart, Date())
        start.maximumDate = calendar.date(byAdding: .day, value: 1, to: dateStart)?.addingTimeInterval(-60)
        start.date = max(start.minimumDate ?? dateStart,
                         calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dateStart) ?? dateStart)
        fields.addArrangedSubview(start)
        fields.addArrangedSubview(label("Thời lượng"))
        // Preserve the original SwiftUI booking form's complete time choices.
        let durations: [(Int, String)] = [
            (5, "5 phút"), (10, "10 phút"), (15, "15 phút"),
            (20, "20 phút"), (30, "30 phút"), (45, "45 phút"),
            (60, "1 giờ"), (90, "90 phút"), (120, "2 giờ"),
            (180, "3 giờ"), (240, "4 giờ"), (300, "5 giờ"),
            (360, "6 giờ"), (420, "7 giờ"), (480, "8 giờ")
        ]
        durationButton.setTitle("Thời lượng: 30 phút ▾", for: .normal)
        durationButton.contentHorizontalAlignment = .leading
        durationButton.showsMenuAsPrimaryAction = true
        durationButton.menu = UIMenu(children: durations.map { option in
            UIAction(title: option.1) { [weak self] _ in
                self?.durationMinutes = option.0
                self?.durationButton.setTitle("Thời lượng: \(option.1) ▾", for: .normal)
            }
        })
        fields.addArrangedSubview(durationButton)
        inviteButton.contentHorizontalAlignment = .leading
        inviteButton.setTitle("Mời người tham gia (0)", for: .normal)
        inviteButton.addTarget(self, action: #selector(invite), for: .touchUpInside)
        fields.addArrangedSubview(inviteButton)
        confirm.setTitle("Xác nhận đặt phòng", for: .normal)
        confirm.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        confirm.tintColor = .white
        confirm.backgroundColor = .systemRed
        confirm.layer.cornerRadius = 16
        confirm.heightAnchor.constraint(equalToConstant: 52).isActive = true
        confirm.addTarget(self, action: #selector(submit), for: .touchUpInside)
        fields.addArrangedSubview(confirm)
    }

    @objc private func invite() {
        navigationController?.pushViewController(
            LegacyMeetingInviteesController(session: session, maximum: max(0, room.capacity - 1), chosen: invited) { [weak self] value in
                self?.invited = value
                self?.inviteButton.setTitle("Mời người tham gia (\(value.count))", for: .normal)
            }, animated: true
        )
    }
    @objc private func submit() {
        guard !submitting else { return }
        guard invited.count + 1 <= room.capacity else {
            LegacyMeetingUI.message("Vượt sức chứa", "Hãy giảm số người tham gia.", from: self)
            return
        }
        submitting = true
        confirm.isEnabled = false
        let category = kind.selectedSegmentIndex == 1 ? "Tiếp khách" : "Nội bộ"
        let text = topic.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = text.isEmpty ? category : "\(category) · \(text)"
        let minutes = durationMinutes
        Task { [weak self] in
            guard let self else { return }
            let error = await session.createMeeting(
                room: room, title: title, start: start.date,
                duration: minutes, participants: Array(invited)
            )
            submitting = false
            confirm.isEnabled = true
            if let error { LegacyMeetingUI.message("Không thể đặt phòng", error, from: self) }
            else { navigationController?.popViewController(animated: true) }
        }
    }
}

@available(iOS 17.0, *)
@MainActor
private final class LegacyMeetingInviteesController: UITableViewController, UISearchResultsUpdating {
    private let session: SessionStore
    private let maximum: Int
    private let onUpdate: (Set<String>) -> Void
    private var chosen: Set<String>
    private var text = ""
    private var cancellable: AnyCancellable?
    private var people: [MeetingInvitee] {
        session.meetingInvitees.filter {
            text.isEmpty || $0.fullName.localizedCaseInsensitiveContains(text)
                || $0.employeeCode.localizedCaseInsensitiveContains(text)
                || $0.department.localizedCaseInsensitiveContains(text)
        }
    }
    init(session: SessionStore, maximum: Int, chosen: Set<String>, onUpdate: @escaping (Set<String>) -> Void) {
        self.session = session; self.maximum = maximum; self.chosen = chosen; self.onUpdate = onUpdate
        super.init(style: .insetGrouped)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Mời người tham gia"
        let search = UISearchController(searchResultsController: nil)
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Tên, mã nhân viên hoặc phòng ban"
        navigationItem.searchController = search
        cancellable = session.$meetingInvitees.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.tableView.reloadData() }
        Task {
            if let error = await session.refreshMeetingInvitees() {
                LegacyMeetingUI.message("Không thể tải nhân viên", error, from: self)
            }
        }
    }
    func updateSearchResults(for searchController: UISearchController) {
        text = searchController.searchBar.text ?? ""
        tableView.reloadData()
    }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { people.count }
    override func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let person = people[path.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        cell.textLabel?.text = person.fullName
        cell.detailTextLabel?.text = "\(person.employeeCode) · \(person.department)"
        cell.accessoryType = chosen.contains(person.id) ? .checkmark : .none
        return cell
    }
    override func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        tableView.deselectRow(at: path, animated: true)
        let person = people[path.row]
        if chosen.contains(person.id) { chosen.remove(person.id) }
        else if chosen.count < maximum { chosen.insert(person.id) }
        else {
            LegacyMeetingUI.message("Đủ sức chứa", "Chỉ còn \(maximum) vị trí dành cho người được mời.", from: self)
            return
        }
        onUpdate(chosen)
        tableView.reloadData()
    }
}

@available(iOS 17.0, *)
@MainActor
private final class LegacyMeetingDetailController: UIViewController {
    private let session: SessionStore
    private let room: MeetingRoom
    private let meeting: MeetingBooking
    private let summary = UILabel()
    init(session: SessionStore, room: MeetingRoom, meeting: MeetingBooking) {
        self.session = session; self.room = room; self.meeting = meeting
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }
    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Chi tiết cuộc họp"
        view.backgroundColor = .systemGroupedBackground
        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        let fields = UIStackView()
        fields.axis = .vertical; fields.spacing = 16
        fields.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(fields)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            fields.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 18),
            fields.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -18),
            fields.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            fields.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            fields.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -36)
        ])
        summary.numberOfLines = 0
        summary.font = .preferredFont(forTextStyle: .body)
        summary.text = "\(meeting.title)\n\nPhòng: \(room.name)\nThời gian: \(LegacyMeetingUI.time(meeting.startsAt)) – \(LegacyMeetingUI.time(meeting.endsAt))\nSố người: \(meeting.attendeeCount)"
        fields.addArrangedSubview(summary)
        if meeting.isOwner == true {
            if let start = LegacyMeetingUI.date(meeting.startsAt), start > Date() {
                fields.addArrangedSubview(button("Hủy lịch họp", #selector(cancel)))
            } else if let end = LegacyMeetingUI.date(meeting.endsAt), end > Date() {
                fields.addArrangedSubview(button("Gia hạn 5 phút", #selector(extend)))
                fields.addArrangedSubview(button("Kết thúc cuộc họp", #selector(end)))
            }
        }
        Task {
            if let detail = await session.meetingBookingDetails(id: meeting.id) {
                var value = "\(detail.title)\n\nPhòng: \(detail.room.name)\nThời gian: \(LegacyMeetingUI.time(detail.startsAt)) – \(LegacyMeetingUI.time(detail.endsAt))\nNgười tổ chức: \(detail.employee.fullName)"
                if detail.isLimitedViewer != true {
                    value += "\n\nNgười tham gia:\n" + detail.participants.map { $0.employee.fullName }.joined(separator: "\n")
                }
                summary.text = value
            }
        }
    }
    private func button(_ text: String, _ selector: Selector) -> UIButton {
        let value = UIButton(type: .system)
        value.setTitle(text, for: .normal)
        value.heightAnchor.constraint(equalToConstant: 48).isActive = true
        value.addTarget(self, action: selector, for: .touchUpInside)
        return value
    }
    @objc private func cancel() {
        let alert = UIAlertController(title: "Hủy lịch họp?", message: "Bạn có chắc muốn hủy?", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Không", style: .cancel))
        alert.addAction(UIAlertAction(title: "Hủy lịch", style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task {
                let error = await self.session.cancelMeeting(id: self.meeting.id, scheduledAt: self.meeting.startsAt)
                if let error { LegacyMeetingUI.message("Không thể hủy", error, from: self) }
                else { self.navigationController?.popViewController(animated: true) }
            }
        })
        present(alert, animated: true)
    }
    @objc private func extend() { perform("extend") }
    @objc private func end() {
        let alert = UIAlertController(title: "Kết thúc cuộc họp?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Không", style: .cancel))
        alert.addAction(UIAlertAction(title: "Kết thúc", style: .destructive) { [weak self] _ in
            self?.perform("end")
        })
        present(alert, animated: true)
    }
    private func perform(_ action: String) {
        Task {
            let error = await session.performMeetingControl(bookingID: meeting.id, action: action)
            if let error { LegacyMeetingUI.message("Không thể cập nhật", error, from: self) }
            else { navigationController?.popViewController(animated: true) }
        }
    }
}
