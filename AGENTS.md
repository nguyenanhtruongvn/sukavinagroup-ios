# Hướng dẫn dự án Sukavina

## Phạm vi thực hiện

- Chỉ thay đổi đúng nền tảng hoặc thành phần mà người dùng yêu cầu.
- Không tự động chạy, build hoặc triển khai các thành phần không nằm trong yêu cầu hiện tại.
- Không cập nhật, khởi động lại hoặc triển khai lên VPS nếu người dùng chưa yêu cầu rõ ràng.
- Luôn ưu tiên giữ máy chủ đang hoạt động ổn định.

## Android

- Khi người dùng yêu cầu sửa Android, chỉ sửa mã nguồn Android trong `apps/android`.
- Build và kiểm tra Android trên máy local để người dùng xem bằng Android Studio hoặc máy ảo.
- Không triển khai Android lên VPS.
- Không build hoặc phát hành iOS khi yêu cầu chỉ liên quan đến Android.

## iOS

- Khi người dùng yêu cầu sửa iOS, chỉ sửa mã nguồn iOS trong `apps/ios`.
- Sau khi sửa, build IPA iOS và phát hành lên repo SideStore.
- Xác nhận workflow hoàn tất thành công và cung cấp liên kết tải IPA.
- Không chạy Android hoặc cập nhật VPS khi yêu cầu chỉ liên quan đến iOS.

## Website và VPS

- Không coi việc sửa mã nguồn website là quyền tự động triển khai lên VPS.
- Chỉ triển khai website hoặc API lên VPS khi người dùng yêu cầu rõ ràng.
- Trước khi triển khai phải kiểm tra build và tránh làm gián đoạn máy chủ đang hoạt động.

## Phiên bản

- Các bản build Android và iOS sử dụng phiên bản `2.x` trở đi.

## Bổ sung hướng dẫn

- Khi người dùng yêu cầu thêm quy tắc ghi nhớ cho dự án, cập nhật file này và giữ nguyên các quy tắc cũ không mâu thuẫn.
