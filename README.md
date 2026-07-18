# Sukavina User native apps

Ung dung iOS dong bo truc tiep voi https://sukavinagroup.net.

## Build unsigned IPA

Mo tab **Actions**, chon **Build unsigned iOS IPA**, sau do chon **Run workflow**. File ket qua nam trong artifact `Sukavina-Portal-unsigned-IPA`.

IPA unsigned dung de kiem tra goi build. De cai truc tiep len iPhone, tep van can duoc ky bang chung chi Apple hoac mot dich vu ky phu hop.

## Android Kotlin

Ung dung Android nam tai `apps/android`, duoc viet hoan toan bang Kotlin va Jetpack Compose, khong dung WebView. Moi lan thay doi ma Android tren nhanh `main`, GitHub Actions se tao artifact `Sukavina-Android-debug-APK` de cai thu tren thiet bi Android.
