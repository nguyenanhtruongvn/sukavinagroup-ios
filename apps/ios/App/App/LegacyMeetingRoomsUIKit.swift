import UIKit
import SwiftUI
import Combine

/// iOS 17 can abort before `EmployeePortalView.body` gets to choose its own
/// fallback. Keeping the complete tab container in UIKit means only the page
/// the employee opens is hosted as SwiftUI, instead of creating a large portal
/// type tree during application launch.
struct LegacyEmployeePortalUIKitView: UIViewControllerRepresentable {
    let session: SessionStore
    let notificationRouter: APNsNotificationRouter

    func makeUIViewController(context: Context) -> LegacyEmployeePortalController {
        LegacyEmployeePortalController(session: session, notificationRouter: notificationRouter)
    }

    func updateUIViewController(_ controller: LegacyEmployeePortalController, context: Context) {}
}

@MainActor
final class LegacyEmployeePortalController: UITabBarController, UITabBarControllerDelegate {
    private let session: SessionStore
    private let notificationRouter: APNsNotificationRouter
    private var cancellables = Set<AnyCancellable>()

    init(session: SessionStore, notificationRouter: APNsNotificationRouter) {
        self.session = session
        self.notificationRouter = notificationRouter
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        delegate = self
        tabBar.tintColor = .systemRed
        tabBar.unselectedItemTintColor = .secondaryLabel
        setViewControllers([
            page(title: "Trang chủ", image: "house.fill") { [session, notificationRouter] in
                AnyView(DashboardView(isActive: true).sessionEnvironment(session).environmentObject(notificationRouter))
            },
            page(title: "Đơn từ", image: "doc.text.fill") { [session, notificationRouter] in
                AnyView(RequestsView(initialFilter: nil).sessionEnvironment(session).environmentObject(notificationRouter))
            },
            page(title: "Phòng họp", image: "building.2.fill") { [session, notificationRouter] in
                AnyView(LegacyMeetingRoomsUIKitView(session: session).sessionEnvironment(session).environmentObject(notificationRouter))
            },
            page(title: "Thông báo", image: "bell.fill") { [session, notificationRouter] in
                AnyView(NotificationsView().sessionEnvironment(session).environmentObject(notificationRouter))
            },
            page(title: "Tài khoản", image: "person.crop.circle.fill") { [session, notificationRouter] in
                AnyView(ProfileView().sessionEnvironment(session).environmentObject(notificationRouter))
            }
        ], animated: false)

        session.badge.$count
            .receive(on: RunLoop.main)
            .sink { [weak self] count in self?.updateBadge(count) }
            .store(in: &cancellables)

        notificationRouter.$pendingRoute
            .compactMap { $0 }
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.selectedIndex = 3 }
            .store(in: &cancellables)
    }

    func tabBarController(_ tabBarController: UITabBarController, didSelect viewController: UIViewController) {
        if selectedIndex == 3 {
            session.clearNotificationBadge()
        }
    }

    private func page(title: String, image: String, root: @escaping () -> AnyView) -> UIViewController {
        let controller = LegacyPortalPageController(root: root)
        controller.tabBarItem = UITabBarItem(title: title, image: UIImage(systemName: image), tag: 0)
        return controller
    }

    private func updateBadge(_ count: Int) {
        guard let pages = viewControllers,
              pages.indices.contains(3),
              let notificationItem = pages[3].tabBarItem else { return }
        notificationItem.badgeValue = count > 0 ? (count > 99 ? "99+" : String(count)) : nil
    }
}

@MainActor
private final class LegacyPortalPageController: UIViewController {
    private let root: () -> AnyView
    private var host: UIHostingController<AnyView>?

    init(root: @escaping () -> AnyView) {
        self.root = root
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: root())
        host.view.backgroundColor = .systemBackground
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        self.host = host
    }
}

// iOS 17.6.1 aborts in SwiftUI/AttributeGraph metadata construction when
// entering the complex meeting-room view (TestFlight 109/110). Keep the
// entire iOS 17 room/navigation/booking path native UIKit; iOS 18+ retains
// the existing SwiftUI implementation without any change.
struct LegacyMeetingRoomsUIKitView: UIViewControllerRepresentable {
    let session: SessionStore

    func makeUIViewController(context: Context) -> UINavigationController {
        UINavigationController(rootViewController: LegacyMeetingRoomsController(session: session))
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}
}

@MainActor
private enum LegacyMeetingUI {
    static func time(_ text: String) -> String { MeetingPresentation.time(text) }
    /// The booking form as a large sheet with its own navigation bar.
    static func presentBooking(session: SessionStore, room: MeetingRoom, day: Date, from controller: UIViewController, onDismiss: (() -> Void)? = nil) {
        presentSheet(LegacyMeetingBookingController(session: session, room: room, day: day), from: controller, onDismiss: onDismiss)
    }

    /// Every meeting screen opens as a large sheet, as on iOS 18:
    /// booking, a room's schedule, "Lịch của tôi" and meeting details.
    static func presentSheet(_ root: UIViewController, from controller: UIViewController, largeTitles: Bool = false, onDismiss: (() -> Void)? = nil) {
        let navigation = LegacySheetNavigationController(rootViewController: root)
        navigation.onDismiss = onDismiss
        navigation.navigationBar.prefersLargeTitles = largeTitles
        navigation.modalPresentationStyle = .pageSheet
        navigation.sheetPresentationController?.detents = [.large()]
        navigation.sheetPresentationController?.prefersGrabberVisible = false
        controller.present(navigation, animated: true)
    }

    static func sameDay(_ booking: MeetingBooking, _ day: Date) -> Bool {
        guard let start = booking.startDate else { return false }
        return MeetingPresentation.calendar.isDate(start, inSameDayAs: day)
    }
    static func message(_ title: String, _ body: String, from controller: UIViewController) {
        let alert = UIAlertController(title: title, message: body, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đóng", style: .default))
        controller.present(alert, animated: true)
    }

    /// PortalPageTitle: 30 pt bold rounded, scaled with Dynamic Type.
    static var pageTitleFont: UIFont {
        let base = UIFont.systemFont(ofSize: 30, weight: .bold)
        let rounded = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: 30) } ?? base
        return UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: rounded)
    }

    /// The room's state on `day`, same rules as MeetingRoomCard (iOS 18+):
    /// in a meeting now, free until the next one, or free all day.
    static func roomStatus(bookings: [MeetingBooking], day: Date, now: Date) -> (available: Bool, text: String) {
        let calendar = MeetingPresentation.calendar
        let dayBookings = bookings.filter { sameDay($0, day) }
        let isToday = calendar.isDate(day, inSameDayAs: now)
        if isToday, let current = dayBookings.first(where: { booking in
            guard let start = booking.startDate, let end = booking.endDate else { return false }
            return now >= start && now < end
        }) {
            return (false, "Đang họp đến \(time(current.endsAt))")
        }
        let point = isToday ? now : calendar.startOfDay(for: day)
        let next = dayBookings
            .filter { ($0.startDate ?? .distantPast) > point }
            .min { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
        if let next { return (true, "Trống đến \(time(next.startsAt))") }
        return (true, "Còn trống cả ngày")
    }

    /// Loading (nil symbol), failure or empty state for a list background.
    static func stateView(symbol: String?, title: String, message: String?, action: (String, UIAction)?) -> UIView {
        let stack = UIStackView()
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 10
        if let symbol {
            let image = UIImageView(image: UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 40, weight: .regular)))
            image.tintColor = .secondaryLabel
            stack.addArrangedSubview(image)
        } else {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            stack.addArrangedSubview(spinner)
        }
        let titleLabel = UILabel()
        titleLabel.text = title
        titleLabel.font = UIFont.preferredFont(forTextStyle: symbol == nil ? .subheadline : .title3).withWeight(symbol == nil ? .regular : .bold)
        titleLabel.textColor = symbol == nil ? .secondaryLabel : .label
        titleLabel.numberOfLines = 0
        titleLabel.textAlignment = .center
        stack.addArrangedSubview(titleLabel)
        if let message {
            let messageLabel = UILabel()
            messageLabel.text = message
            messageLabel.font = .preferredFont(forTextStyle: .subheadline)
            messageLabel.textColor = .secondaryLabel
            messageLabel.numberOfLines = 0
            messageLabel.textAlignment = .center
            stack.addArrangedSubview(messageLabel)
        }
        if let action {
            var configuration = UIButton.Configuration.filled()
            configuration.title = action.0
            configuration.baseBackgroundColor = .systemRed
            configuration.cornerStyle = .medium
            stack.addArrangedSubview(UIButton(configuration: configuration, primaryAction: action.1))
        }
        let container = UIView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 60),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
        ])
        return container
    }
}

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

