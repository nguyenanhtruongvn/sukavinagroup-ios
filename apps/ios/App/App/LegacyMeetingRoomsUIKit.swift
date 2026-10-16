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
        navigationController?.pushViewController(
            LegacyMeetingBookingController(session: session, room: room, day: day), animated: true
        )
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

@MainActor
private final class LegacyMeetingScheduleController: UITableViewController {
    private let session: SessionStore
    private let room: MeetingRoom?
    private let day: Date
    private var cancellable: AnyCancellable?
    /// This room's (or my) meetings of the day, recomputed per data change;
    /// every row callback used to filter and sort the whole schedule again.
    private var bookings: [MeetingBooking] = []

    private func reload() {
        bookings = session.meetingBookings.filter { meeting in
            LegacyMeetingUI.sameDay(meeting, day)
                && (room == nil ? (meeting.isMine ?? false) : meeting.roomId == room?.id)
        }.sorted { $0.startsAt < $1.startsAt }
        tableView.reloadData()
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
        cancellable = session.meetings.$bookings.receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
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
        let cell = tableView.dequeueReusableCell(withIdentifier: "meeting")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "meeting")
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
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.keyboardDismissMode = .interactive
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
            // Follows the keyboard: pinned to the safe area this form left
            // "Xác nhận đặt phòng" under the keyboard after typing the topic.
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
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
        topic.returnKeyType = .done
        topic.addTarget(topic, action: #selector(UIResponder.resignFirstResponder), for: .editingDidEndOnExit)
        fields.addArrangedSubview(topic)
        fields.addArrangedSubview(label("Bắt đầu"))
        start.datePickerMode = .dateAndTime
        start.preferredDatePickerStyle = .compact
        start.locale = Locale(identifier: "vi_VN")
        start.timeZone = MeetingPresentation.timezone
        start.minuteInterval = MeetingBookingTime.minuteStep
        let calendar = MeetingPresentation.calendar
        let dateStart = calendar.startOfDay(for: day)
        let firstStart = MeetingBookingTime.defaultStart(on: day, now: Date(), calendar: calendar)
        start.minimumDate = calendar.isDate(day, inSameDayAs: Date()) ? firstStart : dateStart
        // Prevent an invalid minimum > maximum date range if the user opens
        // this form at the very end of the selected day.
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: dateStart)?.addingTimeInterval(-60)
            ?? dateStart
        start.maximumDate = max(start.minimumDate ?? dateStart, endOfDay)
        start.date = max(start.minimumDate ?? dateStart, firstStart)
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
        // Leaving with a typed topic or invitees asks first; the swipe-back
        // gesture is turned off on this screen for the same reason.
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Hủy", style: .plain, target: self, action: #selector(close))
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
    }

    @objc private func close() {
        let typed = !(topic.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard typed || !invited.isEmpty else {
            navigationController?.popViewController(animated: true)
            return
        }
        let alert = UIAlertController(title: "Bỏ lịch đang đặt?", message: "Nội dung và người được mời bạn đã chọn sẽ không được lưu.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Tiếp tục đặt", style: .cancel))
        alert.addAction(UIAlertAction(title: "Bỏ lịch", style: .destructive) { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
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
        if let reason = MeetingBookingTime.blockReason(
            start: start.date, now: Date(), attendeeCount: invited.count + 1,
            capacity: room.capacity, calendar: MeetingPresentation.calendar
        ) {
            LegacyMeetingUI.message("Chưa thể đặt phòng", reason, from: self)
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
        cancellable = session.meetings.$invitees.receive(on: RunLoop.main)
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
