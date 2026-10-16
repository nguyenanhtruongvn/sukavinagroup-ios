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
    static func presentBooking(session: SessionStore, room: MeetingRoom, day: Date, from controller: UIViewController) {
        let navigation = UINavigationController(rootViewController: LegacyMeetingBookingController(session: session, room: room, day: day))
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
    private var dayOffset = 0
    private var day: Date {
        MeetingPresentation.calendar.date(byAdding: .day, value: dayOffset, to: Date()) ?? Date()
    }
    private let tableView = UITableView(frame: .zero, style: .plain)
    private let todayButton = LegacyPillButton(title: "Hôm nay")
    private let tomorrowButton = LegacyPillButton(title: "Ngày mai")
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
        header.spacing = 12
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
        tableView.contentInset = UIEdgeInsets(top: 6, left: 0, bottom: 24, right: 0)
        view.addSubview(tableView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 20),
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            tableView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            tableView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Swipe left/right switches Hôm nay ⇄ Ngày mai, like iOS 18+.
        for direction in [UISwipeGestureRecognizer.Direction.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipedDay(_:)))
            swipe.direction = direction
            tableView.addGestureRecognizer(swipe)
        }

        session.meetings.$rooms
            .combineLatest(session.meetings.$bookingsByRoom, session.meetings.$scheduleLoaded, session.meetings.$scheduleError)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _, _ in self?.reload() }
            .store(in: &cancellables)
        updateDayButtons()
        NotificationCenter.default.addObserver(self, selector: #selector(clockChanged),
                                               name: UIApplication.significantTimeChangeNotification, object: nil)
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

    @objc private func clockChanged() { reload() }

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
        todayButton.isOn = dayOffset == 0
        tomorrowButton.isOn = dayOffset == 1
    }

    private func setDay(_ offset: Int) {
        guard offset != dayOffset else { return }
        dayOffset = offset
        updateDayButtons()
        fetch()
    }

    @objc private func showToday() { setDay(0) }
    @objc private func showTomorrow() { setDay(1) }
    @objc private func swipedDay(_ gesture: UISwipeGestureRecognizer) {
        setDay(gesture.direction == .left ? 1 : 0)
    }

    @objc private func openMyMeetings() {
        navigationController?.pushViewController(
            LegacyMeetingScheduleController(session: session, room: nil, day: day), animated: true
        )
    }

    private func openSchedule(_ room: MeetingRoom) {
        navigationController?.pushViewController(
            LegacyMeetingScheduleController(session: session, room: room, day: day), animated: true
        )
    }

    private func openBooking(_ room: MeetingRoom) {
        LegacyMeetingUI.presentBooking(session: session, room: room, day: day, from: self)
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
            onBook: { [weak self] in self?.openBooking(room) }
        )
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt path: IndexPath) {
        tableView.deselectRow(at: path, animated: false)
        guard rooms.indices.contains(path.row) else { return }
        openSchedule(rooms[path.row])
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
        self.session.reorderMeetingRooms(reordered)
    }
}

/// "Hôm nay" / "Ngày mai" pills and the calendar button of the iOS 18+ header.
private final class LegacyPillButton: UIButton {
    var isOn = false { didSet { applyStyle() } }