/// The iOS 17 Meeting Rooms tab, built in UIKit to match the iOS 18+ SwiftUI
/// design (MeetingRoomsView): pinned "Phòng họp" header with Hôm nay /
/// Ngày mai / Lịch của tôi, and room cards with photo, status chip, status
/// line and a full-width action. UIKit on purpose: the SwiftUI room tree
/// aborts in type-metadata construction on iOS 17 (see LegacyMeetingRoomsUIKitView).
@MainActor
private final class LegacyMeetingRoomsController: UIViewController, UITableViewDataSource, UITableViewDelegate,
    UITableViewDragDelegate, UITableViewDropDelegate {
    private let session: SessionStore
    private var cancellables = Set<AnyCancellable>()
    /// The shown day as a date, like MeetingRoomsView: after midnight a
    /// "Ngày mai" selection becomes today instead of moving on a day.
    private var day = Date()
    private var tomorrow: Date {
        MeetingPresentation.calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
    }
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let todayButton = LegacyPillButton(title: "Hôm nay", weight: .bold)
    private let tomorrowButton = LegacyPillButton(title: "Ngày mai", weight: .semibold)
    private let mineButton = LegacyPillButton(symbol: "calendar")
    /// Fires at the next moment a room's status can change (a meeting start
    /// or end, or midnight), not every minute.
    private var statusTimer: Timer?
    private var isVisible = false
    private var rooms: [MeetingRoom] { session.meetings.rooms }

    init(session: SessionStore) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground

        // Pinned header, same metrics as the iOS 18+ PortalPinnedHeader:
        // title 20 pt below the safe area and from the edges.
        let title = UILabel()
        title.text = "Phòng họp"
        title.font = LegacyMeetingUI.pageTitleFont
        title.adjustsFontForContentSizeCategory = true
        title.accessibilityTraits = .header
        todayButton.addTarget(self, action: #selector(showToday), for: .touchUpInside)
        tomorrowButton.addTarget(self, action: #selector(showTomorrow), for: .touchUpInside)
        mineButton.addTarget(self, action: #selector(openMyMeetings), for: .touchUpInside)
        mineButton.accessibilityLabel = "Lịch của tôi"
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = UIStackView(arrangedSubviews: [todayButton, tomorrowButton, spacer, mineButton])
        buttons.spacing = 10
        let header = UIStackView(arrangedSubviews: [title, buttons])
        header.axis = .vertical
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)

        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.dragDelegate = self
        tableView.dropDelegate = self
        tableView.dragInteractionEnabled = true
        tableView.register(LegacyRoomCardCell.self, forCellReuseIdentifier: LegacyRoomCardCell.reuseID)
        // 16 pt from the buttons to the first card and 24 pt below the last,
        // as in MeetingRoomsView (cells add 8 pt around each card).
        tableView.contentInset = UIEdgeInsets(top: 6, left: 0, bottom: 16, right: 0)
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self, weak refresh] _ in
            guard let self else { return }
            let selected = day
            Task {
                await self.session.refreshMeetingSchedule(date: selected, force: true)
                refresh?.endRefreshing()
            }
        }, for: .valueChanged)
        tableView.refreshControl = refresh
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 2),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // A horizontal drag switches Hôm nay ⇄ Ngày mai with the thresholds
        // of MeetingRoomsView (at least 48 pt, mostly horizontal), alongside
        // vertical scrolling.
        let pan = UIPanGestureRecognizer(target: self, action: #selector(pannedDay(_:)))
        pan.delegate = self
        tableView.addGestureRecognizer(pan)

        session.meetings.$rooms
            .combineLatest(session.meetings.$bookingsByRoom, session.meetings.$scheduleLoaded, session.meetings.$scheduleError)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.reload() }
            .store(in: &cancellables)
        updateDayButtons()
        // Midnight, a clock change and returning to the app: like
        // refreshForCalendarChange in MeetingRoomsView.
        for name in [Notification.Name.NSCalendarDayChanged, UIApplication.significantTimeChangeNotification, UIApplication.didBecomeActiveNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(calendarChanged), name: name, object: nil)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // The tab has its own header; pushed screens keep the navigation bar.
        navigationController?.setNavigationBarHidden(true, animated: animated)
        isVisible = true
        fetch()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.setNavigationBarHidden(false, animated: animated)
        isVisible = false
        statusTimer?.invalidate()
        statusTimer = nil
    }

    /// Schedules one refresh for the next status change. New or changed
    /// bookings arrive through the realtime stream and reload the list, which
    /// reschedules; a clock change (time zone, manual time) does too.
    private func scheduleNextStatusChange() {
        statusTimer?.invalidate()
        statusTimer = nil
        guard isVisible else { return }
        let boundaries = session.meetings.bookingsByRoom.values.joined().flatMap { [$0.startDate, $0.endDate] }.compactMap { $0 }
        guard let next = MeetingBookingTime.statusChangeTimes(after: Date(), boundaries: boundaries, calendar: MeetingPresentation.calendar).first else { return }
        let timer = Timer(fire: next.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
        // .common so the refresh also happens while the list is scrolling.
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    /// A past day goes back to today; otherwise the shown day is refetched.
    @objc private func calendarChanged() {
        let calendar = MeetingPresentation.calendar
        if calendar.startOfDay(for: day) < calendar.startOfDay(for: Date()) {
            day = Date()
            updateDayButtons()
            fetch()
        } else if isVisible {
            fetch()
        } else {
            reload()
        }
    }

    private func fetch() {
        let selected = day
        Task { await session.refreshMeetingSchedule(date: selected) }
        reload()
    }

    private func reload() {
        tableView.reloadData()
        tableView.backgroundView = stateView()
        scheduleNextStatusChange()
    }

    /// Loading, failure (with retry) or "no rooms" — same states as iOS 18+.
    private func stateView() -> UIView? {
        guard rooms.isEmpty else { return nil }
        let meetings = session.meetings
        if let error = meetings.scheduleError {
            return LegacyMeetingUI.stateView(
                symbol: "wifi.exclamationmark", title: "Không tải được phòng họp", message: error,
                action: ("Thử lại", UIAction { [weak self] _ in
                    guard let self else { return }
                    let selected = self.day
                    Task { await self.session.refreshMeetingSchedule(date: selected, force: true) }
                }))
        }
        if !meetings.scheduleLoaded {
            return LegacyMeetingUI.stateView(symbol: nil, title: "Đang tải phòng họp…", message: nil, action: nil)
        }
        return LegacyMeetingUI.stateView(
            symbol: "building.2", title: "Chưa có phòng họp",
            message: "Quản trị viên cần cấu hình phòng trước khi nhân viên có thể đặt lịch.", action: nil)
    }

    private func updateDayButtons() {
        todayButton.isOn = MeetingPresentation.calendar.isDateInToday(day)
        tomorrowButton.isOn = MeetingPresentation.calendar.isDate(day, inSameDayAs: tomorrow)
    }

    /// Setting the day always refetches, like assigning `day` in SwiftUI.
    private func setDay(_ value: Date, animated: Bool = false) {
        day = value
        let changes = {
            self.updateDayButtons()
            self.fetch()
        }
        if animated {
            UIView.transition(with: tableView, duration: 0.25, options: .transitionCrossDissolve, animations: changes)
        } else {
            changes()
        }
    }

    @objc private func showToday() { setDay(Date()) }
    @objc private func showTomorrow() { setDay(tomorrow) }
    @objc private func pannedDay(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: tableView)
        guard abs(translation.x) > abs(translation.y), abs(translation.x) > 48 else { return }
        let calendar = MeetingPresentation.calendar
        if translation.x < 0, calendar.isDateInToday(day) { setDay(tomorrow, animated: true) }
        if translation.x > 0, calendar.isDate(day, inSameDayAs: tomorrow) { setDay(Date(), animated: true) }
    }

    @objc private func openMyMeetings() {
        LegacyMeetingUI.presentSheet(LegacyMyMeetingsController(session: session, day: day), from: self) { [weak self] in
            self?.fetch()
        }
    }

    private func openSchedule(_ room: MeetingRoom) {
        // The schedule can switch day and a booking can be for another day;
        // both reload the shared schedule: show this list's day again.
        LegacyMeetingUI.presentSheet(LegacyMeetingScheduleController(session: session, room: room, day: day), from: self, largeTitles: true) { [weak self] in
            self?.fetch()
        }
    }

    private func openBooking(_ room: MeetingRoom) {
        LegacyMeetingUI.presentBooking(session: session, room: room, day: day, from: self) { [weak self] in
            self?.fetch()
        }
    }

    // MARK: Table

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { rooms.count }

    func tableView(_ tableView: UITableView, cellForRowAt path: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: LegacyRoomCardCell.reuseID, for: path) as! LegacyRoomCardCell
        let room = rooms[path.row]
        cell.configure(
            room: room,
            bookings: session.meetings.bookingsByRoom[room.id] ?? [],
            day: day,
            now: Date(),
            onSchedule: { [weak self] in self?.openSchedule(room) },
            onBook: { [weak self] in self?.openBooking(room) },
            onMoveUp: path.row > 0 ? { [weak self] in self?.move(room, by: -1) } : nil,
            onMoveDown: path.row < rooms.count - 1 ? { [weak self] in self?.move(room, by: 1) } : nil
        )
        return cell
    }

    /// The long-press menu of MeetingRoomOrderingModifier: the accessible,
    /// non-drag way to reorder.
    func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt path: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        guard rooms.indices.contains(path.row) else { return nil }
        let room = rooms[path.row]
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            let up = UIAction(title: "Chuyển phòng lên trên", image: UIImage(systemName: "arrow.up")) { _ in self?.move(room, by: -1) }
            let down = UIAction(title: "Chuyển phòng xuống dưới", image: UIImage(systemName: "arrow.down")) { _ in self?.move(room, by: 1) }
            if path.row <= 0 { up.attributes = .disabled }
            if path.row >= (self?.rooms.count ?? 0) - 1 { down.attributes = .disabled }
            return UIMenu(children: [up, down])
        }
    }

    private func move(_ room: MeetingRoom, by offset: Int) {
        guard let index = rooms.firstIndex(where: { $0.id == room.id }), rooms.indices.contains(index + offset) else { return }
        var reordered = rooms
        reordered.swapAt(index, index + offset)
        session.reorderMeetingRooms(reordered)
    }

    // Long-press drag reorders rooms, saved like the iOS 18+ list.
    func tableView(_ tableView: UITableView, itemsForBeginning session: UIDragSession, at path: IndexPath) -> [UIDragItem] {
        let item = UIDragItem(itemProvider: NSItemProvider())
        item.localObject = rooms[path.row].id
        return [item]
    }

    func tableView(_ tableView: UITableView, dropSessionDidUpdate session: UIDropSession,
                   withDestinationIndexPath destinationIndexPath: IndexPath?) -> UITableViewDropProposal {
        session.localDragSession != nil
            ? UITableViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
            : UITableViewDropProposal(operation: .forbidden)
    }

    func tableView(_ tableView: UITableView, performDropWith coordinator: UITableViewDropCoordinator) {
        guard let destination = coordinator.destinationIndexPath,
              let item = coordinator.items.first,
              let roomID = item.dragItem.localObject as? String,
              let from = rooms.firstIndex(where: { $0.id == roomID }) else { return }
        var reordered = rooms
        let room = reordered.remove(at: from)
        reordered.insert(room, at: min(destination.row, reordered.count))
        // Land the lifted card at its new place instead of snapping it back.
        coordinator.drop(item.dragItem, toRowAt: destination)
        self.session.reorderMeetingRooms(reordered)
    }
}

extension LegacyMeetingRoomsController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// "Hôm nay" / "Ngày mai" pills and the calendar button of the iOS 18+ header.
private final class LegacyPillButton: UIButton {
    var isOn = false { didSet { applyStyle() } }

    init(title: String? = nil, weight: UIFont.Weight = .bold, symbol: String? = nil) {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        if let title {
            configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([
                .font: UIFont.preferredFont(forTextStyle: .subheadline).withWeight(weight),
            ]))
        }
        if let symbol {
            configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .bold))
            configuration.contentInsets = .zero
            widthAnchor.constraint(equalToConstant: 38).isActive = true
        }
        self.configuration = configuration
        heightAnchor.constraint(equalToConstant: 38).isActive = true
        layer.cornerRadius = 11
        layer.cornerCurve = .continuous
        applyStyle()
    }
    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyStyle()
    }

    private func applyStyle() {
        backgroundColor = isOn ? .systemRed : .systemBackground
        tintColor = isOn ? .white : .label
        configuration?.baseForegroundColor = isOn ? .white : .label
        layer.borderWidth = isOn ? 0 : 0.8
        layer.borderColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }
}

/// One room card: photo, name, status chip, capacity · equipment, status
/// line and the full-width "Đặt phòng" / "Xem lịch" button (iOS 18+ card).
private final class LegacyRoomCardCell: UITableViewCell {
    static let reuseID = "LegacyRoomCardCell"
    /// Decoded room photos; bounded (the HTTP layer keeps the files).
    private static let imageCache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 40
        cache.totalCostLimit = 32 * 1024 * 1024
        return cache
    }()

    private let card = UIView()
    private let photo = UIImageView()
    private let nameLabel = UILabel()
    private let chip = UIView()
    private let chipDot = UIView()
    private let chipLabel = UILabel()
    private let detailLabel = UILabel()
    private let statusLabel = UILabel()
    private let actionButton = UIButton(configuration: .filled())
    private var onSchedule: () -> Void = {}
    private var onBook: () -> Void = {}
    private var onMoveUp: (() -> Void)?
    private var onMoveDown: (() -> Void)?
    private var available = true
    private var imageTask: Task<Void, Never>?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        selectionStyle = .none

        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = 24
        card.layer.cornerCurve = .continuous
        card.layer.shadowOffset = CGSize(width: 0, height: 3)
        contentView.addSubview(card)

        photo.contentMode = .scaleAspectFill
        photo.clipsToBounds = true
        photo.layer.cornerRadius = 14
        photo.layer.cornerCurve = .continuous
        photo.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.10)
        photo.tintColor = .systemGreen
        photo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            photo.widthAnchor.constraint(equalToConstant: 88),
            photo.heightAnchor.constraint(equalToConstant: 108),
        ])

        nameLabel.font = UIFont.preferredFont(forTextStyle: .headline).withWeight(.bold)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = .label
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        chipDot.layer.cornerRadius = 3
        chipDot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([chipDot.widthAnchor.constraint(equalToConstant: 6), chipDot.heightAnchor.constraint(equalToConstant: 6)])
        chipLabel.font = UIFont.preferredFont(forTextStyle: .caption1).withWeight(.bold)
        let chipStack = UIStackView(arrangedSubviews: [chipDot, chipLabel])
        chipStack.spacing = 4
        chipStack.alignment = .center
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(chipStack)
        chip.layer.cornerRadius = 12
        NSLayoutConstraint.activate([
            chipStack.topAnchor.constraint(equalTo: chip.topAnchor, constant: 5),
            chipStack.bottomAnchor.constraint(equalTo: chip.bottomAnchor, constant: -5),
            chipStack.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 8),
            chipStack.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -8),
        ])
        chip.setContentHuggingPriority(.required, for: .horizontal)
        chip.setContentCompressionResistancePriority(.required, for: .horizontal)

        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = .secondaryLabel
        detailLabel.numberOfLines = 2
        statusLabel.font = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        statusLabel.adjustsFontForContentSizeCategory = true

        let titleRow = UIStackView(arrangedSubviews: [nameLabel, chip])
        titleRow.spacing = 8
        titleRow.alignment = .top
        let info = UIStackView(arrangedSubviews: [titleRow, detailLabel, statusLabel])
        info.axis = .vertical
        info.spacing = 7
        let topRow = UIStackView(arrangedSubviews: [photo, info])
        topRow.spacing = 12
        topRow.alignment = .top
        // Only the photo and text open the schedule (MeetingRoomCard's
        // onTapGesture), not the margins or the button area.
        topRow.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tappedInfo)))

        actionButton.addTarget(self, action: #selector(tappedAction), for: .touchUpInside)
        actionButton.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let column = UIStackView(arrangedSubviews: [topRow, actionButton])
        column.axis = .vertical
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: 12),
            column.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 12),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -12),
        ])
        applyColors()
    }
    required init?(coder: NSCoder) { nil }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageTask?.cancel()
        imageTask = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // A capsule at any Dynamic Type size.
        chip.layer.cornerRadius = chip.bounds.height / 2
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColors()
    }

    func configure(room: MeetingRoom, bookings: [MeetingBooking], day: Date, now: Date,
                   onSchedule: @escaping () -> Void, onBook: @escaping () -> Void,
                   onMoveUp: (() -> Void)?, onMoveDown: (() -> Void)?) {
        self.onSchedule = onSchedule
        self.onBook = onBook
        self.onMoveUp = onMoveUp
        self.onMoveDown = onMoveDown
        let status = LegacyMeetingUI.roomStatus(bookings: bookings, day: day, now: now)
        available = status.available

        nameLabel.text = room.name
        detailLabel.text = "\(room.capacity) chỗ · \(room.equipment.isEmpty ? "Thiết bị đang cập nhật" : room.equipment.joined(separator: " · "))"
        statusLabel.text = status.text
        chipLabel.text = available ? "Trống" : "Đang họp"
        accessibilityLabel = "\(room.name), \(available ? "Trống" : "Đang họp"), \(status.text)"
        // One VoiceOver item per card; its actions are the card's controls.
        var actions = [
            UIAccessibilityCustomAction(name: available ? "Đặt phòng" : "Xem lịch") { [weak self] _ in self?.tappedAction(); return true },
        ]
        if available {
            actions.append(UIAccessibilityCustomAction(name: "Xem lịch") { [weak self] _ in self?.onSchedule(); return true })
        }
        if let onMoveUp { actions.append(UIAccessibilityCustomAction(name: "Chuyển phòng lên trên") { _ in onMoveUp(); return true }) }
        if let onMoveDown { actions.append(UIAccessibilityCustomAction(name: "Chuyển phòng xuống dưới") { _ in onMoveDown(); return true }) }
        accessibilityCustomActions = actions

        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: available ? "calendar.badge.plus" : "calendar",
                                      withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium))
        configuration.imagePadding = 7
        configuration.attributedTitle = AttributedString(available ? "Đặt phòng" : "Xem lịch", attributes: AttributeContainer([
            .font: UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.bold),
        ]))
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 12
        actionButton.configuration = configuration
        applyColors()
        loadPhoto(room)
    }

    private func applyColors() {
        let dark = traitCollection.userInterfaceStyle == .dark
        // Same surfaces as the iOS 18+ card on iOS 17.
        card.backgroundColor = dark ? UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1) : .white
        card.layer.shadowColor = UIColor.black.cgColor
        card.layer.shadowOpacity = dark ? 0.24 : 0.05
        card.layer.shadowRadius = dark ? 14 : 8
        card.layer.shadowOffset = CGSize(width: 0, height: dark ? 6 : 3)
        let statusColor: UIColor = available ? .systemGreen : .systemRed
        chipDot.backgroundColor = statusColor
        chip.backgroundColor = statusColor.withAlphaComponent(0.12)
        chipLabel.textColor = UIColor(AppTheme.text(Color(statusColor), chipAlpha: 0.12))
        statusLabel.textColor = UIColor(AppTheme.text(Color(statusColor)))
        actionButton.configuration?.baseBackgroundColor = available
            ? .systemRed
            : (dark ? UIColor.white.withAlphaComponent(0.12) : UIColor.black.withAlphaComponent(0.07))
        actionButton.configuration?.baseForegroundColor = available ? .white : .label
    }

    private func loadPhoto(_ room: MeetingRoom) {
        let placeholder = UIImage(systemName: "building.2.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 31, weight: .bold))
        photo.contentMode = .center
        photo.image = placeholder
        let value = room.imageUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value.hasPrefix("/") ? "https://sukavinagroup.net\(value)" : value),
              url.scheme?.hasPrefix("http") == true else { return }
        if let cached = Self.imageCache.object(forKey: url as NSURL) {
            photo.contentMode = .scaleAspectFill
            photo.image = cached
            return
        }
        imageTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data), !Task.isCancelled else { return }
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            Self.imageCache.setObject(image, forKey: url as NSURL, cost: cost)
            self?.photo.contentMode = .scaleAspectFill
            self?.photo.image = image
        }
    }

    @objc private func tappedAction() { available ? onBook() : onSchedule() }
    @objc private func tappedInfo() { onSchedule() }
}

