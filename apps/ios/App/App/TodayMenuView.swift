import UIKit
import SwiftUI
import Combine
import Security
import UserNotifications
import Network
import LocalAuthentication
import WidgetKit
import AVFoundation
import CoreImage.CIFilterBuiltins
import WebKit
import UniformTypeIdentifiers

struct TodayMenuView: View {
    // Observes only `isWorking` (below), not every session change.
    @Environment(\.sessionActions) private var sessionActions
    private var session: SessionStore { sessionActions.store }
    @State private var isSessionWorking = false
    @EnvironmentObject private var menuStore: MenuStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var pendingChoice: String?
    @State private var includeSelfForPendingChoice = true
    @State private var selectedManagedEmployeeIds: Set<String> = []
    // Measured from the actual sheet content; no fixed minimum height.
    @State private var mealSheetHeight: CGFloat = 1

    private var delegatedOrders: [ManagedMealEmployee] {
        (menuStore.todayMenu?.managedEmployees ?? []).filter {
            $0.selection != nil && $0.orderedByEmployeeId != nil
        }
    }

    private var hasPendingDelegatedOrders: Bool {
        delegatedOrders.contains { $0.receivedAt == nil }
    }

    private var hasAvailableManagedEmployees: Bool {
        (menuStore.todayMenu?.managedEmployees ?? []).contains { $0.selection == nil }
    }

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        PortalPageTitle("Thực đơn")
                    }

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 11) {
                        menuGroup("Món nước", icon: "takeoutbag.and.cup.and.straw.fill", color: .cyan, lines: [menuStore.todayMenu?.day.featured])
                        menuGroup("Món thường", icon: "fork.knife", color: .orange, lines: [
                            menuStore.todayMenu?.day.savoryMain,
                            menuStore.todayMenu?.day.savorySide,
                            menuStore.todayMenu?.day.vegetable,
                            menuStore.todayMenu?.day.soup
                        ])
                        menuGroup("Món chay", icon: "leaf.fill", color: .green, lines: [
                            menuStore.todayMenu?.day.vegetarianMain,
                            menuStore.todayMenu?.day.vegetarianSide
                        ])
                        menuGroup("Tăng ca", icon: "moon.stars.fill", color: .purple, lines: [menuStore.todayMenu?.day.overtime])
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        if let selection = menuStore.todayMenu?.selection {
                            let isWater = selection == "water"
                            // Keep every person receiving this same dish in
                            // the dish card. Previously they were displayed
                            // much farther down as a separate list, leaving
                            // the card misleadingly showing only “Tôi”.
                            let peopleWithThisMeal = delegatedOrders.filter { $0.selection == selection }
                            Text("MÓN ĂN ĐÃ ĐẶT").font(.caption.bold()).tracking(1.2).foregroundColor(AppTheme.muted)
                            HStack(spacing: 14) {
                                Image(systemName: isWater ? "takeoutbag.and.cup.and.straw.fill" : "leaf.fill")
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundColor(isWater ? .cyan : .green)
                                    .frame(width: 50, height: 50)
                                    .background((isWater ? Color.cyan : Color.green).opacity(0.14))
                                    .clipShape(RoundedRectangle(cornerRadius: 15))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(isWater ? "Món nước" : "Món chay").font(.title3.bold())
                                    Text(selectedMealDetail(selection))
                                        .font(.subheadline).foregroundColor(AppTheme.muted).lineLimit(2)
                                }
                            }
                            GroupedMealReceiptRows(
                                pendingNames: (menuStore.todayMenu?.receivedAt == nil ? ["Tôi"] : [])
                                    + peopleWithThisMeal.filter { $0.receivedAt == nil }.map { $0.fullName.isEmpty ? $0.employeeCode : $0.fullName },
                                receivedNames: (menuStore.todayMenu?.receivedAt != nil ? ["Tôi"] : [])
                                    + peopleWithThisMeal.filter { $0.receivedAt != nil }.map { $0.fullName.isEmpty ? $0.employeeCode : $0.fullName }
                            )
                            let otherDelegatedOrders = delegatedOrders.filter { $0.selection != selection }
                            if !otherDelegatedOrders.isEmpty {
                                let otherByChoice = Dictionary(grouping: otherDelegatedOrders, by: { $0.selection ?? "water" })
                                ForEach(["water", "vegetarian"].filter { otherByChoice[$0] != nil }, id: \.self) { choice in
                                    let employees = otherByChoice[choice] ?? []
                                    Divider()
                                    delegatedMealHeader(choice)
                                    GroupedMealReceiptRows(
                                        pendingNames: employees.filter { $0.receivedAt == nil }.map { $0.fullName.isEmpty ? $0.employeeCode : $0.fullName },
                                        receivedNames: employees.filter { $0.receivedAt != nil }.map { $0.fullName.isEmpty ? $0.employeeCode : $0.fullName }
                                    )
                                }
                            }
                        } else {
                            Text("LỰA CHỌN HÔM NAY").font(.caption.bold()).tracking(1.2).foregroundColor(AppTheme.muted)
                            if menuStore.todayMenu?.orderingOpen == false {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock.badge.exclamationmark.fill")
                                        .font(.title3.bold())
                                        .foregroundColor(.orange)
                                        .frame(width: 42, height: 42)
                                        .background(Color.orange.opacity(0.13))
                                        .clipShape(RoundedRectangle(cornerRadius: 13))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Đã khóa đặt món").font(.headline).foregroundColor(AppTheme.text(.orange, chipAlpha: 0.13))
                                        Text("Vui lòng đặt món trước \(menuStore.todayMenu?.orderingCutoff ?? "09:00").")
                                            .font(.caption).foregroundColor(AppTheme.muted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(Color.orange.opacity(0.08))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            } else {
                                mealButton("Món nước", detail: menuStore.todayMenu?.day.featured, icon: "takeoutbag.and.cup.and.straw.fill", color: .cyan, choice: "water")
                                mealButton("Món chay", detail: [menuStore.todayMenu?.day.vegetarianMain, menuStore.todayMenu?.day.vegetarianSide].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "), icon: "leaf.fill", color: .green, choice: "vegetarian")
                            }
                        }
                        if menuStore.todayMenu?.selection != nil,
                           hasAvailableManagedEmployees,
                           menuStore.todayMenu?.orderingOpen == true {
                            Divider()
                            Text("ĐẶT THÊM CHO NHÂN VIÊN")
                                .font(.caption.bold()).tracking(1.2).foregroundColor(AppTheme.muted)
                            // Mirror Android: a manager must cancel their own meal
                            // before choosing that same dish again. Only offer the
                            // alternative dish for additional delegated orders.
                            if menuStore.todayMenu?.selection != "water" {
                                mealButton("Món nước", detail: menuStore.todayMenu?.day.featured,
                                    icon: "takeoutbag.and.cup.and.straw.fill", color: .cyan,
                                    choice: "water", forManagedOnly: true)
                            }
                            if menuStore.todayMenu?.selection != "vegetarian" {
                                mealButton("Món chay", detail: [menuStore.todayMenu?.day.vegetarianMain,
                                    menuStore.todayMenu?.day.vegetarianSide].compactMap { $0 }
                                    .filter { !$0.isEmpty }.joined(separator: " · "),
                                    icon: "leaf.fill", color: .green,
                                    choice: "vegetarian", forManagedOnly: true)
                            }
                        }
                        if menuStore.todayMenu?.selection == nil, !delegatedOrders.isEmpty {
                            let delegatedByChoice = Dictionary(grouping: delegatedOrders, by: { $0.selection ?? "water" })
                            ForEach(["water", "vegetarian"].filter { delegatedByChoice[$0] != nil }, id: \.self) { choice in
                                let employees = delegatedByChoice[choice] ?? []
                                Divider()
                                delegatedMealHeader(choice)
                                GroupedMealReceiptRows(
                                    pendingNames: employees.filter { $0.receivedAt == nil }.map { $0.fullName.isEmpty ? $0.employeeCode : $0.fullName },
                                    receivedNames: employees.filter { $0.receivedAt != nil }.map { $0.fullName.isEmpty ? $0.employeeCode : $0.fullName }
                                )
                            }
                        }
                        // Keep QR and cancellation controls at the bottom,
                        // after every meal/person row and add-more choice.
                        if menuStore.todayMenu?.selection != nil {
                            if menuStore.todayMenu?.receivedAt == nil || hasPendingDelegatedOrders {
                                MealQRCodeAccessCard(useManagedGroupQr: hasPendingDelegatedOrders)
                                    .id(hasPendingDelegatedOrders)
                            }
                            if menuStore.todayMenu?.receivedAt == nil {
                                Button {
                                    pendingChoice = "cancel"
                                } label: {
                                    Label("Hủy lựa chọn hôm nay", systemImage: "xmark.circle.fill")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.red.opacity(0.86))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                }
                                .buttonStyle(.plain)
                                .disabled(menuStore.todayMenu?.orderingOpen == false)
                            }
                        } else if hasPendingDelegatedOrders {
                            MealQRCodeAccessCard(useManagedGroupQr: true)
                        }
                    }
                    .padding(18)
                    .background(AppTheme.card.opacity(0.86))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                }
                .frame(maxWidth: horizontalSizeClass == .regular ? 760 : .infinity)
                .frame(maxWidth: .infinity)
                .padding(20)
                .padding(.bottom, 94)
            }
            .hidesPortalBottomScrollEdgeEffect()
            .background(AppTheme.ink.ignoresSafeArea())
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
            .task {
                await session.refreshTodayMenu(force: true)
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    guard !Task.isCancelled else { return }
                    if scenePhase == .active {
                        await session.refreshTodayMenu(force: true)
                    }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await session.refreshTodayMenu(force: true) }
                }
            }
            .onReceive(session.$isWorking) { isSessionWorking = $0 }
            .mealConfirmationSheet(isPresented: Binding(
                get: { pendingChoice != nil },
                set: { if !$0 { pendingChoice = nil } }
            )) {
                mealConfirmationContent
            }
        }
    }

    // Isolated from the portal body to keep iOS Release type-checking manageable.
    @ViewBuilder private var mealConfirmationContent: some View {
        let choice = pendingChoice ?? "water"
        let cancelling = choice == "cancel"
        let title = choice == "water" ? "Món nước" : "Món chay"
        let detail = choice == "water"
            ? (menuStore.todayMenu?.day.featured ?? "...")
            : [menuStore.todayMenu?.day.vegetarianMain, menuStore.todayMenu?.day.vegetarianSide]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let allEmployees = menuStore.todayMenu?.managedEmployees ?? []
        let eligibleEmployees = allEmployees.filter { $0.selection == nil }
        let eligibleIDs = Set(eligibleEmployees.map(\.id))
        let managerSelectable = menuStore.todayMenu?.selection == nil
        let allSelected = !eligibleIDs.isEmpty
            && selectedManagedEmployeeIds == eligibleIDs
            && (!managerSelectable || includeSelfForPendingChoice)
        let numberOfPeople = selectedManagedEmployeeIds.count
            + (managerSelectable && includeSelfForPendingChoice ? 1 : 0)

        ScrollView(showsIndicators: false) {
            VStack(spacing: 18) {
                Image(systemName: cancelling ? "xmark.circle.fill" :
                      (choice == "water" ? "takeoutbag.and.cup.and.straw.fill" : "leaf.fill"))
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(cancelling ? .red : (choice == "water" ? .cyan : .green))
                    .frame(width: 64, height: 64)
                    .background((cancelling ? Color.red : (choice == "water" ? Color.cyan : Color.green)).opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                VStack(spacing: 7) {
                    Text(cancelling ? "Hủy lựa chọn hôm nay?" : "Xác nhận \(title)")
                        .font(.title2.bold())
                    Text(cancelling ? "Bạn có thể chọn lại món khác trong thời gian cho phép."
                         : "Kiểm tra món và những người được đặt trước khi xác nhận.")
                        .font(.subheadline)
                        .foregroundColor(AppTheme.muted)
                        .multilineTextAlignment(.center)
                }

                if !cancelling {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title.uppercased())
                                .font(.caption.bold()).tracking(1).foregroundColor(AppTheme.muted)
                            Text(detail.isEmpty ? "..." : detail).font(.headline)
                        }
                        Spacer(minLength: 8)
                        if !allEmployees.isEmpty {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("SỐ NGƯỜI").font(.caption2.bold()).foregroundColor(AppTheme.muted)
                                Text("\(numberOfPeople)").font(.title2.bold()).monospacedDigit()
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(AppTheme.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                if !cancelling && !allEmployees.isEmpty {
                    HStack(spacing: 8) {
                        managerSelectionTile("Tôi",
                            selected: managerSelectable && includeSelfForPendingChoice,
                            enabled: managerSelectable) {
                            includeSelfForPendingChoice.toggle()
                        }
                        managerSelectionTile("Tất cả",
                            selected: allSelected,
                            enabled: !eligibleIDs.isEmpty) {
                            if allSelected {
                                selectedManagedEmployeeIds = []
                                if managerSelectable { includeSelfForPendingChoice = false }
                            } else {
                                selectedManagedEmployeeIds = eligibleIDs
                                if managerSelectable { includeSelfForPendingChoice = true }
                            }
                        }
                    }

                    Text("ĐẶT CÙNG NHÂN VIÊN")
                        .font(.caption.bold()).tracking(1.2).foregroundColor(AppTheme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        ForEach(allEmployees) { employee in
                            let canSelect = employee.selection == nil
                            let selected = selectedManagedEmployeeIds.contains(employee.id)
                            Button {
                                if selected {
                                    selectedManagedEmployeeIds.remove(employee.id)
                                } else {
                                    selectedManagedEmployeeIds.insert(employee.id)
                                }
                            } label: {
                                Text(employee.fullName.isEmpty ? employee.employeeCode : employee.fullName)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundColor(canSelect ? .primary : AppTheme.muted)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 11)
                                    .background(selected ? Color.green.opacity(0.16) :
                                        (canSelect ? AppTheme.card : AppTheme.card.opacity(0.45)))
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    .overlay {
                                        if selected {
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(Color.green.opacity(0.65), lineWidth: 1)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .disabled(!canSelect)
                        }
                    }
                }

                Button {
                    guard cancelling || numberOfPeople > 0 else { return }
                    pendingChoice = nil
                    Task {
                        if cancelling {
                            await session.cancelMealSelection()
                        } else if selectedManagedEmployeeIds.isEmpty && includeSelfForPendingChoice && managerSelectable {
                            await session.selectMeal(choice)
                        } else {
                            await session.selectMealWithManagedEmployees(
                                choice,
                                employeeIds: Array(selectedManagedEmployeeIds),
                                includeSelf: managerSelectable && includeSelfForPendingChoice
                            )
                        }
                    }
                } label: {
                    Text(cancelling ? "Xác nhận hủy" : "Đặt món")
                        .font(.headline).foregroundColor(.white)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(cancelling ? Color.red : AppTheme.red)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .disabled(!cancelling && numberOfPeople == 0)
                .opacity(!cancelling && numberOfPeople == 0 ? 0.45 : 1)

                Button("Quay lại") { pendingChoice = nil }
                    .font(.headline).foregroundColor(AppTheme.muted).padding(.vertical, 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 22)
            .padding(.top, 24)
            .padding(.bottom, 18)
            // Measure the VStack, not the ScrollView viewport. The latter
            // grows to the old sheet detent and creates empty space below
            // short confirmation / cancellation content.
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: MealSheetHeightPreferenceKey.self, value: proxy.size.height)
                }
            }
        }
        .onPreferenceChange(MealSheetHeightPreferenceKey.self) { height in
            guard height > 0 else { return }
            let maximumHeight = UIScreen.main.bounds.height * 0.82
            let measuredHeight = min(ceil(height + 8), maximumHeight)
            if abs(mealSheetHeight - measuredHeight) > 1 {
                mealSheetHeight = measuredHeight
            }
        }
        .fittedMealSheetSizing(fallbackHeight: mealSheetHeight)
        .presentationContentInteraction(.scrolls)
        .presentationDragIndicator(.visible)
        .attachedMealSheetCorners()
    }

    private func managerSelectionTile(
        _ title: String, selected: Bool, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(selected ? AppTheme.text(.green) :
                    (enabled ? Color.primary : AppTheme.muted))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(selected ? Color.green.opacity(0.16) :
                    (enabled ? AppTheme.card : AppTheme.card.opacity(0.45)))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay {
                    if selected {
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.green.opacity(0.65), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func selectedMealDetail(_ selection: String) -> String {
        if selection == "water" {
            return menuStore.todayMenu?.day.featured ?? "..."
        }
        let detail = [menuStore.todayMenu?.day.vegetarianMain, menuStore.todayMenu?.day.vegetarianSide]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? "..." : detail
    }

    private func delegatedMealHeader(_ choice: String) -> some View {
        let water = choice == "water"
        let color = water ? Color.cyan : Color.green
        let detail = selectedMealDetail(choice)
        return HStack(spacing: 13) {
            Image(systemName: water ? "takeoutbag.and.cup.and.straw.fill" : "leaf.fill")
                .font(.headline.weight(.bold))
                .foregroundColor(color)
                .frame(width: 44, height: 44)
                .background(color.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 3) {
                Text(water ? "Món nước" : "Món chay").font(.title3.bold())
                Text(detail).font(.subheadline).foregroundColor(AppTheme.muted).lineLimit(2)
            }
        }
    }

    private func menuGroup(_ title: String, icon: String, color: Color, lines: [String?]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.headline).foregroundColor(color).frame(width: 42, height: 42).background(color.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 13))
            Text(title.uppercased()).font(.caption2.bold()).tracking(1).foregroundColor(AppTheme.muted)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, value in
                Text(value?.isEmpty == false ? value! : "...")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .padding(15)
        .background(AppTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .shadow(color: Color.black.opacity(0.035), radius: 5, y: 2)
    }

    private func mealButton(
        _ title: String,
        detail: String?,
        icon: String,
        color: Color,
        choice: String,
        forManagedOnly: Bool = false
    ) -> some View {
        let selected = !forManagedOnly && menuStore.todayMenu?.selection == choice
        let fallbackAvailable = !(detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let available = choice == "water"
            ? (menuStore.todayMenu?.availableChoices?.water ?? fallbackAvailable)
            : (menuStore.todayMenu?.availableChoices?.vegetarian ?? fallbackAvailable)
        // The tile may be reused while live menu updates arrive. Prevent
        // a duplicate selection even if the sheet was opened just beforehand.
        let canChoose = available && menuStore.todayMenu?.selection != choice
        return Button {
            guard canChoose else { return }
            includeSelfForPendingChoice = !forManagedOnly
            selectedManagedEmployeeIds = []
            pendingChoice = choice
        } label: {
            HStack(spacing: 13) {
                Image(systemName: icon).font(.title3).foregroundColor(color).frame(width: 44, height: 44).background(color.opacity(0.14)).clipShape(RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(available ? (detail?.isEmpty == false ? detail! : "...") : "Đang trống").font(.caption).foregroundColor(AppTheme.muted).lineLimit(1)
                }
                Spacer()
                Image(systemName: selected ? "checkmark.circle.fill" : "circle").font(.title3).foregroundColor(selected ? .green : AppTheme.muted)
            }
            .padding(13)
            .background(selected ? Color.green.opacity(0.11) : Color.white.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
            .shadow(color: Color.black.opacity(selected ? 0.05 : 0.03), radius: 5, y: 2)
        }
        .buttonStyle(.plain)
        .disabled(isSessionWorking || !canChoose)
        .opacity(canChoose ? 1 : 0.58)
    }
}

private struct MealReceiptStatusRow: View {
    let title: String
    let receivedAt: String?

    var body: some View {
        let received = receivedAt != nil
        let color = received ? Color.green : Color.orange
        HStack(spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 8)
            Label(received ? "Đã nhận" : "Chưa nhận",
                  systemImage: received ? "checkmark.circle.fill" : "clock")
                .font(.caption.weight(.semibold))
                .foregroundColor(AppTheme.text(color, chipAlpha: 0.12))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

private struct GroupedMealReceiptRows: View {
    let pendingNames: [String]
    let receivedNames: [String]

    var body: some View {
        VStack(spacing: 12) {
            if !pendingNames.isEmpty {
                MealReceiptStatusRow(title: pendingNames.joined(separator: ", "), receivedAt: nil)
            }
            if !receivedNames.isEmpty {
                MealReceiptStatusRow(title: receivedNames.joined(separator: ", "), receivedAt: "received")
            }
        }
    }
}

struct MealSheetHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    @ViewBuilder
    func mealConfirmationSheet<SheetContent: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> SheetContent
    ) -> some View {
        sheet(isPresented: isPresented, content: content)
    }

    @ViewBuilder
    func attachedMealSheetCorners() -> some View {
        if #available(iOS 26.0, *) {
            self
        } else {
            presentationCornerRadius(28)
        }
    }

    @ViewBuilder
    func fittedMealSheetSizing(fallbackHeight: CGFloat) -> some View {
        presentationDetents([.height(fallbackHeight)])
    }
}
