## Mở và chạy bằng Xcode

1. Mở `apps/ios/App/App.xcodeproj` bằng Xcode.
2. Mở `App/AppDelegate.swift`.
3. Chọn **Editor > Canvas** hoặc nhấn `Option + Command + Enter`.
4. Chọn một preview: **Đăng nhập**, **Trang chủ nhân viên** hoặc **Khởi động**.
5. Nhấn **Resume** nếu Canvas đang tạm dừng.

Preview dùng dữ liệu mẫu tại máy, không đăng nhập và không thay đổi dữ liệu thật.

## Build IPA cho SideStore

0. Thay đổi (4 nơi) MARKETING_VERSION và CURRENT_PROJECT_VERSION ở đường dẫn: apps/ios/App/App.xcodeproj/project.pbxproj.
1. Vào tab **Actions** của repository.
2. Chọn workflow **Build unsigned iOS IPA**.
3. Chọn nhánh `main` và chọn **Publish to SideStore** khi muốn phát hành.
4. Khi không chọn publish, workflow chỉ tạo artifact IPA để kiểm tra.