/// The day schedule of a room (or of the employee's own meetings) as the
/// same timeline iOS 18+ shows: hours 06:00–23:00, a label per meeting with
/// connectors to its start and end, a red current-time marker, a day picker
/// and a booking button. UIKit, so iOS 17 never builds the SwiftUI timeline
/// (see the iOS 17 crash rules); the label placement is the shared
/// `MeetingScheduleLayout`, so both versions place every meeting identically.
@MainActor
private final class LegacyMeetingScheduleController: UIViewController {
    private let session: SessionStore
    private let room: MeetingRoom
    private var day: Date
    private var cancellable: AnyCancellable?
    private let scrollView = UIScrollView()
    private let timeline = LegacyMeetingTimelineView()
    private let datePicker = UIDatePicker()
    private let header = UIStackView()

    init(session: SessionStore, room: MeetingRoom, day: Date) {
        self.session = session; self.room = room; self.day = day
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = room.name
        navigationItem.largeTitleDisplayMode = .always
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Đóng", style: .plain, target: self, action: #selector(closeSheet))

        // "Ngày" and a compact day picker inside the scrolling content, as in
        // MeetingRoomScheduleSheet; past days cannot be booked.
        let dayLabel = UILabel()
        dayLabel.text = "Ngày"
        dayLabel.font = .preferredFont(forTextStyle: .body)
        dayLabel.adjustsFontForContentSizeCategory = true
        datePicker.datePickerMode = .date
        datePicker.preferredDatePickerStyle = .compact
        datePicker.locale = Locale(identifier: "vi_VN")
        datePicker.timeZone = VietnamTime.timeZone
        datePicker.calendar = VietnamTime.calendar
        datePicker.minimumDate = VietnamTime.calendar.startOfDay(for: Date())
        datePicker.date = day
        datePicker.addTarget(self, action: #selector(dayChanged), for: .valueChanged)
        [dayLabel, UIView(), datePicker].forEach(header.addArrangedSubview)
        header.alignment = .center
        header.isLayoutMarginsRelativeArrangement = true
        header.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 12, trailing: 16)

        let content = UIStackView(arrangedSubviews: [header, timeline])
        content.axis = .vertical
        content.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        timeline.onSelect = { [weak self] booking in self?.openDetail(booking) }
        scrollView.addSubview(content)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            content.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            timeline.heightAnchor.constraint(equalToConstant: LegacyMeetingTimelineView.timelineHeight),
        ])

        // The green "+" floats over the timeline, as on iOS 18.
        let book = UIButton(type: .system)
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2).applying(UIImage.SymbolConfiguration(weight: .bold)))
        configuration.baseBackgroundColor = .systemGreen
        configuration.baseForegroundColor = .white
        configuration.cornerStyle = .capsule
        book.configuration = configuration
        book.accessibilityLabel = "Đặt phòng \(room.name)"
        book.layer.shadowColor = UIColor.black.cgColor
        book.layer.shadowOpacity = 0.2
        book.layer.shadowRadius = 8
        book.layer.shadowOffset = CGSize(width: 0, height: 4)
        book.addTarget(self, action: #selector(bookRoom), for: .touchUpInside)
        book.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(book)
        NSLayoutConstraint.activate([
            book.widthAnchor.constraint(equalToConstant: 58),
            book.heightAnchor.constraint(equalToConstant: 58),
            book.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -22),
            book.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -22),
        ])

        // `bookings` is published after `bookingsByRoom`: both are current here.
        cancellable = session.meetings.$bookings.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
        reload()
        // Like the sheet's .task: load, then centre today's current hour.
        Task { [weak self] in
            guard let self else { return }
            await session.refreshMeetingSchedule(date: day)
            scrollToCurrentHour()
        }
    }

    /// `proxy.scrollTo(hour, anchor: .center)`: the current hour's row centred.
    private func scrollToCurrentHour() {
        let calendar = MeetingPresentation.calendar
        guard calendar.isDateInToday(day) else { return }
        let hour = calendar.component(.hour, from: Date())
        guard hour >= LegacyMeetingTimelineView.firstHour, hour <= LegacyMeetingTimelineView.lastHour else { return }
        view.layoutIfNeeded()
        let rowCenter = header.frame.maxY
            + CGFloat(hour - LegacyMeetingTimelineView.firstHour) * LegacyMeetingTimelineView.hourHeight
            + LegacyMeetingTimelineView.hourHeight / 2
        let inset = scrollView.adjustedContentInset
        let visible = scrollView.bounds.height - inset.top - inset.bottom
        let minOffset = -inset.top
        let maxOffset = max(minOffset, scrollView.contentSize.height + inset.bottom - scrollView.bounds.height)
        scrollView.setContentOffset(CGPoint(x: 0, y: min(max(minOffset, rowCenter - inset.top - visible / 2), maxOffset)), animated: false)
    }

    private func reload() {
        // The store's bookings for this room, as MeetingRoomScheduleSheet shows them.
        timeline.update(bookings: session.meetings.bookingsByRoom[room.id] ?? [], day: day)
    }

    @objc private func dayChanged() {
        day = datePicker.date
        reload()
        Task { await session.refreshMeetingSchedule(date: day) }
    }

    @objc private func closeSheet() { dismiss(animated: true) }

    @objc private func bookRoom() {
        LegacyMeetingUI.presentBooking(session: session, room: room, day: day, from: self)
    }

    private func openDetail(_ meeting: MeetingBooking) {
        // Other people's private bookings carry no id and no details.
        guard !meeting.id.isEmpty else { return }
        LegacyMeetingUI.presentSheet(LegacyMeetingDetailController(session: session, room: room, meeting: meeting), from: self)
    }
}

/// UIKit drawing of `MeetingTimeline` (MeetingScheduleTimeline.swift).
@MainActor
private final class LegacyMeetingTimelineView: UIView {
    static let firstHour = 6
    static let lastHour = 23
    static let hourHeight: CGFloat = 72
    static var timelineHeight: CGFloat { hourHeight * CGFloat(lastHour - firstHour + 1) }
    /// Hour labels: 56 pt wide plus 8 pt of trailing padding.
    private static let gutter: CGFloat = 64

    var onSelect: (MeetingBooking) -> Void = { _ in }
    private var bookings: [MeetingBooking] = []
    private var day = Date()
    private var hourLabels: [UILabel] = []
    private var hourRows: [UIView] = []
    private let lanesView = UIView()
    private let nowLine = UIView()
    private let nowLabel = UILabel()
    private var minuteTimer: Timer?
    private var renderedWidth: CGFloat = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        for hour in Self.firstHour...Self.lastHour {
            let label = UILabel()
            label.text = String(format: "%02d:00", hour)
            label.font = UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 12, weight: .regular))
            label.adjustsFontForContentSizeCategory = true
            label.textColor = .secondaryLabel
            label.textAlignment = .right
            addSubview(label)
            hourLabels.append(label)

            let row = UIView()
            row.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.035)
            let line = UIView()
            line.backgroundColor = UIColor.secondaryLabel.withAlphaComponent(0.12)
            line.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
            line.frame = CGRect(x: 0, y: Self.hourHeight - 1, width: 0, height: 1)
            row.addSubview(line)
            addSubview(row)
            hourRows.append(row)
        }
        lanesView.clipsToBounds = true
        addSubview(lanesView)
        nowLine.backgroundColor = .systemRed
        nowLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption2).pointSize, weight: .bold)
        nowLabel.textColor = .white
        nowLabel.backgroundColor = .systemRed
        nowLabel.textAlignment = .center
        nowLine.isUserInteractionEnabled = false
        nowLabel.isUserInteractionEnabled = false
        addSubview(nowLine)
        addSubview(nowLabel)
    }
    required init?(coder: NSCoder) { nil }

    deinit { minuteTimer?.invalidate() }

    func update(bookings: [MeetingBooking], day: Date) {
        self.bookings = bookings
        self.day = day
        renderLabels()
        updateNowMarker()
        scheduleMinuteTimer()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            minuteTimer?.invalidate()
            minuteTimer = nil
        } else {
            updateNowMarker()
            scheduleMinuteTimer()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = bounds.width
        for (index, label) in hourLabels.enumerated() {
            label.frame = CGRect(x: 0, y: CGFloat(index) * Self.hourHeight, width: 56, height: 16)
        }
        for (index, row) in hourRows.enumerated() {
            row.frame = CGRect(x: Self.gutter, y: CGFloat(index) * Self.hourHeight, width: max(0, width - Self.gutter), height: Self.hourHeight)
        }
        lanesView.frame = CGRect(x: Self.gutter, y: 0, width: max(0, width - Self.gutter), height: Self.timelineHeight)
        if renderedWidth != lanesView.bounds.width { renderLabels() }
        updateNowMarker()
    }

    /// Labels, connectors and dots for the current bookings and width.
    private func renderLabels() {
        lanesView.subviews.forEach { $0.removeFromSuperview() }
        lanesView.layer.sublayers?.filter { $0 is CAShapeLayer }.forEach { $0.removeFromSuperlayer() }
        let width = lanesView.bounds.width
        renderedWidth = width
        guard width > 0 else { return }

        let inset = MeetingScheduleLabelMetrics.horizontalInset
        let fullAvailable = max(1, width - inset * 2)
        let centeredWidth = min(max(180, width - 48), fullAvailable)
        let laneWidth = max(1, (width - inset * 2 - MeetingScheduleLabelMetrics.laneGap) / 2)

        let slots = MeetingScheduleLayout.slots(
            bookings: bookings, firstHour: Self.firstHour, lastHour: Self.lastHour, hourHeight: Self.hourHeight
        )
        for slot in slots {
            let style = LegacyTimelineStyle(for: slot.item.booking)
            let geometry: (left: CGFloat, width: CGFloat)
            switch slot.lane {
            case .center: geometry = ((width - centeredWidth) / 2, centeredWidth)
            case .left: geometry = (inset, laneWidth)
            case .right: geometry = (width - inset - laneWidth, laneWidth)
            }
            addConnector(slot: slot, geometry: geometry, width: width, style: style)
            let label = LegacyTimelineLabel(booking: slot.item.booking, style: style)
            label.frame = CGRect(x: geometry.left, y: slot.labelTop, width: geometry.width, height: MeetingScheduleLabelMetrics.height)
            label.addAction(UIAction { [weak self] _ in self?.onSelect(slot.item.booking) }, for: .touchUpInside)
            lanesView.addSubview(label)
        }
    }

    private func addConnector(slot: MeetingScheduleLayout.Slot, geometry: (left: CGFloat, width: CGFloat), width: CGFloat, style: LegacyTimelineStyle) {
        let labelRight = geometry.left + geometry.width
        let labelCenterY = slot.labelTop + MeetingScheduleLabelMetrics.height / 2
        let leftRail: CGFloat = 4
        let rightRail = max(4, width - 4)
        let startX: CGFloat = slot.lane == .right ? width / 2 + 4 : leftRail
        let endX: CGFloat = slot.lane == .left ? width / 2 - 4 : rightRail

        let path = UIBezierPath()
        Self.appendElbow(to: path, from: CGPoint(x: startX, y: slot.startY), to: CGPoint(x: geometry.left, y: labelCenterY), verticalFirst: true)
        Self.appendElbow(to: path, from: CGPoint(x: labelRight, y: labelCenterY), to: CGPoint(x: endX, y: slot.endY), verticalFirst: false)
        let line = CAShapeLayer()
        line.path = path.cgPath
        line.fillColor = nil
        line.strokeColor = style.line.withAlphaComponent(0.72).cgColor
        line.lineWidth = 1
        line.lineCap = .round
        line.lineJoin = .round
        lanesView.layer.addSublayer(line)

        for (x, y, onRail) in [(startX, slot.startY, startX == leftRail), (endX, slot.endY, endX == rightRail)] {
            let size: CGFloat = onRail ? 4 : 3.4
            let dot = CAShapeLayer()
            dot.path = UIBezierPath(ovalIn: CGRect(x: x - size / 2, y: y - size / 2, width: size, height: size)).cgPath
            dot.fillColor = style.line.withAlphaComponent(0.88).cgColor
            lanesView.layer.addSublayer(dot)
        }
    }

    /// The rounded L-shaped connector of MeetingScheduleConnector: vertical
    /// then horizontal from the booking start, horizontal then vertical to
    /// the booking end.
    private static func appendElbow(to path: UIBezierPath, from start: CGPoint, to end: CGPoint, verticalFirst: Bool) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let radius = min(MeetingScheduleLabelMetrics.cornerRadius, abs(dx), abs(dy))
        let sx: CGFloat = dx > 0 ? 1 : dx < 0 ? -1 : 0
        let sy: CGFloat = dy > 0 ? 1 : dy < 0 ? -1 : 0
        path.move(to: start)
        if radius > 0 {
            if verticalFirst {
                path.addLine(to: CGPoint(x: start.x, y: end.y - sy * radius))
                path.addQuadCurve(to: CGPoint(x: start.x + sx * radius, y: end.y), controlPoint: CGPoint(x: start.x, y: end.y))
            } else {
                path.addLine(to: CGPoint(x: end.x - sx * radius, y: start.y))
                path.addQuadCurve(to: CGPoint(x: end.x, y: start.y + sy * radius), controlPoint: CGPoint(x: end.x, y: start.y))
            }
        }
        path.addLine(to: end)
    }

    private func updateNowMarker() {
        let offset = MeetingScheduleLayout.currentOffset(
            day: day, now: Date(), firstHour: Self.firstHour, lastHour: Self.lastHour, hourHeight: Self.hourHeight
        )
        nowLine.isHidden = offset == nil
        nowLabel.isHidden = offset == nil
        guard let offset else { return }
        nowLine.frame = CGRect(x: Self.gutter, y: offset, width: max(0, bounds.width - Self.gutter), height: 2)
        nowLabel.text = MeetingPresentation.clock.string(from: Date())
        let size = nowLabel.intrinsicContentSize
        nowLabel.frame = CGRect(x: Self.gutter, y: offset - 13, width: size.width + 14, height: size.height + 8)
        bringSubviewToFront(nowLine)
        bringSubviewToFront(nowLabel)
    }

    /// The marker moves once a minute, only while today's timeline is shown
    /// (the one per-minute exception of the event-driven rule: the clock).
    private func scheduleMinuteTimer() {
        minuteTimer?.invalidate()
        minuteTimer = nil
        guard window != nil, MeetingPresentation.calendar.isDateInToday(day) else { return }
        let now = Date()
        let nextMinute = VietnamTime.calendar.nextDate(after: now, matching: DateComponents(second: 0), matchingPolicy: .nextTime) ?? now.addingTimeInterval(60)
        let timer = Timer(fire: nextMinute, interval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateNowMarker() }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }
}