    init(title: String? = nil, symbol: String? = nil) {
        super.init(frame: .zero)
        var configuration = UIButton.Configuration.plain()
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        if let title {
            configuration.attributedTitle = AttributedString(title, attributes: AttributeContainer([
                .font: UIFont.preferredFont(forTextStyle: .subheadline).withWeight(.bold),
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

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        applyColors()
    }

    func configure(room: MeetingRoom, bookings: [MeetingBooking], day: Date, now: Date,
                   onSchedule: @escaping () -> Void, onBook: @escaping () -> Void) {
        self.onSchedule = onSchedule
        self.onBook = onBook
        let status = LegacyMeetingUI.roomStatus(bookings: bookings, day: day, now: now)
        available = status.available

        nameLabel.text = room.name
        detailLabel.text = "\(room.capacity) chỗ · \(room.equipment.isEmpty ? "Thiết bị đang cập nhật" : room.equipment.joined(separator: " · "))"
        statusLabel.text = status.text
        chipLabel.text = available ? "Trống" : "Đang họp"
        accessibilityLabel = "\(room.name), \(available ? "Trống" : "Đang họp"), \(status.text)"

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
    private let room: MeetingRoom?
    private var day: Date
    private var cancellable: AnyCancellable?
    private let scrollView = UIScrollView()
    private let timeline = LegacyMeetingTimelineView()
    private let datePicker = UIDatePicker()
    private var didScrollToNow = false

    init(session: SessionStore, room: MeetingRoom?, day: Date) {
        self.session = session; self.room = room; self.day = day
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        title = room?.name ?? "Lịch của tôi"
        navigationItem.largeTitleDisplayMode = .always

        // "Ngày" and a compact day picker; past days cannot be booked.
        let dayLabel = UILabel()
        dayLabel.text = "Ngày"
        dayLabel.font = .preferredFont(forTextStyle: .body)
        datePicker.datePickerMode = .date
        datePicker.preferredDatePickerStyle = .compact
        datePicker.locale = Locale(identifier: "vi_VN")
        datePicker.timeZone = VietnamTime.timeZone
        datePicker.calendar = VietnamTime.calendar
        datePicker.minimumDate = VietnamTime.calendar.startOfDay(for: Date())
        datePicker.date = day
        datePicker.addTarget(self, action: #selector(dayChanged), for: .valueChanged)
        let header = UIStackView(arrangedSubviews: [dayLabel, UIView(), datePicker])
        header.alignment = .center
        header.translatesAutoresizingMaskIntoConstraints = false

        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        timeline.translatesAutoresizingMaskIntoConstraints = false
        timeline.onSelect = { [weak self] booking in self?.openDetail(booking) }
        scrollView.addSubview(timeline)
        view.addSubview(header)
        view.addSubview(scrollView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            header.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            timeline.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            timeline.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            timeline.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor),
            timeline.heightAnchor.constraint(equalToConstant: LegacyMeetingTimelineView.timelineHeight),
        ])

        if room != nil {
            // The green "+" of the iOS 18 schedule.
            let book = UIButton(type: .system)
            var configuration = UIButton.Configuration.filled()
            configuration.image = UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold))
            configuration.baseBackgroundColor = .systemGreen
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .capsule
            book.configuration = configuration
            book.accessibilityLabel = "Đặt phòng \(room?.name ?? "")"
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
            scrollView.contentInset.bottom = 58 + 22
        }

        // `bookings` is published after `bookingsByRoom`: both are current here.
        cancellable = session.meetings.$bookings.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
        reload()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        Task { await session.refreshMeetingSchedule(date: day) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // Today opens on the current hour, like iOS 18.
        guard !didScrollToNow, scrollView.bounds.height > 0 else { return }
        didScrollToNow = true
        guard let offset = MeetingScheduleLayout.currentOffset(
            day: day, now: Date(),
            firstHour: LegacyMeetingTimelineView.firstHour,
            lastHour: LegacyMeetingTimelineView.lastHour,
            hourHeight: LegacyMeetingTimelineView.hourHeight
        ) else { return }
        let maxOffset = max(0, LegacyMeetingTimelineView.timelineHeight + scrollView.adjustedContentInset.bottom - scrollView.bounds.height)
        scrollView.contentOffset.y = min(max(0, offset - scrollView.bounds.height / 2), maxOffset)
    }

    private func reload() {
        let bookings: [MeetingBooking]
        if let room {
            bookings = (session.meetings.bookingsByRoom[room.id] ?? []).filter { LegacyMeetingUI.sameDay($0, day) }
        } else {
            bookings = session.meetingBookings.filter { ($0.isMine ?? false) && LegacyMeetingUI.sameDay($0, day) }
        }
        timeline.update(bookings: bookings, day: day)
    }

    @objc private func dayChanged() {
        day = datePicker.date
        reload()
        Task { await session.refreshMeetingSchedule(date: day) }
    }

    @objc private func bookRoom() {
        guard let room else { return }
        LegacyMeetingUI.presentBooking(session: session, room: room, day: day, from: self)
    }

    private func openDetail(_ meeting: MeetingBooking) {
        // Other people's private bookings carry no id and no details.
        guard !meeting.id.isEmpty,
              let selectedRoom = room ?? session.meetingRooms.first(where: { $0.id == meeting.roomId }) else { return }
        navigationController?.pushViewController(
            LegacyMeetingDetailController(session: session, room: selectedRoom, meeting: meeting), animated: true
        )
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
            label.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
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
/// card that names what blocks the booking, a transient error notice and a
/// discard confirmation. Presented as a sheet, like on iOS 18.
@MainActor
private final class LegacyMeetingBookingController: UIViewController, UITextFieldDelegate,
    UIPickerViewDataSource, UIPickerViewDelegate, UIAdaptivePresentationControllerDelegate {
    private let session: SessionStore
    private let room: MeetingRoom
    private let day: Date

    // Form state (mirrors MeetingBookingSheet).
    private var meetingType = "Nội bộ"
    private var start = Date()
    private var durationValue = 30
    private var durationUnit = "phút"
    private var selected = Set<String>()
    private var selectedDepartments = Set<String>()
    private var inviteesError: String?
    private var showStartPicker = false
    private var showDurationPicker = false
    private var isSubmitting = false
    private var invitees: [MeetingInvitee] = []
    private var cancellable: AnyCancellable?

    private let red = UIColor.systemRed
    private let green = UIColor(red: 0, green: 0.42, blue: 0.25, alpha: 1)
    private let minuteValues = Array(stride(from: 0, to: 60, by: MeetingBookingTime.minuteStep))
    private var durationValues: [Int] { durationUnit == "giờ" ? Array(1...8) : [5, 10, 15, 20, 30, 45, 60, 90, 120] }

    // Views that persist (text fields keep focus); the rest is re-rendered.
    private let scroll = UIScrollView()
    private let content = UIStackView()
    private let titleField = UITextField()
    private let peopleField = UITextField()
    private let departmentField = UITextField()
    private let typeButtons = UIStackView()
    private let startTile = UIControl()
    private let durationTile = UIControl()
    private let startPicker = UIPickerView()
    private let durationPicker = UIPickerView()
    private let startPickerBox = UIView()
    private let durationPickerBox = UIView()
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
    private let confirmButton = UIButton(type: .system)
    private var notice: UIView?
    private var noticeHide: DispatchWorkItem?

    init(session: SessionStore, room: MeetingRoom, day: Date) {
        self.session = session; self.room = room; self.day = day
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { nil }

    // MARK: Derived values

    private var durationMinutes: Int { durationUnit == "giờ" ? durationValue * 60 : durationValue }
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
        navigationItem.rightBarButtonItem = UIBarButtonItem(title: "Đóng", style: .plain, target: self, action: #selector(close))
        navigationController?.presentationController?.delegate = self
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
        cancellable = session.meetings.$invitees.receive(on: RunLoop.main).sink { [weak self] value in
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

        typeButtons.axis = .horizontal
        typeButtons.spacing = 10
        typeButtons.distribution = .fillEqually
        for (value, icon) in [("Nội bộ", "person.2.fill"), ("Tiếp khách", "person.badge.plus")] {
            let button = UIButton(type: .system)
            button.addAction(UIAction { [weak self] _ in self?.meetingType = value; self?.render() }, for: .touchUpInside)
            button.accessibilityIdentifier = value
            button.heightAnchor.constraint(equalToConstant: 44).isActive = true
            button.configuration = typeConfiguration(value: value, icon: icon, selected: false)
            typeButtons.addArrangedSubview(button)
        }
        card.addArrangedSubview(typeButtons)

        let contentLabel = label("Nội dung cuộc họp", style: .caption1, weight: .semibold, color: .secondaryLabel)
        styleField(titleField, placeholder: "Ví dụ: Họp kế hoạch tuần", icon: nil, height: 48)
        titleField.returnKeyType = .done
        titleField.delegate = self
        titleField.addAction(UIAction { [weak self] _ in self?.renderConfirm() }, for: .editingChanged)
        let titleGroup = UIStackView(arrangedSubviews: [contentLabel, fieldContainer(titleField, icon: nil, height: 48)])
        titleGroup.axis = .vertical
        titleGroup.spacing = 7
        card.addArrangedSubview(titleGroup)

        let tiles = UIStackView(arrangedSubviews: [startTile, durationTile])
        tiles.spacing = 10
        tiles.distribution = .fillEqually
        startTile.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            showStartPicker.toggle()
            render(animated: true)
        }, for: .touchUpInside)
        durationTile.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            showDurationPicker.toggle()
            render(animated: true)
        }, for: .touchUpInside)
        card.addArrangedSubview(tiles)

        configurePicker(startPicker, box: startPickerBox, titles: ["Giờ", "Phút"])
        configurePicker(durationPicker, box: durationPickerBox, titles: ["Số", "Đơn vị"])
        card.addArrangedSubview(startPickerBox)
        card.addArrangedSubview(durationPickerBox)

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
        countBadge.backgroundColor = red.withAlphaComponent(0.10)
        countBadge.layer.cornerRadius = 11
        countBadge.layer.masksToBounds = true
        countBadge.textAlignment = .center
        countBadge.setContentHuggingPriority(.required, for: .horizontal)
        countBadge.heightAnchor.constraint(equalToConstant: 22).isActive = true
        let titleRow = UIStackView(arrangedSubviews: [sectionTitle("Mời người tham gia", icon: "person.2.fill"), UIView(), countBadge])
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
            field.returnKeyType = .search
            field.delegate = self
            field.addAction(UIAction { [weak self] _ in self?.renderInvitees(keeping: field) }, for: .editingChanged)
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
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
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
        confirmButton.heightAnchor.constraint(equalToConstant: 52).isActive = true
        confirmButton.addTarget(self, action: #selector(submit), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [blockLabel, confirmButton])
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

    private func render(animated: Bool = false) {
        for case let button as UIButton in typeButtons.arrangedSubviews {
            let value = button.accessibilityIdentifier ?? ""
            let icon = value == "Nội bộ" ? "person.2.fill" : "person.badge.plus"
            button.configuration = typeConfiguration(value: value, icon: icon, selected: value == meetingType)
        }
        fillTile(startTile, title: "Bắt đầu", value: MeetingPresentation.clock.string(from: start), icon: "clock.fill", active: showStartPicker)
        fillTile(durationTile, title: "Thời lượng", value: "\(durationValue) \(durationUnit)", icon: "timer", active: showDurationPicker)
        expectedLabel.text = "\(MeetingPresentation.clock.string(from: start)) – \(MeetingPresentation.clock.string(from: endTime))"
        let changes = {
            self.startPickerBox.isHidden = !self.showStartPicker
            self.durationPickerBox.isHidden = !self.showDurationPicker
            self.startPickerBox.alpha = self.showStartPicker ? 1 : 0
            self.durationPickerBox.alpha = self.showDurationPicker ? 1 : 0
        }
        if animated {
            UIView.animate(withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [], animations: {
                changes()
                self.content.layoutIfNeeded()
            })
        } else {
            changes()
        }
        syncPickers()
        renderInvitees()
    }

    private func renderConfirm() {
        let reason = isSubmitting ? nil : blockReason
        blockLabel.isHidden = reason == nil
        if let reason {
            let text = NSMutableAttributedString(attributedString: NSAttributedString(attachment: NSTextAttachment(image: UIImage(systemName: "info.circle") ?? UIImage())))
            text.append(NSAttributedString(string: " " + reason))
            blockLabel.attributedText = text
        }
        let enabled = reason == nil && !isSubmitting
        var configuration = confirmButton.configuration ?? .filled()
        configuration.baseBackgroundColor = enabled || isSubmitting ? red : .systemGray3
        configuration.baseForegroundColor = .white
        configuration.image = isSubmitting ? nil : UIImage(systemName: "checkmark.circle.fill")
        configuration.showsActivityIndicator = isSubmitting
        var title = AttributedString(isSubmitting ? "Đang đặt phòng..." : "Xác nhận đặt phòng")
        title.font = .preferredFont(forTextStyle: .headline).withWeight(.bold)
        configuration.attributedTitle = title
        confirmButton.configuration = configuration
        confirmButton.isEnabled = enabled
        // Swiping the sheet down asks first once something was entered.
        navigationController?.isModalInPresentation = hasUnsavedInput || isSubmitting
    }

    /// The invitation card's dynamic parts. [keeping] stays visible above the
    /// keyboard while the results above it grow or shrink.
    private func renderInvitees(keeping field: UITextField? = nil) {
        countBadge.text = "  \(selected.count) người  "

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
                renderInvitees()
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
                        renderInvitees(keeping: departmentField)
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
                    inviteesError = await session.refreshMeetingInvitees(force: true)
                    renderInvitees()
                }
            }, for: .touchUpInside)
            errorSection.addArrangedSubview(retry)
        }

        hintLabel.isHidden = !(query.isEmpty && selectedDepartments.isEmpty)
        capacityLabel.text = "\(selected.count + 1)/\(room.capacity) chỗ · gồm bạn và người được mời"
        renderConfirm()

        if let field = field ?? [peopleField, departmentField].first(where: \.isFirstResponder) {
            view.layoutIfNeeded()
            let rect = field.convert(field.bounds, to: scroll).insetBy(dx: 0, dy: -8)
            scroll.scrollRectToVisible(rect, animated: false)
        }
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
            if selected.contains(person.id) { selected.remove(person.id) } else { selected.insert(person.id) }
            renderInvitees(keeping: peopleField)
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

    private func typeConfiguration(value: String, icon: String, selected: Bool) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 13
        configuration.baseBackgroundColor = selected ? green : .secondarySystemBackground
        configuration.baseForegroundColor = selected ? .white : .label
        configuration.background.strokeColor = selected ? .clear : .separator
        configuration.background.strokeWidth = 1
        configuration.image = UIImage(systemName: icon)
        configuration.imagePadding = 6
        var title = AttributedString(value)
        title.font = .preferredFont(forTextStyle: .subheadline).withWeight(.bold)
        configuration.attributedTitle = title
        return configuration
    }

    private func fillTile(_ tile: UIControl, title: String, value: String, icon: String, active: Bool) {
        tile.subviews.forEach { $0.removeFromSuperview() }
        tile.backgroundColor = active ? red.withAlphaComponent(0.10) : .secondarySystemBackground
        tile.layer.cornerRadius = 14
        tile.layer.cornerCurve = .continuous
        tile.layer.borderWidth = 1
        tile.layer.borderColor = (active ? red.withAlphaComponent(0.35) : .clear).cgColor
        let iconView = UIImageView(image: UIImage(systemName: icon))
        iconView.tintColor = red
        let chevron = UIImageView(image: UIImage(systemName: active ? "chevron.up" : "chevron.down",
                                                 withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1, scale: .medium)))
        chevron.tintColor = .secondaryLabel
        let top = UIStackView(arrangedSubviews: [iconView, UIView(), chevron])
        top.alignment = .center
        let titleLabel = label(title, style: .caption1, color: .secondaryLabel)
        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .headline).pointSize, weight: .bold)
        valueLabel.textColor = .label
        let stack = UIStackView(arrangedSubviews: [top, titleLabel, valueLabel])
        stack.axis = .vertical
        stack.spacing = 7
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: tile.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -12),
        ])
        tile.isAccessibilityElement = true
        tile.accessibilityTraits = .button
        tile.accessibilityLabel = "\(title): \(value)"
    }

    private func configurePicker(_ picker: UIPickerView, box: UIView, titles: [String]) {
        picker.dataSource = self
        picker.delegate = self
        let headers = UIStackView(arrangedSubviews: titles.map { label($0, style: .caption1, weight: .semibold, color: .secondaryLabel) })
        headers.distribution = .fillEqually
        headers.arrangedSubviews.forEach { ($0 as? UILabel)?.textAlignment = .center }
        let stack = UIStackView(arrangedSubviews: [headers, picker])
        stack.axis = .vertical
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 0, trailing: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        box.backgroundColor = .secondarySystemBackground
        box.layer.cornerRadius = 15
        box.layer.cornerCurve = .continuous
        box.clipsToBounds = true
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            box.heightAnchor.constraint(equalToConstant: 138),
        ])
        box.isHidden = true
    }

    private func syncPickers() {
        let calendar = MeetingPresentation.calendar
        let hour = calendar.component(.hour, from: start)
        let minute = calendar.component(.minute, from: start)
        if startPicker.selectedRow(inComponent: 0) != hour { startPicker.selectRow(hour, inComponent: 0, animated: false) }
        if let index = minuteValues.firstIndex(of: minute), startPicker.selectedRow(inComponent: 1) != index {
            startPicker.selectRow(index, inComponent: 1, animated: false)
        }
        if let index = durationValues.firstIndex(of: durationValue), durationPicker.selectedRow(inComponent: 0) != index {
            durationPicker.selectRow(index, inComponent: 0, animated: false)
        }
        let unitIndex = durationUnit == "giờ" ? 1 : 0
        if durationPicker.selectedRow(inComponent: 1) != unitIndex { durationPicker.selectRow(unitIndex, inComponent: 1, animated: false) }
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
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = icon == nil ? .default : .no
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

    // MARK: Pickers

    func numberOfComponents(in pickerView: UIPickerView) -> Int { 2 }

    func pickerView(_ pickerView: UIPickerView, numberOfRowsInComponent component: Int) -> Int {
        if pickerView === startPicker { return component == 0 ? 24 : minuteValues.count }
        return component == 0 ? durationValues.count : 2
    }

    func pickerView(_ pickerView: UIPickerView, titleForRow row: Int, forComponent component: Int) -> String? {
        if pickerView === startPicker {
            return String(format: "%02d", component == 0 ? row : minuteValues[row])
        }
        if component == 0 { return String(format: "%02d", durationValues[row]) }
        return row == 0 ? "phút" : "giờ"
    }

    func pickerView(_ pickerView: UIPickerView, didSelectRow row: Int, inComponent component: Int) {
        let calendar = MeetingPresentation.calendar
        if pickerView === startPicker {
            let hour = component == 0 ? row : calendar.component(.hour, from: start)
            let minute = component == 1 ? minuteValues[row] : calendar.component(.minute, from: start)
            start = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: start) ?? start
        } else if component == 0 {
            durationValue = durationValues[row]
        } else {
            let unit = row == 1 ? "giờ" : "phút"
            if unit != durationUnit {
                durationUnit = unit
                durationValue = unit == "giờ" ? 1 : 30
                durationPicker.reloadComponent(0)
            }
        }
        render()
    }

    // MARK: Text fields

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        guard textField !== titleField else { return }
        DispatchQueue.main.async { [weak self] in self?.renderInvitees(keeping: textField) }
    }

    // MARK: Actions

    func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
        close()
    }

    @objc private func close() {
        guard hasUnsavedInput, !isSubmitting else {
            if !isSubmitting { dismiss(animated: true) }
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
                showNotice(failure)
            } else {
                dismiss(animated: true)
            }
        }
    }

    /// The dark notice at the top that disappears after five seconds.
    private func showNotice(_ message: String) {
        noticeHide?.cancel()
        notice?.removeFromSuperview()
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
        icon.tintColor = .white
        icon.setContentHuggingPriority(.required, for: .horizontal)
        let text = label(message, style: .subheadline, weight: .semibold, color: .white)
        let row = UIStackView(arrangedSubviews: [icon, text])
        row.spacing = 8
        row.alignment = .center
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        row.backgroundColor = UIColor.black.withAlphaComponent(0.90)
        row.layer.cornerRadius = 16
        row.layer.cornerCurve = .continuous
        row.layer.shadowColor = UIColor.black.cgColor
        row.layer.shadowOpacity = 0.24
        row.layer.shadowRadius = 10
        row.layer.shadowOffset = CGSize(width: 0, height: 4)
        row.isUserInteractionEnabled = false
        row.accessibilityLabel = "Không thể đặt phòng: \(message)"
        row.isAccessibilityElement = true
        row.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 10),
            row.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            row.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            row.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
        ])
        notice = row
        UIAccessibility.post(notification: .announcement, argument: row.accessibilityLabel)
        let hide = DispatchWorkItem { [weak self, weak row] in
            UIView.animate(withDuration: 0.2, animations: { row?.alpha = 0 }) { _ in
                row?.removeFromSuperview()
                if self?.notice === row { self?.notice = nil }
            }
        }
        noticeHide = hide
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: hide)
    }
}

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
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
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
            if let start = meeting.startDate, start > Date() {
                fields.addArrangedSubview(button("Hủy lịch họp", #selector(cancel)))
            } else if let meetingEndDate = meeting.endDate, meetingEndDate > Date() {
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
