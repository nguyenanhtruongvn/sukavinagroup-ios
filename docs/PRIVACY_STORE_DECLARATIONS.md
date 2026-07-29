# Sukavina Privacy and Store Declarations

Last reviewed: 2026-07-29

## Product Scope

Sukavina is an internal employee application. Accounts are created and administered
by Sukavina Group and are not available through public self-registration. The app has
no advertising, advertising identifier, cross-app tracking, data broker integration,
or advertising/analytics SDK.

Internal use does not make employee data exempt from Apple App Privacy or Google Play
Data safety declarations. Data sent from a device to the Sukavina server is treated as
collected even when the company originally provisioned it.

## Code Audit Summary

- iOS permissions: Face ID usage description only.
- Android permissions: Internet and notifications only.
- No location, contacts, photos, camera, microphone, Bluetooth, health, payment, or
  advertising permissions.
- iOS stores sessions in Keychain and protects biometric sign-in with the current
  biometric set. Android stores the session in encrypted preferences.
- Biometrics are evaluated by the operating system; biometric templates are not
  available to the app or server.
- Notifications are generated from authenticated server updates. The current code
  does not upload APNs or Firebase advertising/device identifiers.

## Apple App Privacy Answers

Select "Yes, we collect data from this app."

Declare these linked, non-tracking data types for App Functionality:

| Apple category | Data type | Additional purpose |
| --- | --- | --- |
| Contact Info | Name | None |
| Contact Info | Email Address | Developer Communications |
| Contact Info | Phone Number | None |
| Identifiers | User ID | Account authentication |
| User Content | Other User Content | Attendance, requests, notes, meal choices |
| Usage Data | Product Interaction | Security, notification/read state, support |

Do not select advertising, marketing, analytics, product personalization, precise or
coarse location, device ID, photos, audio, contacts, health, financial information,
purchases, browsing history, search history, diagnostics, or sensitive information
unless a future production release adds those behaviors.

Privacy Policy URL: `https://sukavinagroup.net/privacy-policy`

Privacy Choices URL: `https://sukavinagroup.net/account-deletion`

## Google Play Data Safety Answers

For a public, closed, or production Play listing, answer that the app collects data.
Declare the following as collected, required, encrypted in transit, not sold, and not
shared with third parties other than service providers acting for Sukavina:

| Google category | Data type | Purpose |
| --- | --- | --- |
| Personal info | Name | App functionality, account management |
| Personal info | Email address | App functionality, account management, communications |
| Personal info | Phone number | App functionality, account management |
| Personal info | User IDs | App functionality, account management |
| App activity | App interactions | App functionality, security |
| App info and performance | Crash logs / diagnostics | Select only if production logging records these |
| Other user-generated content | Attendance, requests, notes, meal choices | App functionality |

The app contains no ads. Do not declare location, contacts, photos, camera, microphone,
health, financial, payment, purchase, messages, web browsing, advertising ID, or
cross-app tracking.

Google states that apps exclusively active on internal testing and private apps do
not need to display the Data safety form. Keep this baseline anyway because it becomes
required if the release moves to closed, open, or production distribution.

Privacy Policy URL: `https://sukavinagroup.net/privacy-policy`

Account Deletion URL: `https://sukavinagroup.net/account-deletion`

## Account Lifecycle

The production clients do not offer account creation. Accounts are provisioned by the
company. The app and public website still provide a deletion request path. Deletion
removes the app account and data that is not required for employment, security,
dispute, or legal retention. The privacy policy must not promise deletion of records
the company is legally required to retain.

## Release Rules

1. Keep the public privacy, support, and deletion URLs accessible without login.
2. Give reviewers a working employee test account and explain that registration is
   company-managed.
3. Update store declarations whenever permissions, SDKs, server logging, or data
   features change.
4. Re-audit every third-party SDK before release.
5. Store approval cannot be guaranteed by source code; metadata, reviewer access,
   signing, screenshots, runtime behavior, and organization status are also reviewed.