/// UIKit colours of `MeetingTimeline.bookingStyle(for:)`.
private struct LegacyTimelineStyle {
    let fill: UIColor
    let border: UIColor
    let foreground: UIColor
    let meta: UIColor
    let line: UIColor

    init(for booking: MeetingBooking) {
        func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor { UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1) }
        if booking.isOwner == true {
            fill = rgb(220, 239, 226); border = rgb(143, 198, 160); foreground = rgb(46, 106, 67); meta = rgb(92, 127, 104); line = rgb(166, 207, 178)
        } else if booking.isMine == true {
            fill = rgb(220, 233, 250); border = rgb(142, 180, 232); foreground = rgb(49, 92, 145); meta = rgb(96, 126, 167); line = rgb(168, 195, 232)
        } else {
            fill = rgb(229, 231, 235); border = rgb(184, 190, 199); foreground = rgb(89, 97, 109); meta = rgb(119, 127, 137); line = rgb(195, 200, 207)
        }
    }
}

/// One meeting's pill: title · organiser on the left, time range on the right.
private final class LegacyTimelineLabel: UIControl {
    init(booking: MeetingBooking, style: LegacyTimelineStyle) {
        super.init(frame: .zero)
        backgroundColor = style.fill
        layer.cornerRadius = 18
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.8
        layer.borderColor = style.border.withAlphaComponent(0.96).cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.035
        layer.shadowRadius = 1.5
        layer.shadowOffset = CGSize(width: 0, height: 0.5)

        let title = UILabel()
        title.text = [booking.title.isEmpty ? "Đã có lịch" : booking.title, booking.organizerName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        title.font = .systemFont(ofSize: 10.5, weight: .semibold)
        title.textColor = style.foreground
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let time = UILabel()
        time.text = MeetingPresentation.range(booking)
        time.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        time.textColor = style.meta
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [title, time])
        row.spacing = 7
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = booking.id.isEmpty ? .staticText : .button
        accessibilityLabel = booking.id.isEmpty
            ? "Khung giờ đã được đặt, \(MeetingPresentation.range(booking))"
            : "Xem chi tiết cuộc họp \(booking.title.isEmpty ? "đã có lịch" : booking.title), \(MeetingPresentation.range(booking))"
    }
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }
}

/// The booking form of iOS 18+ (`MeetingBookingSheet`) rebuilt in UIKit for
/// iOS 17, section by section: header, meeting details with the start and
/// duration wheels and the expected time, invitations (people and
/// departments, invite a whole department, capacity), a floating confirm
/// card that names what blocks the booking, an alert when booking fails
/// and a discard confirmation. Presented as a sheet, like on iOS 18.
@MainActor
private final class LegacyMeetingBookingController: UIViewController, UITextFieldDelegate {
    private let session: SessionStore
    private let room: MeetingRoom
    private let day: Date

    // Form state (mirrors MeetingBookingSheet).
    private var meetingType = "Nội bộ"
    private var start = Date()
    private var durationMinutes = 30
    private var selected = Set<String>()
    private var selectedDepartments = Set<String>()
    private var inviteesError: String?
    private var isSubmitting = false
    private var invitees: [MeetingInvitee] = []
    private var cancellable: AnyCancellable?

    private let red = UIColor.systemRed

    // Views that persist (text fields keep focus); the rest is re-rendered.
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let titleField = UITextField()
    private let peopleField = UITextField()
    private let departmentField = UITextField()
    private let typeControl = UISegmentedControl(items: ["Nội bộ", "Tiếp khách"])
    // Built once and updated in place: re-creating the picker while its
    // system overlay is open would cut the employee off mid-choice.
    // Each tile draws its value and lets a control underneath take the tap:
    // Apple's compact time picker under each tile (TileFillingPickerView);
    // Apple's own time bubble opens from each.
    private let startTileControl = TileFillingPickerView()
    private var startTimePicker: UIDatePicker { startTileControl.picker }
    private let startValueLabel = UILabel()
    private let durationTileControl = TileFillingPickerView()
    private var durationPicker: UIDatePicker { durationTileControl.picker }
    private let durationValueLabel = UILabel()
    private let expectedLabel = UILabel()
    private let countBadge = UILabel()
    private let selectedSection = UIStackView()
    private let departmentChipsSection = UIStackView()
    private let inviteAllSection = UIStackView()
    private let peopleResults = UIStackView()
    private let departmentResults = UIStackView()
    private let errorSection = UIStackView()
    private let hintLabel = UILabel()
    private let capacityLabel = UILabel()
    private let blockLabel = UILabel()
    private var blockRow: UIView?
    private let confirmButton = UIButton(type: .system)
    private var keyboardObservers: [NSObjectProtocol] = []

