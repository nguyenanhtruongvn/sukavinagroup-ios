# Sukavina Group Platform

Monorepo chính thức cho hệ thống nội bộ Sukavina Group. Dự án gồm website nhân viên, website quản trị, API và hai ứng dụng mobile native.

## Cấu trúc

| Thư mục | Thành phần | Công nghệ |
| --- | --- | --- |
| `apps/web` | Website nhân viên `/` và quản trị `/admin` | React, TypeScript, Vite |
| `apps/api` | API, xác thực, nội dung, nhân viên, chấm công | NestJS, Prisma, PostgreSQL |
| `apps/ios` | Ứng dụng iPhone/iPad native | Swift, SwiftUI |
| `apps/android` | Ứng dụng Android native | Kotlin, Jetpack Compose |
| `prisma` | Schema cơ sở dữ liệu | Prisma |
| `deploy` | Cấu hình triển khai mẫu | Docker, Nginx |

Website thường và website quản trị dùng chung một React application nhưng được phân tách theo route và quyền truy cập. iOS và Android gọi trực tiếp cùng API tại `https://sukavinagroup.net/api/`; hai app không dùng WebView.

## Phát triển website và API

Yêu cầu Node.js 22 và pnpm 11.

```bash
corepack enable
pnpm install
pnpm prisma:generate
pnpm build
pnpm test
```

Tạo `.env` từ `.env.example`. Không commit `.env`, token, mật khẩu, dữ liệu PostgreSQL hoặc media thật.

## Xem trước iOS trong Xcode

1. Mở `apps/ios/App/App.xcodeproj` bằng Xcode.
2. Mở `App/AppDelegate.swift`.
3. Chọn **Editor > Canvas** hoặc nhấn `Option + Command + Enter`.
4. Chọn một preview: **Đăng nhập**, **Trang chủ nhân viên** hoặc **Khởi động**.
5. Nhấn **Resume** nếu Canvas đang tạm dừng.

Preview dùng dữ liệu mẫu tại máy, không đăng nhập và không thay đổi dữ liệu thật. Workflow `Build unsigned iOS IPA` tạo IPA unsigned để kiểm tra gói build.

## Xem trước Android

1. Mở thư mục `apps/android` bằng Android Studio.
2. Mở `app/src/main/java/net/sukavinagroup/user/ui/SukavinaApp.kt`.
3. Chọn chế độ **Split** hoặc **Design**.
4. Android Studio hiển thị preview **Đăng nhập** và **Trang chủ nhân viên**.

Workflow `Build native Android APK` chạy lint và tạo APK debug có thể cài thử.

## CI/CD

- `Repository quality`: build và test website/API.
- `Build unsigned iOS IPA`: biên dịch Swift và đóng gói IPA unsigned.
- `Build native Android APK`: lint Kotlin và tạo APK debug.

Chi tiết kiến trúc và nguyên tắc vận hành nằm tại [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).
