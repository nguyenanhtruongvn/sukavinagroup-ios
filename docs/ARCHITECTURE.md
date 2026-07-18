# Kiến trúc Sukavina Group Platform

## Luồng hệ thống

```text
Web nhân viên ─┐
Web quản trị  ─┼─ HTTPS ─> NestJS API ─> PostgreSQL
iOS native    ─┤                 ├──────> Media storage
Android native┘                 └──────> WiseEye Proxy
```

## Phân tách trách nhiệm

- `apps/web` chỉ xử lý giao diện web, route `/` và `/admin` cùng trạng thái trình duyệt.
- `apps/api` là nguồn quy tắc nghiệp vụ duy nhất. Mọi giới hạn quyền, tháng chấm công và xác thực phải được kiểm tra lại ở API, không chỉ ở giao diện.
- `apps/ios` và `apps/android` là ứng dụng native độc lập, đồng bộ qua REST và SSE.
- `prisma/schema.prisma` là nguồn định nghĩa cấu trúc database duy nhất.

## Bảo mật

- Chỉ dùng HTTPS ở môi trường thật.
- Token mobile được lưu trong Keychain trên iOS và EncryptedSharedPreferences trên Android.
- Không ghi token, mật khẩu hoặc nội dung `.env` vào log.
- Tài khoản admin tổng được bảo vệ ở API, không phụ thuộc nút ẩn trên giao diện.
- API chấm công chỉ cho phép tháng hiện tại và tháng trước.

## Real-time

API phát sự kiện SSE khi nội dung, tài khoản hoặc chấm công thay đổi. Web và mobile nhận sự kiện rồi tải lại dữ liệu từ endpoint có xác thực. SSE chỉ là tín hiệu thay đổi, không mang dữ liệu nhạy cảm.

## Quy trình thay đổi

1. Sửa source trong monorepo, không sửa trực tiếp bundle `dist`.
2. Chạy build/test tương ứng.
3. Đẩy commit để GitHub Actions xác minh cả nền tảng bị ảnh hưởng.
4. Triển khai website/API từ commit đã kiểm tra.
5. Không commit artifact, backup, database dump hoặc thông tin máy chủ.