    init(session: SessionStore, room: MeetingRoom, day: Date) {
        self.session = session; self.room = room; self.day = day
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    // MARK: Derived values

    private var endTime: Date { start.addingTimeInterval(Double(durationMinutes * 60)) }
    private var blockReason: String? {
        MeetingBookingTime.blockReason(
            start: start, now: Date(), attendeeCount: selected.count + 1,
            capacity: room.capacity, calendar: MeetingPresentation.calendar
        )
    }
    private var hasUnsavedInput: Bool {
        !(titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !selected.isEmpty
    }
    private var bookingTitle: String {
        let text = (titleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? meetingType : "\(meetingType) · \(text)"
    }
    private var query: String { (peopleField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var departmentQuery: String { (departmentField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
    private var people: [MeetingInvitee] {
        guard !query.isEmpty || !selectedDepartments.isEmpty else { return [] }
        return invitees.filter {
            (selectedDepartments.isEmpty || selectedDepartments.contains($0.department))
                && (query.isEmpty
                    || $0.fullName.localizedCaseInsensitiveContains(query)
                    || $0.employeeCode.localizedCaseInsensitiveContains(query))
        }
    }
    private var departments: [String] {
        Array(Set(invitees.map(\.department).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
    private var matchingDepartments: [String] {
        guard !departmentQuery.isEmpty else { return [] }
        return departments.filter { $0.localizedCaseInsensitiveContains(departmentQuery) }
    }
    private var unselectedDepartmentInvitees: [MeetingInvitee] {
        guard !selectedDepartments.isEmpty else { return [] }
        return invitees.filter { selectedDepartments.contains($0.department) && !selected.contains($0.id) }
    }
    private var canInviteEntireDepartment: Bool {
        selected.count + unselectedDepartmentInvitees.count + 1 <= room.capacity
    }

    // MARK: Layout

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let closeItem = UIBarButtonItem(title: "Đóng", style: .plain, target: self, action: #selector(close))
        let closeFont = UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        closeItem.setTitleTextAttributes([.font: closeFont], for: .normal)
        closeItem.setTitleTextAttributes([.font: closeFont], for: .highlighted)
        navigationItem.rightBarButtonItem = closeItem
        start = MeetingBookingTime.defaultStart(on: day, now: Date(), calendar: MeetingPresentation.calendar)

        scroll.showsVerticalScrollIndicator = false
        scroll.keyboardDismissMode = .interactive
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        view.addSubview(scroll)

        let bottomBar = makeConfirmCard()
        view.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomBar.topAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 12),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
            bottomBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bottomBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            // Above the keyboard while typing, above the home indicator otherwise.
            bottomBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -8),
        ])

        content.addArrangedSubview(makeHeader())
        content.addArrangedSubview(makeDetailsCard())
        content.addArrangedSubview(makeInviteesCard())

        invitees = session.meetings.invitees
        // The scroll view ends at the confirm card, which follows the keyboard
        // (keyboardLayoutGuide). When a field gains focus the keyboard is not
        // up yet, so scrolling then found the field "visible" and the keyboard
        // covered it a moment later. Scroll again once the keyboard's final
        // frame is laid out, as MeetingBookingSheet does on iOS 18.
        for name in [UIResponder.keyboardDidShowNotification, UIResponder.keyboardDidChangeFrameNotification] {
            keyboardObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.keepFocusedFieldVisible(animated: true) }
            })
        }
        UIFlowLog.record("sheet.appear", "legacy.booking")
        cancellable = session.meetings.$invitees.receive(on: RunLoop.main).sink { [weak self] value in
            // Rebuilds the invitation card while the employee may be typing.
            UIFlowLog.record("legacy.booking.renderInvitees", "cause=inviteesChanged")
            self?.invitees = value
            self?.renderInvitees()
        }
        render()
        Task { [weak self] in
            guard let self else { return }
            inviteesError = await session.refreshMeetingInvitees()
            renderInvitees()
        }
    }

    private func makeHeader() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "calendar.badge.plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .bold)))
        icon.tintColor = .white
        icon.contentMode = .center
        icon.backgroundColor = red
        icon.layer.cornerRadius = 17
        icon.layer.cornerCurve = .continuous
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([icon.widthAnchor.constraint(equalToConstant: 54), icon.heightAnchor.constraint(equalToConstant: 54)])

        let kicker = label("ĐẶT PHÒNG", style: .caption1, weight: .bold, color: red)
        let name = label(room.name, style: .title3, weight: .bold, color: .label)
        let meta = label("\(room.capacity) chỗ · \(VietnamTime.weekdayDate.string(from: day).capitalized)", style: .caption1, color: .secondaryLabel)
        let texts = UIStackView(arrangedSubviews: [kicker, name, meta])
        texts.axis = .vertical
        texts.spacing = 3
        let row = UIStackView(arrangedSubviews: [icon, texts])
        row.spacing = 12
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        return row
    }

    private func makeDetailsCard() -> UIView {
        let card = cardStack()
        card.addArrangedSubview(sectionTitle("Thông tin cuộc họp", icon: "text.bubble.fill"))

        // Apple's segmented control, as on iOS 18.
        typeControl.accessibilityLabel = "Loại cuộc họp"
        typeControl.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.meetingType = self.typeControl.titleForSegment(at: self.typeControl.selectedSegmentIndex) ?? self.meetingType
            self.render()
        }, for: .valueChanged)
        card.addArrangedSubview(typeControl)

        let contentLabel = label("Nội dung cuộc họp", style: .caption1, weight: .semibold, color: .secondaryLabel)
        styleField(titleField, placeholder: "Ví dụ: Họp kế hoạch tuần", icon: nil, height: 48)
        titleField.delegate = self
        titleField.addAction(UIAction { [weak self] _ in self?.renderConfirm() }, for: .editingChanged)
        let titleGroup = UIStackView(arrangedSubviews: [contentLabel, fieldContainer(titleField, icon: nil, height: 48)])
        titleGroup.axis = .vertical
        titleGroup.spacing = 7
        card.addArrangedSubview(titleGroup)

        // The two facts of a booking as tiles, as on iOS 18
        // (MeetingBookingSheet): when it starts (hh:mm) and how long it
        // lasts. Both open Apple's compact time bubble, so one tap moves
        // from either to the other (a system menu for Thời lượng could
        // not hand over to the time bubble).
        configureStartTimePicker()
        configureDurationPicker()
        let tiles = UIStackView(arrangedSubviews: [
            makeTile(title: "Bắt đầu", icon: "clock.fill", valueLabel: startValueLabel, control: startTileControl),
            makeTile(title: "Thời lượng", icon: "timer", valueLabel: durationValueLabel, control: durationTileControl),
        ])
        tiles.spacing = 10
        tiles.distribution = .fillEqually
        card.addArrangedSubview(tiles)
        renderDuration()

        let clockIcon = UIImageView(image: UIImage(systemName: "clock.arrow.circlepath"))
        clockIcon.tintColor = red
        clockIcon.setContentHuggingPriority(.required, for: .horizontal)
        let expectedTitle = label("Thời gian dự kiến", style: .caption1, color: .secondaryLabel)
        expectedLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .bold)
        let expectedTexts = UIStackView(arrangedSubviews: [expectedTitle, expectedLabel])
        expectedTexts.axis = .vertical
        expectedTexts.spacing = 1
        let expected = UIStackView(arrangedSubviews: [clockIcon, expectedTexts, UIView()])
        expected.spacing = 9
        expected.alignment = .center
        expected.isLayoutMarginsRelativeArrangement = true
        expected.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12)
        expected.backgroundColor = red.withAlphaComponent(0.08)
        expected.layer.cornerRadius = 13
        expected.layer.cornerCurve = .continuous
        card.addArrangedSubview(expected)
        return card
    }

    private func makeInviteesCard() -> UIView {
        let card = cardStack()
        countBadge.font = .preferredFont(forTextStyle: .caption1).withWeight(.bold)
        countBadge.textColor = red
        let badge = LegacyCapsuleView(content: countBadge, insets: NSDirectionalEdgeInsets(top: 5, leading: 9, bottom: 5, trailing: 9))
        badge.backgroundColor = red.withAlphaComponent(0.10)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        let titleRow = UIStackView(arrangedSubviews: [sectionTitle("Mời người tham gia", icon: "person.2.fill"), UIView(), badge])
        titleRow.alignment = .center
        card.addArrangedSubview(titleRow)

        for section in [selectedSection, departmentChipsSection, inviteAllSection, peopleResults, departmentResults, errorSection] {
            section.axis = .vertical
            section.spacing = 8
        }
        card.addArrangedSubview(selectedSection)
        card.addArrangedSubview(departmentChipsSection)
        card.addArrangedSubview(inviteAllSection)

        styleField(peopleField, placeholder: "Tìm tên hoặc mã nhân viên", icon: "magnifyingglass", height: 46)
        styleField(departmentField, placeholder: "Tìm phòng ban", icon: "building.2", height: 46)
        for field in [peopleField, departmentField] {
            field.delegate = self
            field.addAction(UIAction { [weak self] _ in self?.renderInvitees(followFocus: true) }, for: .editingChanged)
        }
        // Results sit right above their field, like on iOS 18.
        card.addArrangedSubview(peopleResults)
        card.addArrangedSubview(fieldContainer(peopleField, icon: "magnifyingglass", height: 46))
        card.addArrangedSubview(departmentResults)
        card.addArrangedSubview(fieldContainer(departmentField, icon: "building.2", height: 46))
        card.addArrangedSubview(errorSection)

        hintLabel.text = "Gõ tên nhân viên hoặc chọn phòng ban để hiển thị danh sách."
        hintLabel.font = .preferredFont(forTextStyle: .caption1)
        hintLabel.textColor = .secondaryLabel
        hintLabel.numberOfLines = 0
        capacityLabel.font = .preferredFont(forTextStyle: .caption1)
        capacityLabel.textColor = .secondaryLabel
        capacityLabel.numberOfLines = 0
        card.addArrangedSubview(hintLabel)
        card.addArrangedSubview(capacityLabel)
        return card
    }

    private func makeConfirmCard() -> UIView {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        blur.layer.cornerRadius = 25
        blur.layer.cornerCurve = .continuous
        blur.clipsToBounds = true
        blur.layer.borderWidth = 0.75
        blur.layer.borderColor = UIColor.label.withAlphaComponent(0.07).cgColor
        blur.translatesAutoresizingMaskIntoConstraints = false

        blockLabel.font = .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        blockLabel.textColor = .secondaryLabel
        blockLabel.numberOfLines = 0

        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 16
        configuration.imagePadding = 8
        confirmButton.configuration = configuration
        // The system's disabled look would replace these colours.
        confirmButton.configurationUpdateHandler = { [weak self] button in
            guard let self, var updated = button.configuration else { return }
            let canConfirm = blockReason == nil && !isSubmitting
            updated.baseBackgroundColor = canConfirm ? red : .systemGray3
            updated.baseForegroundColor = .white
            updated.background.backgroundColor = canConfirm ? red : .systemGray3
            button.configuration = updated
        }
        confirmButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        confirmButton.addTarget(self, action: #selector(submit), for: .touchUpInside)

        let blockRow = UIStackView(arrangedSubviews: [blockLabel])
        blockRow.isLayoutMarginsRelativeArrangement = true
        blockRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 6, bottom: 0, trailing: 6)
        self.blockRow = blockRow
        let stack = UIStackView(arrangedSubviews: [blockRow, confirmButton])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: blur.contentView.topAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor, constant: -8),
            stack.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor, constant: -8),
        ])
        return blur
    }

    // MARK: Rendering

    private func render() {
        typeControl.selectedSegmentIndex = meetingType == "Tiếp khách" ? 1 : 0
        if startTimePicker.date != start { startTimePicker.date = start }
        startValueLabel.text = MeetingPresentation.clock.string(from: start)
        renderDuration()
        expectedLabel.text = "\(MeetingPresentation.clock.string(from: start)) – \(MeetingPresentation.clock.string(from: endTime))"
        renderInvitees()
    }

    private func renderConfirm() {
        let reason = isSubmitting ? nil : blockReason
        blockRow?.isHidden = reason == nil
        if let reason {
            let text = NSMutableAttributedString(attributedString: NSAttributedString(attachment: NSTextAttachment(image: UIImage(systemName: "info.circle") ?? UIImage())))
            text.append(NSAttributedString(string: " " + reason))
            blockLabel.attributedText = text
        }
        let enabled = reason == nil && !isSubmitting
        var configuration = confirmButton.configuration ?? .filled()
        configuration.baseBackgroundColor = enabled ? red : .systemGray3
        configuration.baseForegroundColor = .white
        configuration.image = isSubmitting ? nil : UIImage(systemName: "checkmark.circle.fill")
        configuration.showsActivityIndicator = isSubmitting
        var title = AttributedString(isSubmitting ? "Đang đặt phòng..." : "Xác nhận đặt phòng")
        title.font = .preferredFont(forTextStyle: .headline).withWeight(.bold)
        configuration.attributedTitle = title
        confirmButton.configuration = configuration
        confirmButton.isEnabled = enabled
        confirmButton.setNeedsUpdateConfiguration()
        // Swiping the sheet down asks first once something was entered.
        navigationController?.isModalInPresentation = hasUnsavedInput || isSubmitting
    }

    /// The invitation card's dynamic parts. With [followFocus] (typing, or
    /// people/departments added) the focused search field stays above the
    /// keyboard; removing someone only shrinks a list and does not jump.
    private func renderInvitees(followFocus: Bool = false) {
        countBadge.text = "\(selected.count) người"

        // "Đã chọn"
        selectedSection.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let chosen = invitees.filter { selected.contains($0.id) }
        selectedSection.isHidden = chosen.isEmpty
        if !chosen.isEmpty {
            let box = UIStackView()
            box.axis = .vertical
            box.spacing = 8
            box.isLayoutMarginsRelativeArrangement = true
            box.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11)
            box.backgroundColor = .secondarySystemBackground
            box.layer.cornerRadius = 13
            box.layer.cornerCurve = .continuous
            box.addArrangedSubview(label("Đã chọn", style: .caption1, weight: .semibold, color: .secondaryLabel))
            for person in chosen { box.addArrangedSubview(selectedRow(person)) }
            selectedSection.addArrangedSubview(box)
        }

        // Selected departments
        departmentChipsSection.arrangedSubviews.forEach { $0.removeFromSuperview() }
        departmentChipsSection.isHidden = selectedDepartments.isEmpty
        if !selectedDepartments.isEmpty {
            departmentChipsSection.addArrangedSubview(label("Phòng ban đã chọn", style: .caption1, weight: .semibold, color: .secondaryLabel))
            var chips: [UIView] = [chip("Bỏ chọn tất cả", filled: false) { [weak self] in
                self?.selectedDepartments.removeAll()
                self?.peopleField.text = ""
                self?.renderInvitees()
            }]
            for department in selectedDepartments.sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
                chips.append(chip(department, filled: true) { [weak self] in
                    self?.selectedDepartments.remove(department)
                    self?.renderInvitees()
                })
            }
            departmentChipsSection.addArrangedSubview(horizontalScroller(chips, height: 44))
        }

        // Invite a whole department
        inviteAllSection.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let remaining = unselectedDepartmentInvitees
        inviteAllSection.isHidden = selectedDepartments.isEmpty || remaining.isEmpty
        if !inviteAllSection.isHidden {
            var configuration = UIButton.Configuration.tinted()
            configuration.baseBackgroundColor = red
            configuration.baseForegroundColor = red
            configuration.image = UIImage(systemName: "person.3.fill")
            configuration.imagePadding = 6
            var title = AttributedString("Mời tất cả \(remaining.count) người thuộc \(selectedDepartments.count) phòng ban")
            title.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
            configuration.attributedTitle = title
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 12, bottom: 11, trailing: 12)
            let button = UIButton(configuration: configuration)
            button.isEnabled = canInviteEntireDepartment
            button.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                selected.formUnion(unselectedDepartmentInvitees.map(\.id))
                renderInvitees(followFocus: true)
            }, for: .touchUpInside)
            inviteAllSection.addArrangedSubview(button)
            if !canInviteEntireDepartment {
                let note = label("Số người trong phòng ban vượt quá số chỗ còn lại của phòng họp.", style: .caption1, color: .secondaryLabel)
                inviteAllSection.addArrangedSubview(note)
            }
        }

        // People results (above the people field)
        peopleResults.arrangedSubviews.forEach { $0.removeFromSuperview() }
        peopleResults.isHidden = query.isEmpty && selectedDepartments.isEmpty
        if !peopleResults.isHidden {
            let found = people
            let panel = resultsPanel()
            if found.isEmpty {
                panel.addArrangedSubview(label("Không tìm thấy người phù hợp.", style: .caption1, color: .secondaryLabel))
            } else {
                panel.addArrangedSubview(label("Kết quả người tham gia", style: .caption1, weight: .semibold, color: .secondaryLabel))
                panel.addArrangedSubview(horizontalScroller(found.map(personResult), height: 62))
            }
            peopleResults.addArrangedSubview(panel)
        }

        // Department results (above the department field)
        departmentResults.arrangedSubviews.forEach { $0.removeFromSuperview() }
        departmentResults.isHidden = departmentQuery.isEmpty
        if !departmentResults.isHidden {
            let panel = resultsPanel()
            let found = matchingDepartments
            if found.isEmpty {
                panel.addArrangedSubview(label("Không tìm thấy phòng ban phù hợp.", style: .caption1, color: .secondaryLabel))
            } else {
                panel.addArrangedSubview(label("Kết quả phòng ban", style: .caption1, weight: .semibold, color: .secondaryLabel))
                let chips = found.map { department in
                    chip(department, filled: selectedDepartments.contains(department), neutralWhenOff: true) { [weak self] in
                        guard let self else { return }
                        if selectedDepartments.contains(department) {
                            selectedDepartments.remove(department)
                        } else {
                            selectedDepartments.insert(department)
                            peopleField.text = ""
                        }
                        renderInvitees(followFocus: selectedDepartments.contains(department))
                    }
                }
                panel.addArrangedSubview(horizontalScroller(chips, height: 48))
            }
            departmentResults.addArrangedSubview(panel)
        }

        // Load error
        errorSection.arrangedSubviews.forEach { $0.removeFromSuperview() }
        errorSection.isHidden = inviteesError == nil
        if let inviteesError {
            errorSection.addArrangedSubview(label(inviteesError, style: .caption1, color: .systemRed))
            let retry = UIButton(type: .system)
            var title = AttributedString("Tải lại danh sách mời")
            title.font = .preferredFont(forTextStyle: .caption1).withWeight(.bold)
            retry.setAttributedTitle(NSAttributedString(title), for: .normal)
            retry.contentHorizontalAlignment = .leading
            retry.addAction(UIAction { [weak self] _ in
                Task { [weak self] in
                    guard let self else { return }
                    self.inviteesError = await self.session.refreshMeetingInvitees()
                    renderInvitees()
                }
            }, for: .touchUpInside)
            errorSection.addArrangedSubview(retry)
        }

        hintLabel.isHidden = !(query.isEmpty && selectedDepartments.isEmpty)
        capacityLabel.text = "\(selected.count + 1)/\(room.capacity) chỗ · gồm bạn và người được mời"
        renderConfirm()

        if followFocus, let field = [peopleField, departmentField].first(where: \.isFirstResponder) {
            keepVisible(field, animated: false)
        }
    }

    /// The focused field's whole rounded box (not only its text) just above
    /// the confirm card, which itself sits on the keyboard.
    private func keepVisible(_ field: UITextField, animated: Bool) {
        view.layoutIfNeeded()
        let box = field.superview?.superview ?? field
        let rect = box.convert(box.bounds, to: scroll).insetBy(dx: 0, dy: -10)
        scroll.scrollRectToVisible(rect, animated: animated)
    }

    private func keepFocusedFieldVisible(animated: Bool) {
        guard let field = [titleField, peopleField, departmentField].first(where: \.isFirstResponder) else { return }
        keepVisible(field, animated: animated)
    }

    // MARK: Pieces

    private func selectedRow(_ person: MeetingInvitee) -> UIView {
        let initial = UILabel()
        initial.text = String(person.fullName.prefix(1)).uppercased()
        initial.font = .preferredFont(forTextStyle: .caption1).withWeight(.bold)
        initial.textColor = red
        initial.textAlignment = .center
        initial.backgroundColor = red.withAlphaComponent(0.14)
        initial.layer.cornerRadius = 15
        initial.layer.masksToBounds = true
        initial.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([initial.widthAnchor.constraint(equalToConstant: 30), initial.heightAnchor.constraint(equalToConstant: 30)])
        let name = label(person.fullName, style: .subheadline, weight: .medium, color: .label)
        let department = label(person.department, style: .caption1, color: .secondaryLabel)
        let texts = UIStackView(arrangedSubviews: [name, department])
        texts.axis = .vertical
        texts.spacing = 1
        let remove = UIButton(type: .system)
        remove.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        remove.tintColor = .tertiaryLabel
        remove.accessibilityLabel = "Bỏ mời \(person.fullName)"
        remove.addAction(UIAction { [weak self] _ in
            // Removing only shrinks this list: no jump to a search field.
            self?.selected.remove(person.id)
            self?.renderInvitees()
        }, for: .touchUpInside)
        remove.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([remove.widthAnchor.constraint(equalToConstant: 44), remove.heightAnchor.constraint(equalToConstant: 44)])
        let row = UIStackView(arrangedSubviews: [initial, texts, UIView(), remove])
        row.spacing = 9
        row.alignment = .center
        return row
    }

    private func personResult(_ person: MeetingInvitee) -> UIView {
        let isChosen = selected.contains(person.id)
        let control = UIControl()
        control.backgroundColor = isChosen ? red.withAlphaComponent(0.10) : .secondarySystemBackground
        control.layer.cornerRadius = 12
        control.layer.cornerCurve = .continuous
        let icon = UIImageView(image: UIImage(systemName: isChosen ? "checkmark.circle.fill" : "plus.circle"))
        icon.tintColor = isChosen ? red : .secondaryLabel
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let name = label(person.fullName, style: .subheadline, weight: .semibold, color: .label)
        name.numberOfLines = 1
        let meta = label("\(person.employeeCode) · \(person.department)", style: .caption1, color: .secondaryLabel)
        meta.numberOfLines = 1
        let texts = UIStackView(arrangedSubviews: [name, meta])
        texts.axis = .vertical
        texts.spacing = 2
        let row = UIStackView(arrangedSubviews: [icon, texts])
        row.spacing = 8
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: control.topAnchor, constant: 9),
            row.bottomAnchor.constraint(equalTo: control.bottomAnchor, constant: -9),
            row.leadingAnchor.constraint(equalTo: control.leadingAnchor, constant: 11),
            row.trailingAnchor.constraint(equalTo: control.trailingAnchor, constant: -11),
            control.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])
        let full = !isChosen && selected.count + 1 >= room.capacity
        control.isEnabled = !full
        control.alpha = full ? 0.45 : 1
        control.accessibilityLabel = "\(isChosen ? "Bỏ mời" : "Mời") \(person.fullName)"
        control.isAccessibilityElement = true
        control.accessibilityTraits = .button
        control.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            let adding = !selected.contains(person.id)
            if adding { selected.insert(person.id) } else { selected.remove(person.id) }
            renderInvitees(followFocus: adding)
        }, for: .touchUpInside)
        return control
    }

    private func chip(_ title: String, filled: Bool, neutralWhenOff: Bool = false, action: @escaping () -> Void) -> UIView {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.baseBackgroundColor = filled ? red : .secondarySystemBackground
        configuration.baseForegroundColor = filled ? .white : .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        var text = AttributedString(title)
        text.font = .preferredFont(forTextStyle: .subheadline).withWeight(.semibold)
        configuration.attributedTitle = text
        configuration.titleLineBreakMode = .byTruncatingTail
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    private func horizontalScroller(_ views: [UIView], height: CGFloat) -> UIView {
        let scroller = UIScrollView()
        scroller.showsHorizontalScrollIndicator = false
        scroller.clipsToBounds = false
        let row = UIStackView(arrangedSubviews: views)
        row.spacing = 8
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        scroller.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroller.heightAnchor.constraint(equalToConstant: height),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor, constant: 1),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor, constant: -1),
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            row.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
        ])
        return scroller
    }

    private func resultsPanel() -> UIStackView {
        let panel = UIStackView()
        panel.axis = .vertical
        panel.spacing = 5
        panel.isLayoutMarginsRelativeArrangement = true
        panel.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)
        panel.backgroundColor = .systemBackground
        panel.layer.cornerRadius = 13
        panel.layer.cornerCurve = .continuous
        panel.layer.shadowColor = UIColor.black.cgColor
        panel.layer.shadowOpacity = 0.10
        panel.layer.shadowRadius = 8
        panel.layer.shadowOffset = CGSize(width: 0, height: 3)
        return panel
    }

    private func cardStack() -> UIStackView {
        let card = UIStackView()
        card.axis = .vertical
        card.spacing = 14
        card.isLayoutMarginsRelativeArrangement = true
        card.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 16, leading: 16, bottom: 16, trailing: 16)
        card.backgroundColor = .systemBackground
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = UIColor.black.withAlphaComponent(0.06).cgColor
        return card
    }

    private func sectionTitle(_ text: String, icon: String) -> UIView {
        let image = UIImageView(image: UIImage(systemName: icon))
        image.tintColor = .label
        image.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium)
        image.setContentHuggingPriority(.required, for: .horizontal)
        let title = label(text, style: .subheadline, weight: .bold, color: .label)
        let row = UIStackView(arrangedSubviews: [image, title])
        row.spacing = 8
        row.alignment = .center
        return row
    }

    /// The system's compact time picker, in Vietnam time and 5-minute steps
    /// (`MeetingBookingTime.minuteStep`).
    private func configureStartTimePicker() {
        startTileControl.name = "Bắt đầu"
        startTimePicker.datePickerMode = .time
        startTimePicker.preferredDatePickerStyle = .compact
        startTimePicker.minuteInterval = MeetingBookingTime.minuteStep
        startTimePicker.timeZone = VietnamTime.timeZone
        startTimePicker.calendar = VietnamTime.calendar
        startTimePicker.locale = VietnamTime.locale
        startTimePicker.date = start
        startTimePicker.accessibilityLabel = "Bắt đầu"
        startTimePicker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            // Only the hour and minute, so the booking stays on its day.
            let calendar = MeetingPresentation.calendar
            let time = calendar.dateComponents([.hour, .minute], from: self.startTimePicker.date)
            self.start = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0, of: self.start) ?? self.start
            self.render()
        }, for: .valueChanged)
    }

    /// A start or duration tile, as on iOS 18: icon and chevron, caption,
    /// value. `control` fills the tile underneath and takes every tap; the
    /// drawn face on top covers it and takes none. Built once; `render()`
    /// only updates `valueLabel`.
    private func makeTile(title: String, icon: String, valueLabel: UILabel, control: UIView) -> UIView {
        let tile = UIView()
        tile.layer.cornerRadius = 14
        tile.layer.cornerCurve = .continuous
        tile.clipsToBounds = true

        control.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(control)

        let face = UIView()
        face.backgroundColor = .secondarySystemBackground
        face.isUserInteractionEnabled = false
        // VoiceOver reads the control underneath instead.
        face.accessibilityElementsHidden = true
        face.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(face)

        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = red
        let chevron = UIImageView(image: UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .medium)
        ))
        chevron.tintColor = .secondaryLabel
        let top = UIStackView(arrangedSubviews: [iconView, UIView(), chevron])
        top.alignment = .center
        let titleLabel = label(title, style: .caption1, color: .secondaryLabel)
        valueLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .bold)
        valueLabel.textColor = .label
        let stack = UIStackView(arrangedSubviews: [top, titleLabel, valueLabel])
        stack.axis = .vertical
        stack.spacing = 7
        stack.translatesAutoresizingMaskIntoConstraints = false
        face.addSubview(stack)

        NSLayoutConstraint.activate([
            control.topAnchor.constraint(equalTo: tile.topAnchor),
            control.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            control.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            face.topAnchor.constraint(equalTo: tile.topAnchor),
            face.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            face.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            face.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            stack.topAnchor.constraint(equalTo: face.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: face.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: face.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: face.trailingAnchor, constant: -12),
        ])
        return tile
    }

    /// The system's compact time picker read as a length of time, as on
    /// iOS 18: "01:30" is 1 giờ 30 phút; 5-minute steps, 00:05 to 08:00
    /// (`MeetingBookingTime.durationRange`).
    private func configureDurationPicker() {
        let calendar = VietnamTime.calendar
        durationTileControl.name = "Thời lượng"
        durationPicker.datePickerMode = .time
        durationPicker.preferredDatePickerStyle = .compact
        durationPicker.minuteInterval = MeetingBookingTime.minuteStep
        durationPicker.timeZone = VietnamTime.timeZone
        durationPicker.calendar = calendar
        durationPicker.locale = VietnamTime.locale
        durationPicker.minimumDate = MeetingBookingTime.clockDate(forDuration: MeetingBookingTime.durationRange.lowerBound, calendar: calendar)
        durationPicker.maximumDate = MeetingBookingTime.clockDate(forDuration: MeetingBookingTime.durationRange.upperBound, calendar: calendar)
        durationPicker.date = MeetingBookingTime.clockDate(forDuration: durationMinutes, calendar: calendar)
        durationPicker.accessibilityLabel = "Thời lượng"
        durationPicker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.durationMinutes = MeetingBookingTime.durationMinutes(fromClock: self.durationPicker.date, calendar: VietnamTime.calendar)
            self.render()
        }, for: .valueChanged)
    }

    /// The Thời lượng tile's value, and its picker kept on it.
    private func renderDuration() {
        durationValueLabel.text = MeetingBookingTime.durationTitle(minutes: durationMinutes)
        let clock = MeetingBookingTime.clockDate(forDuration: durationMinutes, calendar: VietnamTime.calendar)
        if durationPicker.date != clock { durationPicker.date = clock }
    }

    private func label(_ text: String, style: UIFont.TextStyle, weight: UIFont.Weight? = nil, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        let font = UIFont.preferredFont(forTextStyle: style)
        label.font = weight.map { font.withWeight($0) } ?? font
        label.textColor = color
        label.numberOfLines = 0
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    private func styleField(_ field: UITextField, placeholder: String, icon: String?, height: CGFloat) {
        field.placeholder = placeholder
        field.font = .preferredFont(forTextStyle: icon == nil ? .body : .subheadline)

    }

    private func fieldContainer(_ field: UITextField, icon: String?, height: CGFloat) -> UIView {
        let box = UIView()
        box.backgroundColor = .secondarySystemBackground
        box.layer.cornerRadius = 13
        box.layer.cornerCurve = .continuous
        let row = UIStackView(arrangedSubviews: [field])
        if let icon {
            let image = UIImageView(image: UIImage(systemName: icon))
            image.tintColor = .secondaryLabel
            image.setContentHuggingPriority(.required, for: .horizontal)
            row.insertArrangedSubview(image, at: 0)
        }
        row.spacing = 9
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(row)
        NSLayoutConstraint.activate([
            box.heightAnchor.constraint(equalToConstant: height),
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 13),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -13),
            row.topAnchor.constraint(equalTo: box.topAnchor),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    // MARK: Text fields

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        // Moving between fields with the keyboard already up sends no
        // keyboard notification: scroll for the new field here too.
        DispatchQueue.main.async { [weak self] in self?.keepVisible(textField, animated: true) }
    }

    deinit {
        keyboardObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: Actions

    @objc private func close() {
        guard hasUnsavedInput else {
            dismiss(animated: true)
            return
        }
        let sheet = UIAlertController(
            title: "Bỏ lịch đang đặt?",
            message: "Tiêu đề và người được mời bạn đã chọn sẽ không được lưu.",
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: "Bỏ lịch", style: .destructive) { [weak self] _ in self?.dismiss(animated: true) })
        sheet.addAction(UIAlertAction(title: "Tiếp tục đặt", style: .cancel))
        sheet.popoverPresentationController?.barButtonItem = navigationItem.rightBarButtonItem
        present(sheet, animated: true)
    }

    @objc private func submit() {
        guard blockReason == nil, !isSubmitting else { return }
        view.endEditing(true)
        isSubmitting = true
        renderInvitees()
        Task { [weak self] in
            guard let self else { return }
            let failure = await session.createMeeting(
                room: room, title: bookingTitle, start: start,
                duration: durationMinutes, participants: Array(selected)
            )
            if let failure {
                isSubmitting = false
                renderInvitees()
                showError(failure)
            } else {
                dismiss(animated: true)
            }
        }
    }

    /// Apple's alert, as on iOS 18, which stays until it is read and
    /// dismissed (it was a dark notice drawn at the top that hid itself
    /// after five seconds).
    private func showError(_ message: String) {
        let alert = UIAlertController(title: "Không thể đặt phòng", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Đã hiểu", style: .cancel))
        present(alert, animated: true)
    }
}

/// `MeetingBookingDetailSheet` (iOS 18+) in UIKit for iOS 17: the role-
/// coloured hero card, time / place / equipment / organiser / participants
/// cards (limited view for HR), the organiser's meeting controls (extend in
/// 5-minute steps up to the next booking, end with confirmation) and
/// cancelling a future booking. Follows live schedule changes.
@MainActor
private final class LegacyMeetingDetailController: UIViewController {
    private let session: SessionStore
    private let room: MeetingRoom
    private let meeting: MeetingBooking
    private var details: MeetingBookingDetails?
    private var isCancelling = false
    private var extensionMinutes = 5
    private var isSubmittingControl = false
    private var controlAction: String?
    private var controlError: String?
    private var cancellable: AnyCancellable?
    private let scroll = UIScrollView()
    private let content = UIStackView()

    init(session: SessionStore, room: MeetingRoom, meeting: MeetingBooking) {
        self.session = session; self.room = room; self.meeting = meeting
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    // MARK: Derived values (as in MeetingBookingDetailSheet)

    private var isOwner: Bool { meeting.isOwner == true }
    private var isLimitedViewer: Bool { details?.isLimitedViewer == true }
    private var accent: UIColor { isOwner ? UIColor(red: 0.13, green: 0.71, blue: 0.45, alpha: 1) : .systemBlue }
    private var roleTitle: String {
        if isLimitedViewer { return "Thông tin giới hạn dành cho Phòng Nhân sự" }
        return isOwner ? "Bạn là người tổ chức" : "Bạn được mời tham dự"
    }
    private var roleIcon: String {
        isLimitedViewer ? "lock.shield.fill" : isOwner ? "person.badge.key.fill" : "person.2.badge.gearshape.fill"
    }
    /// The live schedule copy: an end or extension shows at once.
    private var current: MeetingBooking {
        session.meetings.bookings.first(where: { $0.id == meeting.id }) ?? meeting
    }
    private var displayedRoom: MeetingRoom { details?.room ?? room }
    private var meetingStarted: Bool { current.startDate.map { $0 <= Date() } ?? false }
    private var meetingEnded: Bool { current.endDate.map { $0 <= Date() } ?? false }
    private var dateTitle: String {
        guard let start = current.startDate else { return "Chưa xác định" }
        return VietnamTime.weekdayLongDate.string(from: start).capitalized
    }
    private var durationTitle: String {
        guard let start = current.startDate, let end = current.endDate else { return "—" }
        let minutes = max(0, Int(end.timeIntervalSince(start) / 60))
        return minutes >= 60 ? "\(minutes / 60) giờ\(minutes % 60 == 0 ? "" : " \(minutes % 60) phút")" : "\(minutes) phút"
    }
    private var canCancel: Bool {
        guard isOwner, current.status == "confirmed", let start = current.startDate else { return false }
        return start > Date()
    }
    private var canShowMeetingControls: Bool { isOwner && current.status == "confirmed" && meetingStarted }
    private var nextBooking: MeetingBooking? {
        guard let end = current.endDate else { return nil }
        return session.meetings.bookings
            .filter { $0.roomId == current.roomId && $0.id != current.id }
            .filter { ($0.startDate ?? .distantPast) > end }
            .min { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }
    private var maximumExtensionMinutes: Int {
        guard let end = current.endDate else { return 0 }
        guard let nextStart = nextBooking?.startDate else { return 120 }
        return min(120, max(0, Int(nextStart.timeIntervalSince(end) / 60) - 5))
    }
    private var extensionBlockMessage: String {
        guard let nextBooking else { return "Không thể gia hạn vì lịch phòng đang được cập nhật." }
        let title = nextBooking.title.isEmpty ? "cuộc họp tiếp theo" : "“\(nextBooking.title)”"
        return "Không thể gia hạn vì \(displayedRoom.name) có \(title) lúc \(MeetingPresentation.time(nextBooking.startsAt))."
    }

    // MARK: Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Chi tiết cuộc họp"
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Đóng", style: .plain, target: self, action: #selector(close))
        view.backgroundColor = .systemGroupedBackground
        scroll.showsVerticalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .vertical
        content.spacing = 18
        content.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(content)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
            content.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 20),
            content.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -20),
        ])
        details = session.cachedMeetingBookingDetails(id: meeting.id)
        UIFlowLog.record("sheet.appear", "legacy.meetingDetail")
        cancellable = session.meetings.$bookings.receive(on: RunLoop.main).sink { [weak self] _ in
            // Rebuilds every subview of the open detail sheet.
            UIFlowLog.record("legacy.meetingDetail.render", "cause=bookingsChanged")
            self?.render()
        }
        render()
        Task { [weak self] in
            guard let self else { return }
            if let loaded = await session.meetingBookingDetails(id: meeting.id) {
                details = loaded
                render()
            }
        }
    }

    @objc private func close() { dismiss(animated: true) }

    // MARK: Rendering

    private func render() {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        content.addArrangedSubview(heroCard())

        var time: [UIView] = [
            label(MeetingPresentation.range(current), font: .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize, weight: .bold)),
            label(dateTitle, style: .subheadline, color: .secondaryLabel),
        ]
        if !isLimitedViewer {
            let pills = UIStackView(arrangedSubviews: [pill(durationTitle, icon: "timer"), pill("\(current.attendeeCount) người", icon: "person.2.fill"), UIView()])
            pills.spacing = 8
            time.append(pills)
        }
        content.addArrangedSubview(card("Thời gian", icon: "clock.fill", time))

        if !isLimitedViewer {
            var place: [UIView] = [label(displayedRoom.name, style: .headline)]
            if !displayedRoom.location.isEmpty {
                place.append(iconLabel(displayedRoom.location, icon: "mappin.and.ellipse", style: .subheadline, color: .secondaryLabel))
            }
            place.append(label("Sức chứa phòng: \(displayedRoom.capacity) người", style: .caption1, weight: .medium, color: .secondaryLabel))
            content.addArrangedSubview(card("Địa điểm", icon: "building.2.fill", place))
            if !displayedRoom.equipment.isEmpty {
                content.addArrangedSubview(card("Thiết bị sẵn có", icon: "display.2", [
                    label(displayedRoom.equipment.joined(separator: "  ·  "), style: .subheadline, weight: .medium, color: .secondaryLabel),
                ]))
            }
        }

        if let details {
            if isLimitedViewer {
                content.addArrangedSubview(card("Thông tin cuộc họp", icon: "lock.shield.fill", [
                    iconLabel("Loại cuộc họp: \(details.title)", icon: "tag.fill", style: .headline, color: .label),
                    iconLabel("Người tổ chức: \(details.employee.fullName)", icon: "person.crop.circle.fill", style: .subheadline, weight: .semibold, color: .label),
                ]))
            } else {
                let organiserMeta = [details.employee.employeeCode, details.employee.department, details.employee.jobTitle]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: " · ")
                content.addArrangedSubview(card("Người tổ chức", icon: "person.crop.circle.fill", [
                    label(details.employee.fullName, style: .headline),
                    label(organiserMeta, style: .subheadline, color: .secondaryLabel),
                ]))
                let people: [UIView] = details.participants.isEmpty
                    ? [label("Chưa có người được mời thêm.", style: .subheadline, color: .secondaryLabel)]
                    : details.participants.map { label($0.employee.fullName, style: .subheadline, weight: .medium) as UIView }
                content.addArrangedSubview(card("Người tham gia (\(details.participants.count))", icon: "person.2.fill", people))
            }
        } else {
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.startAnimating()
            let loading = UIStackView(arrangedSubviews: [spinner, label("Đang tải thông tin người tham gia…", style: .caption1, color: .secondaryLabel), UIView()])
            loading.spacing = 8
            content.addArrangedSubview(loading)
        }

        if canShowMeetingControls { content.addArrangedSubview(controlCard()) }

        if canCancel {
            var configuration = UIButton.Configuration.tinted()
            configuration.baseBackgroundColor = .systemRed
            configuration.baseForegroundColor = .systemRed
            configuration.image = UIImage(systemName: "calendar.badge.minus")
            configuration.imagePadding = 6
            configuration.contentInsets = NSDirectionalEdgeInsets(top: 14, leading: 12, bottom: 14, trailing: 12)
            var title = AttributedString(isCancelling ? "Đang hủy lịch…" : "Hủy lịch")
            title.font = .preferredFont(forTextStyle: .headline)
            configuration.attributedTitle = title
            let cancel = UIButton(configuration: configuration)
            cancel.isEnabled = !isCancelling
            cancel.addAction(UIAction { [weak self] _ in self?.confirmCancel() }, for: .touchUpInside)
            content.addArrangedSubview(cancel)
        }

        let footer = label("Thông tin được đồng bộ theo thời gian thực.", style: .caption1, color: .secondaryLabel)
        footer.textAlignment = .center
        content.addArrangedSubview(footer)
    }

    private func heroCard() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "calendar.badge.clock", withConfiguration: UIImage.SymbolConfiguration(textStyle: .title2, scale: .medium).applying(UIImage.SymbolConfiguration(weight: .bold))))
        icon.tintColor = .white
        icon.contentMode = .center
        let iconBox = LegacyGradientView(colors: [accent, accent.withAlphaComponent(0.78)])
        iconBox.layer.cornerRadius = 18
        iconBox.layer.cornerCurve = .continuous
        iconBox.clipsToBounds = true
        iconBox.addSubview(icon)
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 54), iconBox.heightAnchor.constraint(equalToConstant: 54),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor), icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
        ])
        let status = chip(current.status == "confirmed" ? "Đã xác nhận" : current.status, icon: "checkmark.seal.fill")
        let top = UIStackView(arrangedSubviews: [iconBox, UIView(), status])
        top.alignment = .top
        let title = UILabel()
        title.text = current.title.isEmpty ? "Cuộc họp" : current.title
        title.numberOfLines = 0
        let rounded = UIFont.systemFont(ofSize: 27, weight: .bold).fontDescriptor.withDesign(.rounded)
        title.font = rounded.map { UIFont(descriptor: $0, size: 27) } ?? .systemFont(ofSize: 27, weight: .bold)
        let role = iconLabel(roleTitle, icon: roleIcon, style: .subheadline, weight: .semibold, color: accent)
        let stack = UIStackView(arrangedSubviews: [top, title, role])
        stack.axis = .vertical
        stack.spacing = 15
        stack.translatesAutoresizingMaskIntoConstraints = false
        let hero = LegacyGradientView(colors: [accent.withAlphaComponent(0.18), .secondarySystemBackground], diagonal: true)
        hero.layer.cornerRadius = 26
        hero.layer.cornerCurve = .continuous
        hero.clipsToBounds = true
        hero.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: hero.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -20),
        ])
        return hero
    }

    private func controlCard() -> UIView {
        let green = UIColor(AppTheme.text(.green))
        var rows: [UIView] = [
            iconLabel(meetingEnded ? "Cuộc họp đã kết thúc" : "Điều khiển cuộc họp",
                      icon: meetingEnded ? "checkmark.circle.fill" : "slider.horizontal.3",
                      style: .headline, weight: .bold, color: green),
        ]
        if meetingEnded {
            rows.append(label("Cuộc họp đã kết thúc. Bạn không thể gia hạn hoặc kết thúc lại.", style: .subheadline, color: .secondaryLabel))
        } else {
            if let controlError {
                let error = label(controlError, style: .caption1, weight: .semibold, color: .systemRed)
                rows.append(padded(error, background: UIColor.systemRed.withAlphaComponent(0.1), radius: 12, inset: 10))
            }
            if maximumExtensionMinutes >= 5 {
                // Apple's stepper, as on iOS 18.
                let amount = label("Gia hạn thêm \(extensionMinutes) phút", style: .subheadline, weight: .bold, color: UIColor(AppTheme.text(.green, chipAlpha: 0.08)))
                let stepper = UIStepper()
                stepper.minimumValue = 5
                stepper.maximumValue = Double(maximumExtensionMinutes)
                stepper.stepValue = 5
                stepper.value = Double(extensionMinutes)
                stepper.isEnabled = !isSubmittingControl
                stepper.accessibilityLabel = "Gia hạn thêm"
                stepper.addAction(UIAction { [weak self, weak amount, weak stepper] _ in
                    guard let self, let stepper else { return }
                    self.extensionMinutes = Int(stepper.value)
                    amount?.text = "Gia hạn thêm \(self.extensionMinutes) phút"
                    // Rebuilt only to clear an error: rebuilding on every
                    // step would end a press-and-hold on the stepper.
                    if self.controlError != nil {
                        self.controlError = nil
                        self.render()
                    }
                }, for: .valueChanged)
                let steps = UIStackView(arrangedSubviews: [amount, stepper])
                steps.spacing = 10
                steps.alignment = .center
                rows.append(steps)
                let extending = isSubmittingControl && controlAction == "extend"
                rows.append(prominentButton(extending ? "Đang gia hạn…" : "Xác nhận gia hạn", icon: "checkmark",
                                            color: .systemGreen, busy: extending) { [weak self] in
                    Task { await self?.submitMeetingControl("extend") }
                })
            } else {
                let unavailable = iconLabel("Gia hạn không khả dụng", icon: "clock.badge.exclamationmark", style: .body, color: .secondaryLabel)
                let centred = UIStackView(arrangedSubviews: [UIView(), unavailable, UIView()])
                centred.distribution = .equalCentering
                rows.append(centred)
                rows.append(label(extensionBlockMessage, style: .caption1, weight: .semibold, color: .systemRed))
            }
            let ending = isSubmittingControl && controlAction == "end"
            rows.append(prominentButton(ending ? "Đang kết thúc…" : "Kết thúc cuộc họp", icon: "stop.fill",
                                        color: .systemRed, busy: ending) { [weak self] in self?.confirmEnd() })
        }
        let stack = UIStackView(arrangedSubviews: rows)
        stack.axis = .vertical
        stack.spacing = 14
        return padded(stack, background: .secondarySystemBackground, radius: 22, inset: 18)
    }

    // MARK: Actions

    private func confirmCancel() {
        let alert = UIAlertController(title: "Hủy lịch họp?", message: "Những người được mời sẽ nhận được thông báo lịch họp đã hủy.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Không", style: .cancel))
        alert.addAction(UIAlertAction(title: "Hủy lịch", style: .destructive) { [weak self] _ in
            guard let self else { return }
            isCancelling = true
            render()
            Task {
                let error = await self.session.cancelMeeting(id: self.meeting.id, scheduledAt: self.meeting.startsAt)
                self.isCancelling = false
                if let error {
                    self.render()
                    let failed = UIAlertController(title: "Chưa thể hủy lịch", message: error, preferredStyle: .alert)
                    failed.addAction(UIAlertAction(title: "Đã hiểu", style: .cancel))
                    self.present(failed, animated: true)
                } else {
                    self.dismiss(animated: true)
                }
            }
        })
        present(alert, animated: true)
    }

    private func confirmEnd() {
        // Irreversible: ask first.
        let sheet = UIAlertController(title: "Kết thúc cuộc họp?", message: "Phòng sẽ được giải phóng ngay để người khác có thể đặt. Không thể hoàn tác.", preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Kết thúc", style: .destructive) { [weak self] _ in
            Task { await self?.submitMeetingControl("end") }
        })
        sheet.addAction(UIAlertAction(title: "Tiếp tục họp", style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        sheet.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
        present(sheet, animated: true)
    }

    private func submitMeetingControl(_ action: String) async {
        guard !isSubmittingControl else { return }
        isSubmittingControl = true
        controlAction = action
        controlError = nil
        render()
        let error = await session.performMeetingControl(bookingID: current.id, action: action, extensionMinutes: extensionMinutes)
        controlError = error
        if error == nil { extensionMinutes = 5 }
        controlAction = nil
        isSubmittingControl = false
        render()
    }

    // MARK: Pieces

    private func card(_ title: String, icon: String, _ rows: [UIView]) -> UIView {
        let stack = UIStackView(arrangedSubviews: [iconLabel(title, icon: icon, style: .subheadline, weight: .bold, color: accent)] + rows)
        stack.axis = .vertical
        stack.spacing = 13
        stack.alignment = .fill
        return padded(stack, background: .secondarySystemBackground, radius: 22, inset: 18)
    }

    private func padded(_ inner: UIView, background: UIColor, radius: CGFloat, inset: CGFloat) -> UIView {
        let box = UIView()
        box.backgroundColor = background
        box.layer.cornerRadius = radius
        box.layer.cornerCurve = .continuous
        inner.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: inset),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -inset),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: inset),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -inset),
        ])
        return box
    }

    private func pill(_ text: String, icon: String) -> UIView {
        capsule(iconLabel(text, icon: icon, style: .caption1, weight: .semibold, color: accent))
    }

    private func chip(_ text: String, icon: String) -> UIView {
        capsule(iconLabel(text, icon: icon, style: .caption1, weight: .bold, color: accent))
    }

    private func capsule(_ content: UIView) -> UIView {
        let box = LegacyCapsuleView(content: content, insets: NSDirectionalEdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
        box.backgroundColor = accent.withAlphaComponent(0.12)
        box.setContentHuggingPriority(.required, for: .horizontal)
        return box
    }

    private func label(_ text: String, style: UIFont.TextStyle = .body, weight: UIFont.Weight? = nil, color: UIColor = .label) -> UILabel {
        let font = UIFont.preferredFont(forTextStyle: style)
        return label(text, font: weight.map { font.withWeight($0) } ?? font, color: color)
    }

    private func label(_ text: String, font: UIFont, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = font
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func iconLabel(_ text: String, icon: String, style: UIFont.TextStyle, weight: UIFont.Weight? = nil, color: UIColor) -> UIView {
        let image = UIImageView(image: UIImage(systemName: icon, withConfiguration: UIImage.SymbolConfiguration(textStyle: style)))
        image.tintColor = color
        image.setContentHuggingPriority(.required, for: .horizontal)
        image.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [image, label(text, style: style, weight: weight, color: color)])
        row.spacing = 6
        row.alignment = .firstBaseline
        return row
    }

    private func prominentButton(_ title: String, icon: String, color: UIColor, busy: Bool, action: @escaping () -> Void) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.baseBackgroundColor = color
        configuration.baseForegroundColor = .white
        configuration.image = busy ? nil : UIImage(systemName: icon)
        configuration.showsActivityIndicator = busy
        configuration.imagePadding = 8
        configuration.attributedTitle = AttributedString(title)
        let button = UIButton(configuration: configuration)
        button.isEnabled = !isSubmittingControl
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}

