# Sukavina Store Release Readiness

Last reviewed: 2026-07-29

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

## Internal App Positioning

Sukavina is an employee-only app. Accounts are provisioned and administered by
Sukavina Group; the mobile apps do not offer public self-registration. This does not
mean the apps can declare "no data collected": employee records and work activity are
transmitted to and stored on the company server.

Recommended store description:

> Sukavina is an internal workforce application available only to authorized
> employees. It contains no advertising, does not track users across apps or
> websites, and does not sell personal data.

Do not state that the app "collects no personal data." Store declarations use the
technical meaning of collection, which includes linked data transmitted off-device.

## Data Disclosure Baseline

Store declarations must match the production behavior and privacy policy:

- Personal information: name, email address, phone number, employee/user identifier.
- Employment information: department, job title, manager, hire date, contract type,
  leave balance.
- Other user content: attendance records, internal requests and approval notes, meal
  selections, internal notifications and their read state.
- Product interaction: authentication, security events and minimal operational logs.

The data is linked to the employee account, used for app functionality, security,
account management, support, and employee communications. It is required for the
app's internal functions. The app does not use advertising or analytics SDKs and does
not declare cross-app tracking, advertising, marketing, location, contacts, photos,
camera, microphone, health, financial, or purchase data.

Biometric templates are not collected. Face ID, Touch ID, and Android biometric
matching happen through operating-system APIs on the device; the app receives only
the authentication result.

## App Store Connect Checklist

- Enroll the organization in the Apple Developer Program.
- Create the app record using bundle identifier `net.sukavinagroup.portal`.
- Create distribution certificates and provisioning profiles for the app and widget.
- Archive and upload a signed release build. The unsigned SideStore IPA is not valid
  for App Store submission.
- Enter the privacy policy and support URLs above.
- Complete App Privacy answers using the data disclosure baseline.
- Mark disclosed data as linked to the user, not used for tracking, and used for App
  Functionality. Use Developer Communications for email where applicable.
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
- Mark disclosed data as collected, required, encrypted in transit, not shared for
  advertising, and used for App functionality and Account management. Operational
  security events may also use Fraud prevention, security, and compliance.
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
