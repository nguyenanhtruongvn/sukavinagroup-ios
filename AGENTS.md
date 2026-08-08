# Quy tắc vận hành dự án Sukavina

## Nguồn mã chính

- Mã nguồn chính thức nằm trên VPS tại `/opt/projects/sukavina`.
- Khi được yêu cầu sửa mã nguồn, thực hiện thay đổi trên bản chính ở VPS.
- Bản backup nằm tại `/opt/projects/sukavina-pre-github-sync-20260731` và phải luôn được giữ để khôi phục khi cần.
- Trước thay đổi có rủi ro, kiểm tra bản backup và bảo đảm có thể khôi phục bản đang chạy.

## GitHub

- Không tự ý đồng bộ hoặc đẩy mã nguồn lên GitHub khi người dùng chưa yêu cầu.
- Ngoại lệ duy nhất là quy trình cần thiết để build và phát hành IPA iOS hoặc APK Android.
- Không coi GitHub là nguồn mã chính; VPS là nguồn mã chính thức.

## Website và API

- Khi sửa website hoặc API, sửa trực tiếp trên bản chính ở VPS.
- Sau khi build thành công, triển khai website/API chạy chính thức.
- Giữ dịch vụ ổn định, hạn chế tối đa thời gian gián đoạn.
- Không thay đổi hoặc xóa dữ liệu PostgreSQL trong quá trình triển khai.

## iOS

- Khi sửa app iOS, sửa mã nguồn iOS trên VPS.
- Build IPA và phát hành bản mới lên repo SideStore.
- Xác nhận workflow thành công và cung cấp liên kết tải IPA.
- Ưu tiên cao nhất là tuân thủ quy định, quyền riêng tư, bảo mật và yêu cầu kỹ thuật của Apple để đủ điều kiện phát hành App Store và không bị thu hồi.

## Android

- Khi sửa app Android, sửa mã nguồn Android trên VPS.
- Build APK và phát hành APK lên GitHub.
- Xác nhận build, lint và artifact APK thành công trước khi bàn giao.
- Ưu tiên cao nhất là tuân thủ chính sách, quyền riêng tư, bảo mật và yêu cầu kỹ thuật của Google Play để đủ điều kiện phát hành và không bị thu hồi.

## Phiên bản

- Android và iOS dùng phiên bản `x.y.z`, bắt đầu lại từ `2.0.1`.
- Mỗi bản mới tăng `z` một đơn vị.
- Sau `x.y.99`, tăng `y` một đơn vị và đặt `z = 1`.
- Sau `x.99.99`, tăng `x` một đơn vị, đặt `y = 0` và `z = 1`.
- Ví dụ: `2.0.1` → `2.0.2` → … → `2.0.99` → `2.1.1` → … → `2.99.99` → `3.0.1`.
- Trước mỗi lần build, kiểm tra phiên bản gần nhất của đúng nền tảng để tránh trùng hoặc giảm phiên bản.

## Bản quyền và sở hữu trí tuệ

- Website, API, Android, iOS, widget và nội dung phát hành trên Store không được vi phạm bản quyền, nhãn hiệu hoặc quyền sở hữu trí tuệ của bên thứ ba.
- Chỉ dùng nội dung do Sukavina sở hữu/tự tạo hoặc tài nguyên có giấy phép và bằng chứng quyền sử dụng hợp lệ; không coi nội dung tìm thấy trên Internet là được phép sử dụng.
- Trước khi thêm hình ảnh, biểu tượng, phông chữ, âm thanh, video, mã nguồn hoặc nội dung bên thứ ba, phải lưu nguồn, giấy phép, tác giả, ngày tải và nghĩa vụ ghi công.
- Trước mỗi lần phát hành Android/iOS và khi thêm tài nguyên mới cho website, phải kiểm tra lại giấy phép phụ thuộc và nguồn gốc tài nguyên.
- Không xóa thông báo bản quyền hoặc giấy phép bắt buộc. Phải duy trì danh mục thông báo mã nguồn mở và hồ sơ chứng minh quyền sử dụng logo/tài sản thương hiệu Sukavina.
- Nội dung do quản trị viên tải lên phải thuộc quyền sở hữu của Sukavina hoặc đã được cấp phép hợp lệ.

## Bổ sung hướng dẫn

