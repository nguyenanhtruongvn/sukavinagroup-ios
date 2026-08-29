# Sukavina iOS

<p align="center">
  <img src="apps/ios/App/App/Assets.xcassets/AppIcon.appiconset/AppIcon-512@2x.png" width="180" alt="Sukavina">
</p>

Mã nguồn iPhone/iPad native của hệ thống nội bộ Sukavina Group. Ứng dụng được viết bằng SwiftUI và dùng trực tiếp API tại `https://sukavinagroup.net/api/`.

## Cấu trúc mã nguồn

| Đường dẫn | Nội dung |
| --- | --- |
| `apps/ios/App/App.xcodeproj` | Dự án Xcode chính |
| `apps/ios/App/App` | Ứng dụng SwiftUI |
| `apps/ios/App/AttendanceWidget` | Widget chấm công |
| `.github/workflows/build-ios-unsigned.yml` | Build IPA unsigned cho SideStore |

## Mở và chạy bằng Xcode

1. Mở `apps/ios/App/App.xcodeproj` bằng Xcode.
2. Mở `App/AppDelegate.swift`.
3. Chọn **Editor > Canvas** hoặc nhấn `Option + Command + Enter`.
4. Chọn một preview: **Đăng nhập**, **Trang chủ nhân viên** hoặc **Khởi động**.
5. Nhấn **Resume** nếu Canvas đang tạm dừng.

Preview dùng dữ liệu mẫu tại máy, không đăng nhập và không thay đổi dữ liệu thật.

## Build IPA cho SideStore

1. Vào tab **Actions** của repository.
2. Chọn workflow **Build unsigned iOS IPA**.
3. Chọn **Run workflow** trên nhánh `main`.
4. Khi workflow hoàn tất, mở lần chạy và tải artifact IPA.
5. Đưa IPA lên GitHub Release trong repository SideStore, sau đó cập nhật `apps.json` với version, ngày, dung lượng và URL tải.

Workflow dùng phiên bản đặt trong Xcode project (hiện `1.0.5`, build `24`) và chỉ tạo artifact IPA. IPA là unsigned để SideStore ký lại bằng Apple ID của thiết bị.

## Lưu ý an toàn

- Không thêm chứng chỉ, provisioning profile, mật khẩu hoặc token vào repository.
- Giữ nguyên bundle identifier `net.sukavinagroup.user` để SideStore cập nhật đè lên ứng dụng hiện có.
