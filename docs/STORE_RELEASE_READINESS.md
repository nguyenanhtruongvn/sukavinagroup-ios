# Sukavina Store Release Readiness

Last reviewed: 2026-07-24

## Technical Status

| Area | iOS | Android |
| --- | --- | --- |
| Native implementation | Swift / SwiftUI | Kotlin / Jetpack Compose |
| Minimum OS | iOS 17 | Android 10 (API 29) |
| Current SDK target | Current Xcode SDK | Android 16 (API 36) |
| Secure session storage | Keychain | EncryptedSharedPreferences |
| Biometric sign-in | Face ID / Touch ID | BiometricPrompt |
| Push notification permission | Supported | Android 13+ runtime permission |
| Realtime updates | Server-Sent Events | Server-Sent Events |
| Attendance widget | WidgetKit | AppWidget |
| Account deletion | In-app request | In-app request |
| Privacy manifest | App and widget | Not required by Android |
| Store package | Signed archive is required | Signed AAB is required |

## Public URLs

- Privacy policy: https://sukavinagroup.net/privacy-policy
- Support: https://sukavinagroup.net/support
- Account deletion: https://sukavinagroup.net/account-deletion

The account deletion page must remain accessible without signing in. It explains both
the in-app deletion flow and how to submit a deletion request outside the app.

## Data Disclosure Baseline

Store declarations must match the production behavior and privacy policy:

- Name
- Email address
- Phone number
- Employee or user identifier
- Attendance records
- Internal request forms and approval history
- Product interaction and operational security logs

The data is linked to the employee account, used for app functionality, security,
support, and employee communications. The app does not use advertising SDKs and does
not declare cross-app tracking.

## App Store Connect Checklist

- Enroll the organization in the Apple Developer Program.
- Create the app record using bundle identifier `net.sukavinagroup.portal`.
- Create distribution certificates and provisioning profiles for the app and widget.
- Archive and upload a signed release build. The unsigned SideStore IPA is not valid
  for App Store submission.
- Enter the privacy policy and support URLs above.
- Complete App Privacy answers using the data disclosure baseline.
- Complete export compliance, content rights, age rating, and availability questions.
- Add screenshots and store metadata for supported device sizes.
- Provide a working reviewer employee account and explain how to reach attendance,
  requests, notifications, biometrics, password change, and account deletion.
- Verify that the reviewer account does not require access to an internal-only network.
- Test account deletion against production before submission.

## Google Play Console Checklist

- Create the Play app using package name `net.sukavinagroup.user`.
- Enable Play App Signing and create a protected upload key.
- Add these GitHub Actions secrets:
  - `ANDROID_KEYSTORE_BASE64`
  - `ANDROID_KEYSTORE_PASSWORD`
  - `ANDROID_KEY_ALIAS`
  - `ANDROID_KEY_PASSWORD`
- Upload the signed release AAB, not the debug APK.
- Enter the privacy policy and account deletion URLs above.
- Complete Data safety using the data disclosure baseline.
- Complete App access with a working reviewer employee account and instructions.
- Complete content rating, ads declaration, target audience, and store listing.
- Add phone and tablet screenshots plus the required feature graphic.
- Complete any testing track requirement shown for the Play developer account.
- Test account deletion against production before production rollout.

## Release Gate

A release is ready to submit only when:

1. Website tests and production smoke tests pass.
2. Android debug and release lint pass and the release AAB builds.
3. iOS Release builds with the app, widget, privacy manifests, and App Group intact.
4. Signed production packages use store-owned signing identities.
5. Public legal URLs load without authentication.
6. Reviewer credentials and all store declarations are current.

Store approval cannot be guaranteed by source code alone. Apple and Google also review
the submitted metadata, account configuration, reviewer access, content, privacy
answers, signed package, and runtime behavior.