- Khi người dùng yêu cầu ghi nhớ hoặc bổ sung quy tắc dự án, cập nhật cả file này và `AGENTS.md` trên bản chính ở VPS.
- Giữ nguyên các quy tắc cũ không mâu thuẫn; quy tắc mới và yêu cầu trực tiếp mới nhất của người dùng được ưu tiên.
## Quản lý dung lượng VPS

- Chủ động kiểm tra dung lượng ổ đĩa trước và sau các lần build hoặc triển khai; không để VPS đầy bộ nhớ.
- Sau khi xác nhận bản mới hoạt động ổn định, dọn Docker image dangling, container đã dừng, cache build và tệp tạm không còn sử dụng.
- Không xóa container/image đang chạy, volume PostgreSQL, mã nguồn chính, cấu hình môi trường, khóa truy cập, artifact phát hành hoặc bản backup cần thiết.
- Khi dung lượng vượt 80%, phải kiểm tra nguyên nhân và ưu tiên dọn an toàn; khi vượt 90%, xử lý ngay trước khi thực hiện build lớn tiếp theo.
- Thông báo ngắn gọn dung lượng trước/sau và những nhóm dữ liệu đã dọn.

## Bảo mật và chống xâm nhập

- Website, API, ứng dụng iOS, ứng dụng Android, dữ liệu và hạ tầng VPS phải luôn được thiết kế, sửa đổi và vận hành với ưu tiên bảo vệ trước truy cập trái phép, đánh cắp tài khoản, rò rỉ dữ liệu, giả mạo yêu cầu và dịch ngược ứng dụng.
- Không lưu mật khẩu, JWT, khóa ký, OTP secret, khóa API hoặc thông tin kết nối thật trong mã nguồn, GitHub, log hay tệp có quyền đọc công khai. Secret sản xuất chỉ nằm trong kho bí mật hoặc `.env` trên VPS với quyền tối thiểu.
- Website ưu tiên phiên đăng nhập bằng cookie `HttpOnly`, `Secure`, `SameSite`; không lưu access token trong `localStorage`. iOS lưu secret trong Keychain; Android lưu secret bằng Android Keystore hoặc vùng lưu trữ đã mã hóa.
- Chỉ truyền dữ liệu qua HTTPS; chặn cleartext HTTP trong ứng dụng. Duy trì HSTS, CSP, CORS giới hạn, rate limit đăng nhập, firewall, Fail2Ban và SSH key; không cho phép SSH bằng mật khẩu.
- Bản release Android phải bật tối ưu/làm rối mã; bản iOS phải dùng cơ chế bảo vệ tiêu chuẩn của Apple. Không nhúng secret có thể dùng lâu dài vào IPA hoặc APK.
- Trước thay đổi bảo mật hoặc xoay khóa phải tạo backup có quyền truy cập hạn chế, kiểm thử khả năng khôi phục và giữ tương thích API với ứng dụng đang phát hành. Sau khi xoay khóa, chấp nhận yêu cầu người dùng đăng nhập lại.
- Không tuyên bố hệ thống an toàn tuyệt đối. Định kỳ kiểm tra dependency, quyền file, cổng mạng, log đăng nhập, chứng chỉ TLS và các khuyến nghị OWASP; xử lý ngay lỗ hổng mức nghiêm trọng hoặc cao.

## Đồng bộ Android Studio và GitHub

- Khi người dùng yêu cầu đồng bộ mã Android lên GitHub, phải đồng bộ vào đúng repository, nhánh và thư mục hiện đang được Android Studio sử dụng: repository `nguyenanhtruongvn/sukavinagroup`, nhánh `main`, project `apps/android`.
- Sau khi đẩy mã lên GitHub, phải cập nhật hoặc xác nhận checkout tại `C:\Users\USER\Documents\Sukavinagroup\ios-github` đã cùng commit với `origin/main`, sau đó refresh/Gradle Sync project `apps/android` trong Android Studio.
- Không được coi một repository, nhánh hoặc bản sao khác là đã đồng bộ cho Android Studio.
- Khi sửa Android, chỉ build và chạy debug cục bộ trên Android Studio/máy ảo để kiểm tra; không phát hành APK trừ khi người dùng yêu cầu rõ ràng.

## Quy trình build iOS

- Khi sửa app iOS, chỉ chạy quy trình build/phát hành IPA dành cho repo SideStore; không build iOS ở local, VPS hoặc các nơi không phục vụ bản phát hành SideStore.
- Không chạy build Android, website hoặc dịch vụ khác khi yêu cầu hiện tại chỉ liên quan đến iOS.