/// `MyMeetingsSheet` in UIKit: the employee's meetings as cards, upcoming or
/// past (segmented control or a horizontal swipe), with the meeting count.
@MainActor
private final class LegacyMyMeetingsController: UIViewController {
    private let session: SessionStore
    private let day: Date
    private var showsUpcoming = true
    private var cancellable: AnyCancellable?
    private let countValue = UILabel()
    private let countCaption = UILabel()
    private let filter = UISegmentedControl(items: ["Sắp tới", "Đã qua"])
    private let list = UIStackView()
    private static let cardColors: [UIColor] = [.systemRed, .systemBlue, .systemGreen, .systemOrange, .systemPurple, .systemTeal]

    init(session: SessionStore, day: Date) {
        self.session = session; self.day = day
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    private var meetings: [MeetingBooking] {
        session.meetings.bookings
            .filter { $0.isMine ?? false }
            .filter { meeting in
                guard let end = meeting.endDate else { return showsUpcoming }
                return showsUpcoming ? end >= Date() : end < Date()
            }
            .sorted { $0.startsAt < $1.startsAt }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        let closeButton = UIButton(type: .system)
        closeButton.setImage(UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline, scale: .medium).applying(UIImage.SymbolConfiguration(weight: .bold))), for: .normal)
        closeButton.tintColor = .label
        closeButton.backgroundColor = .secondarySystemBackground
        closeButton.layer.cornerRadius = 17
        closeButton.accessibilityLabel = "Đóng lịch của tôi"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        let closeArea = UIControl()
        closeArea.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .touchUpInside)
        closeArea.addSubview(closeButton)
        closeArea.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            closeButton.widthAnchor.constraint(equalToConstant: 34), closeButton.heightAnchor.constraint(equalToConstant: 34),
            closeButton.centerXAnchor.constraint(equalTo: closeArea.centerXAnchor), closeButton.centerYAnchor.constraint(equalTo: closeArea.centerYAnchor),
            closeArea.widthAnchor.constraint(equalToConstant: 44), closeArea.heightAnchor.constraint(equalToConstant: 44),
        ])
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: closeArea)

        let scroll = UIScrollView()
        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView(arrangedSubviews: [header(), filterBox(), list])
        stack.axis = .vertical
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        list.axis = .vertical
        list.spacing = 12
        scroll.addSubview(stack)
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -34),
            stack.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        view.addGestureRecognizer(pan)
        cancellable = session.meetings.$bookings.receive(on: RunLoop.main).sink { [weak self] _ in self?.render() }
        render()
        Task { await session.refreshMeetingSchedule(date: day) }
    }

    private func header() -> UIView {
        let title = UILabel()
        title.text = "Lịch của tôi"
        let rounded = UIFont.systemFont(ofSize: 29, weight: .bold).fontDescriptor.withDesign(.rounded)
        title.font = rounded.map { UIFont(descriptor: $0, size: 29) } ?? .systemFont(ofSize: 29, weight: .bold)
        let date = UILabel()
        date.text = VietnamTime.weekdayLongDayMonth.string(from: day).capitalized
        date.font = .preferredFont(forTextStyle: .subheadline)
        date.textColor = .secondaryLabel
        let titles = UIStackView(arrangedSubviews: [title, date])
        titles.axis = .vertical
        titles.spacing = 4

        countValue.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .title3).pointSize, weight: .bold)
        countCaption.font = .preferredFont(forTextStyle: .caption2).withWeight(.semibold)
        for label in [countValue, countCaption] { label.textColor = .systemRed; label.textAlignment = .center }
        let count = UIStackView(arrangedSubviews: [countValue, countCaption])
        count.axis = .vertical
        count.spacing = 1
        count.isLayoutMarginsRelativeArrangement = true
        count.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 11, bottom: 8, trailing: 11)
        count.backgroundColor = UIColor.systemRed.withAlphaComponent(0.10)
        count.layer.cornerRadius = 13
        count.layer.cornerCurve = .continuous
        count.setContentHuggingPriority(.required, for: .horizontal)
        let top = UIStackView(arrangedSubviews: [titles, UIView(), count])
        top.alignment = .firstBaseline
        top.spacing = 12

        let icon = UIImageView(image: UIImage(systemName: "calendar.badge.clock"))
        icon.tintColor = .systemRed
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let note = UILabel()
        note.text = "Lịch họp được đồng bộ theo thời gian thực"
        note.font = .preferredFont(forTextStyle: .caption1).withWeight(.medium)
        note.textColor = .secondaryLabel
        note.numberOfLines = 0
        let info = UIStackView(arrangedSubviews: [icon, note])
        info.spacing = 8
        info.alignment = .center
        info.isLayoutMarginsRelativeArrangement = true
        info.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        info.backgroundColor = .secondarySystemBackground
        info.layer.cornerRadius = 14
        info.layer.cornerCurve = .continuous

        let stack = UIStackView(arrangedSubviews: [top, info])
        stack.axis = .vertical
        stack.spacing = 12
        return stack
    }

    private func filterBox() -> UIView {
        filter.selectedSegmentIndex = 0
        filter.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            showsUpcoming = filter.selectedSegmentIndex == 0
            render()
        }, for: .valueChanged)
        filter.translatesAutoresizingMaskIntoConstraints = false
        let box = UIView()
        box.backgroundColor = .secondarySystemBackground
        box.layer.cornerRadius = 14
        box.layer.cornerCurve = .continuous
        box.addSubview(filter)
        NSLayoutConstraint.activate([
            filter.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            filter.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -4),
            filter.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            filter.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
        ])
        return box
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: view)
        guard abs(translation.x) > abs(translation.y), abs(translation.x) > 48 else { return }
        showsUpcoming = translation.x > 0
        filter.selectedSegmentIndex = showsUpcoming ? 0 : 1
        UIView.animate(withDuration: 0.25) { self.render() }
    }

    private func render() {
        let meetings = meetings
        countValue.text = "\(meetings.count)"
        countCaption.text = showsUpcoming ? "sắp tới" : "đã qua"
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if meetings.isEmpty {
            list.addArrangedSubview(emptyState())
            return
        }
        for (index, meeting) in meetings.enumerated() {
            let color = showsUpcoming ? Self.cardColors[index % Self.cardColors.count] : .systemGray
            let roomName = session.meetingRooms.first(where: { $0.id == meeting.roomId })?.name ?? "Phòng họp"
            let card = LegacyMeetingSummaryCard(meeting: meeting, roomName: roomName, color: color)
            card.addAction(UIAction { [weak self] _ in self?.open(meeting) }, for: .touchUpInside)
            list.addArrangedSubview(card)
        }
    }

    private func emptyState() -> UIView {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "calendar.badge.exclamationmark")
        configuration.text = showsUpcoming ? "Chưa có lịch sắp tới" : "Chưa có lịch đã qua"
        configuration.secondaryText = showsUpcoming
            ? "Các cuộc họp bạn tạo hoặc được mời sẽ xuất hiện tại đây."
            : "Các cuộc họp đã kết thúc sẽ được lưu tại đây."
        let empty = UIContentUnavailableView(configuration: configuration)
        empty.backgroundColor = .systemBackground
        empty.layer.cornerRadius = 22
        empty.layer.cornerCurve = .continuous
        empty.clipsToBounds = true
        empty.heightAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        return empty
    }

    private func open(_ meeting: MeetingBooking) {
        guard let room = session.meetingRooms.first(where: { $0.id == meeting.roomId }) else {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "building.2.crop.circle")
            configuration.text = "Không tìm thấy thông tin phòng"
            let missing = UIViewController()
            missing.view.backgroundColor = .systemGroupedBackground
            missing.contentUnavailableConfiguration = configuration
            LegacyMeetingUI.presentSheet(missing, from: self)
            return
        }
        LegacyMeetingUI.presentSheet(LegacyMeetingDetailController(session: session, room: room, meeting: meeting), from: self)
    }
}

