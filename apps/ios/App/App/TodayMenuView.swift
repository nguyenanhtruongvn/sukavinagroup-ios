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
    @State private var pendingChoice: String?
    @State private var mealSheetHeight: CGFloat = 420

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
                            if menuStore.todayMenu?.receivedAt == nil {
                                MealQRCodeAccessCard()
                            } else {
                                Label("Đã nhận món", systemImage: "checkmark.seal.fill")
                                    .font(.headline).foregroundColor(AppTheme.text(.green))
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background(Color.green.opacity(0.11))
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
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
                await session.refreshTodayMenu()
            }
            .onReceive(session.$isWorking) { isSessionWorking = $0 }
            .mealConfirmationSheet(isPresented: Binding(get: { pendingChoice != nil }, set: { if !$0 { pendingChoice = nil } })) {
                let choice = pendingChoice ?? "water"
                let cancelling = choice == "cancel"
                let title = choice == "water" ? "Món nước" : "Món chay"
                let detail = choice == "water"
                    ? (menuStore.todayMenu?.day.featured ?? "...")
                    : [menuStore.todayMenu?.day.vegetarianMain, menuStore.todayMenu?.day.vegetarianSide].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                VStack(spacing: 18) {
                    Image(systemName: cancelling ? "xmark.circle.fill" : (choice == "water" ? "takeoutbag.and.cup.and.straw.fill" : "leaf.fill"))
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(cancelling ? .red : (choice == "water" ? .cyan : .green))
                        .frame(width: 64, height: 64)
                        .background((cancelling ? Color.red : (choice == "water" ? Color.cyan : Color.green)).opacity(0.13))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                    VStack(spacing: 7) {
                        Text(cancelling ? "Hủy lựa chọn hôm nay?" : "Xác nhận \(title)")
                            .font(.title2.bold())
                        Text(cancelling ? "Bạn có thể chọn lại món khác bất cứ lúc nào trong ngày." : "Kiểm tra món trước khi xác nhận đặt.")
                            .font(.subheadline).foregroundColor(AppTheme.muted).multilineTextAlignment(.center)
                    }
                    if !cancelling {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(title.uppercased()).font(.caption.bold()).tracking(1).foregroundColor(AppTheme.muted)
                            Text(detail.isEmpty ? "..." : detail).font(.headline)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16).background(AppTheme.card).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Button {
                        pendingChoice = nil
                        Task {
                            if cancelling { await session.cancelMealSelection() }
                            else { await session.selectMeal(choice) }
                        }
                    } label: {
                        Text(cancelling ? "Xác nhận hủy" : "Xác nhận đặt món")
                            .font(.headline).foregroundColor(.white).frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(cancelling ? Color.red : AppTheme.red).clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    Button("Quay lại") { pendingChoice = nil }
                        .font(.headline).foregroundColor(AppTheme.muted).padding(.vertical, 5)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 22)
                    // Room for Apple's drag indicator above the icon.
                    .padding(.top, 24)
                    .padding(.bottom, 18)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: MealSheetHeightPreferenceKey.self, value: proxy.size.height)
                    }
                }
                .onPreferenceChange(MealSheetHeightPreferenceKey.self) { height in
                    guard height > 0 else { return }
                    mealSheetHeight = min(max(height + 8, 300), UIScreen.main.bounds.height * 0.82)
                }
                .fittedMealSheetSizing(fallbackHeight: mealSheetHeight)
                // In the menu card, a downward pull is a sheet-dismiss gesture;
                // refreshing remains available from the dashboard itself.
                .presentationContentInteraction(.resizes)
                .presentationDragIndicator(.visible)
                .attachedMealSheetCorners()
            }
        }
    }

    private func selectedMealDetail(_ selection: String) -> String {
        if selection == "water" {
            return menuStore.todayMenu?.day.featured ?? "..."
        }
        let detail = [menuStore.todayMenu?.day.vegetarianMain, menuStore.todayMenu?.day.vegetarianSide]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return detail.isEmpty ? "..." : detail
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

    private func mealButton(_ title: String, detail: String?, icon: String, color: Color, choice: String) -> some View {
        let selected = menuStore.todayMenu?.selection == choice
        let fallbackAvailable = !(detail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let available = choice == "water"
            ? (menuStore.todayMenu?.availableChoices?.water ?? fallbackAvailable)
            : (menuStore.todayMenu?.availableChoices?.vegetarian ?? fallbackAvailable)
        return Button {
            if available { pendingChoice = choice }
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
        .disabled(isSessionWorking || !available)
        .opacity(available ? 1 : 0.58)
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