/// `MeetingSummaryCard`: times, colour bar, title, room and role.
private final class LegacyMeetingSummaryCard: UIControl {
    init(meeting: MeetingBooking, roomName: String, color: UIColor) {
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        layer.cornerRadius = 19
        layer.cornerCurve = .continuous
        layer.borderWidth = 1
        layer.borderColor = color.withAlphaComponent(0.14).cgColor
        layer.shadowColor = color.cgColor
        layer.shadowOpacity = 0.08
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)

        let start = UILabel()
        start.text = MeetingPresentation.time(meeting.startsAt)
        start.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .bold)
        let end = UILabel()
        end.text = MeetingPresentation.time(meeting.endsAt)
        end.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
        end.textColor = .secondaryLabel
        let times = UIStackView(arrangedSubviews: [start, end])
        times.axis = .vertical
        times.spacing = 3
        times.alignment = .center
        times.widthAnchor.constraint(equalToConstant: 54).isActive = true

        let bar = UIView()
        bar.backgroundColor = color
        bar.layer.cornerRadius = 2
        bar.widthAnchor.constraint(equalToConstant: 4).isActive = true

        let title = UILabel()
        title.text = meeting.title.isEmpty ? "Cuộc họp" : meeting.title
        title.font = .preferredFont(forTextStyle: .headline).withWeight(.bold)
        title.numberOfLines = 2
        let roomIcon = UIImageView(image: UIImage(systemName: "building.2.fill", withConfiguration: UIImage.SymbolConfiguration(textStyle: .subheadline)))
        roomIcon.tintColor = .secondaryLabel
        roomIcon.setContentHuggingPriority(.required, for: .horizontal)
        let room = UILabel()
        room.text = roomName
        room.font = .preferredFont(forTextStyle: .subheadline)
        room.textColor = .secondaryLabel
        let roomRow = UIStackView(arrangedSubviews: [roomIcon, room])
        roomRow.spacing = 6
        let role = UILabel()
        role.text = meeting.isOwner == true ? "Bạn tạo lịch" : "Bạn được mời"
        role.font = .preferredFont(forTextStyle: .caption1).withWeight(.bold)
        role.textColor = color
        let roleChip = LegacyCapsuleView(content: role, insets: NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
        roleChip.backgroundColor = color.withAlphaComponent(0.12)
        let roleRow = UIStackView(arrangedSubviews: [roleChip, UIView()])
        let texts = UIStackView(arrangedSubviews: [title, roomRow, roleRow])
        texts.axis = .vertical
        texts.spacing = 5

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right", withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1).applying(UIImage.SymbolConfiguration(weight: .bold))))
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [times, bar, texts, chevron])
        row.spacing = 13
        row.alignment = .center
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            bar.heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "Xem chi tiết cuộc họp \(meeting.title)"
    }
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }
}

/// A capsule around a label (SwiftUI `.padding` + `.clipShape(Capsule())`):
/// round at any Dynamic Type size.
private final class LegacyCapsuleView: UIView {
    init(content: UIView, insets: NSDirectionalEdgeInsets) {
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.leading),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.trailing),
        ])
        layer.cornerCurve = .continuous
        clipsToBounds = true
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    override var forFirstBaselineLayout: UIView { subviews.first?.forFirstBaselineLayout ?? self }
    override var forLastBaselineLayout: UIView { subviews.first?.forLastBaselineLayout ?? self }
}

extension LegacyMyMeetingsController: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

/// A gradient-filled view (hero card, role icon tile).
private final class LegacyGradientView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }
    private let colors: [UIColor]

    init(colors: [UIColor], diagonal: Bool = false) {
        self.colors = colors
        super.init(frame: .zero)
        let gradient = layer as! CAGradientLayer
        gradient.startPoint = diagonal ? CGPoint(x: 0, y: 0) : CGPoint(x: 0.5, y: 0)
        gradient.endPoint = diagonal ? CGPoint(x: 1, y: 1) : CGPoint(x: 0.5, y: 1)
        applyColors()
    }
    required init?(coder: NSCoder) { nil }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColors()
    }

    private func applyColors() {
        (layer as! CAGradientLayer).colors = colors.map { $0.resolvedColor(with: traitCollection).cgColor }
    }
}

/// A sheet's navigation controller that reports its dismissal (iOS 18
/// sheets reload the room list's day in `onDismiss`).
private final class LegacySheetNavigationController: UINavigationController {
    var onDismiss: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil {
            let root = viewControllers.first.map { String(describing: type(of: $0)) } ?? "unknown"
            UIFlowLog.record("sheet.disappear", "legacy root=\(root) animated=\(animated)")
            onDismiss?()
            onDismiss = nil
        }
    }
}
