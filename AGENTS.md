# AGENTS.md

## Scope

This file applies to the entire repository unless a more specific `AGENTS.md` exists deeper in the tree.

This repository contains the native iOS Sukavina app. Use Swift for iOS implementation work. Preserve the existing architecture and server contracts unless a task explicitly requires a coordinated contract change.

## Repository map

Primary iOS project:

```text
apps/ios/App/
├── App.xcodeproj/
│   └── project.pbxproj
├── App/
│   ├── AppDelegate.swift
│   ├── AppPreviews.swift
│   ├── AuthenticationViews.swift
│   ├── DesignSystem.swift
│   ├── EmployeeViews.swift
│   ├── MealViews.swift
│   ├── MeetingLiveActivityActionIntent.swift
│   ├── MeetingLiveActivityAttributes.swift
│   ├── MeetingLiveActivityManager.swift
│   ├── Networking.swift
│   ├── NotificationViews.swift
│   ├── PortalModels.swift
│   ├── ProfileViews.swift
│   ├── RequestViews.swift
│   ├── SessionStore.swift
│   ├── Info.plist
│   ├── App.entitlements
│   ├── PrivacyInfo.xcprivacy
│   └── Assets.xcassets/
└── AttendanceWidget/
    ├── AttendanceWidget.swift
    ├── AttendanceWidget.entitlements
    ├── Info.plist
    ├── PrivacyInfo.xcprivacy
    └── WidgetBackground.jpg
```

Main Xcode targets:

- `App`
- `AttendanceWidget`

Current deployment target is iOS 17.0.

## Architectural overview

### App lifecycle and root UI

`AppDelegate.swift` owns the native UIKit lifecycle and hosts SwiftUI content. The project deliberately avoids relying on newer SwiftUI-only application paths that can introduce runtime compatibility problems on iOS 17 when built with newer Xcode versions.

The root SwiftUI view selects among:

- restoring session
- signed out / authentication
- signed in employee portal
- canteen scanner mode for canteen accounts

Do not casually replace the current UIKit-hosted root lifecycle with a pure SwiftUI `@main App` architecture.

### Shared state and business orchestration

`SessionStore.swift` is the central state and orchestration layer. It owns or coordinates:

- authentication/session restoration
- access and refresh tokens
- profile/dashboard state
- attendance state and cache
- article/notification counters
- meal state
- meeting rooms and meeting bookings
- meeting creation/cancellation/end/extension
- APNs registration and badge reset
- realtime SSE refreshes
- network path monitoring
- offline UI state
- Widget/App Group synchronization
- Live Activity state synchronization back into the app

Before adding new app-wide state, check whether it belongs in `SessionStore` rather than creating an unrelated singleton.

### Networking and credentials

`Networking.swift` contains the shared networking stack and credential storage.

Important behavior:

- `APIClient.shared` is the main JSON API client.
- Primary API base URL is `https://sukavinagroup.net/api/`.
- GET/HEAD requests can retry selected transient network failures.
- A fallback host exists for retryable reads.
- Authenticated requests can refresh the session after HTTP 401.
- Access and refresh tokens are stored in Keychain.
- Biometric refresh credentials use a separate Keychain item protected by `SecAccessControl`.
- Cancellation errors are lifecycle behavior and must not be surfaced as ordinary network failures.

Do not log access tokens, refresh tokens, APNs tokens, biometric secrets, passwords, OTP values, or other credentials.

### Models and shared data structures

`PortalModels.swift` contains shared API/data models for:

- authentication/profile
- dashboard and attendance
- meeting rooms/bookings/details/invitees
- meal data and QR responses
- content/news parsing
- request/response payloads
- attendance widget bridge

Prefer extending existing models here when a model is shared across multiple views or services.

## UI ownership

### `AuthenticationViews.swift`

Owns authentication UI and related flows:

- sign in
- forgot password
- verification/registration support
- root signed-in/signed-out SwiftUI switching helpers

### `EmployeeViews.swift`

Contains the main employee portal UI and several major employee-facing features, including the meeting room schedule/timeline.

When changing meeting schedule rendering, inspect the complete flow in this file before editing isolated views.

Current meeting timeline behavior includes:

- event rail height represents the actual meeting start/end duration
- short-meeting labels are rendered separately from the rail
- short labels can be placed in left/right columns
- connector lines link labels back to their meeting rail
- label placement includes collision avoidance
- the current-time marker must remain visually above schedule content

Do not inflate a short meeting block just to fit text. Preserve time geometry and solve readability in the label/overlay layer.

### `RequestViews.swift`

Owns employee request features:

- request listing/filtering
- request creation
- request approval/rejection
- request cancellation
- attendance correction requests
- business trip fields
- leave/late/early/overtime/gate flows

`EmployeeRequestStore` handles request loading, caching, submit/cancel/decision behavior.

### `NotificationViews.swift`

Owns in-app notifications and meeting notification detail/control UI.

Meeting notification controls use `SessionStore.performMeetingControl(...)` rather than implementing duplicate endpoint logic in the view.

### `ProfileViews.swift`

Owns account settings, display preferences, biometrics, password changes, privacy/support/deletion information, and sign out.

### `MealViews.swift`

Owns employee meal QR generation and canteen scanning.

Camera access is used for canteen QR scanning. Keep permission messaging aligned with actual camera use.

### `DesignSystem.swift`

Contains app theme and shared visual helpers. Prefer reusing `AppTheme` and existing adaptive helpers instead of introducing ad-hoc colors and surfaces throughout the app.

## Meeting architecture

### Data flow

The expected schedule flow is:

```text
API
  ↓
APIClient
  ↓
SessionStore.refreshMeetingSchedule()
  ↓
meetingRooms / meetingBookings
  ↓
meeting schedule views in EmployeeViews.swift
```

`SessionStore.refreshMeetingSchedule(date:)`:

- restores cached schedule first
- fetches the selected day when online
- applies saved room ordering
- normalizes duplicate/anonymous bookings
- applies pending server-confirmed Live Activity meeting-end state
- saves refreshed schedule back to cache

### Meeting mutations

Use the existing server endpoints and `SessionStore` methods:

- create meeting: `POST me/meeting-bookings`
- cancel future meeting: `DELETE me/meeting-bookings/{id}`
- end active meeting: `POST me/meeting-bookings/{id}/end`
- extend active meeting: `POST me/meeting-bookings/{id}/extend`

The app intentionally keeps server-confirmed meeting end state locally until the schedule endpoint reflects the same end time, preventing stale refreshes from visually restoring the old duration.

Keep meeting end/extend behavior idempotent from the UI side where possible and guard against duplicate submissions.

## Live Activity architecture

Shared model:

- `MeetingLiveActivityAttributes.swift`

App-side lifecycle/push token management:

- `MeetingLiveActivityManager.swift`

Interactive intents used by the widget/Live Activity:

- `MeetingLiveActivityActionIntent.swift`

Live Activity and widget UI:

- `AttendanceWidget/AttendanceWidget.swift`

Flow:

```text
MeetingLiveActivityAttributes
        ↓
MeetingLiveActivityManager
        ↓
ActivityKit activity
        ↓
AttendanceWidget / Dynamic Island / Lock Screen
        ↑
MeetingLiveActivityActionIntent
```

Important behavior:

- Live Activity end/extend intents call existing API routes directly.
- The intent process cannot rely on the main app process being active.
- Shared meeting-end results are written through the App Group.
- A Darwin notification wakes an already-running app process to re-read shared meeting state.
- Per-activity ActivityKit push tokens are uploaded after an activity exists.
- `staleDate` does not end a Live Activity by itself.

When debugging Live Activity start timing, distinguish ordinary APNs notifications from ActivityKit push-to-start support. Do not assume a normal remote-notification callback can reliably start a Live Activity while the app is terminated.

## Widget architecture

`AttendanceWidget/AttendanceWidget.swift` contains both:

- attendance Home Screen widget
- meeting Live Activity / Dynamic Island configuration

Shared App Group:

```text
group.net.sukavinagroup.user
```

The main app and widget must continue using the same App Group. The code also handles resigned builds through `ALTAppGroups` lookup.

Attendance widget state and short-lived widget token are shared through the App Group. Keep app and widget payload formats compatible.

## Notifications and APNs

The app registers APNs tokens after authentication and syncs them to the backend.

Important rules:

- APNs token state is scoped to the current signed-in identity.
- Badge acknowledgement is synchronized separately from unread state.
- Opening Notifications can clear only the visual badge without marking every notification as read.
- Server APNs and local fallback notifications must not create obvious duplicate user-visible banners.

For meeting notification routing, preserve the existing notification-router flow and request/meeting detail lookup.

## Realtime refresh

The app consumes the public SSE event stream and coalesces event bursts.

Recognized event families include:

- attendance changes
- request changes
- meal changes
- meeting changes
- content changes

Meeting changes intentionally refresh with minimal delay so timeline changes are visible quickly. Other event groups use jitter to avoid synchronized API spikes across many devices.

Do not introduce a second competing realtime connection without a clear need.

## Caching and offline behavior

The app uses local caches to keep important screens usable during temporary network loss.

Examples:

- session/profile cache
- dashboard cache
- attendance month cache
- today menu cache
- request notification cache
- employee request cache
- meeting room catalog and day schedule cache

Network loss should not automatically destroy a valid locally restored session.

When adding cache data:

- namespace user-specific data by employee identity
- define an appropriate TTL or invalidation rule
- do not cache secrets in `UserDefaults`
- keep server-confirmed mutations authoritative

## iOS compatibility constraints

The project intentionally contains protections for iOS 17 compatibility when built with newer Xcode versions.

Important constraints:

- Avoid introducing iOS 26-only SwiftUI APIs merely for appearance improvements.
- Do not introduce a strong runtime dependency on `SwiftUICore.framework` for iOS 17 builds.
- The Xcode project includes a Release build phase that verifies legacy iOS compatibility and fails when `SwiftUICore.framework` is strongly linked.
- Existing design helpers intentionally avoid newer Liquid Glass APIs in the app binary.

If using a newer SDK-only API, check both compile-time availability and whether simply referencing it can alter binary linkage.

## Concurrency and UI state

Most `SessionStore` operations are `@MainActor` and mutate published UI state there.

Guidelines:

- respect task cancellation from SwiftUI `.task`, `.refreshable`, and view replacement
- do not convert normal cancellation into a user-facing error
- avoid launching duplicate refresh tasks for the same state when an existing coordinator/task already handles it
- guard mutation actions against rapid repeated taps
- keep expensive or potentially blocking Security.framework work off the UI actor when the current implementation already does so

## Date/time conventions

Business dates and meeting-day calculations use the Ho Chi Minh City timezone in important paths:

```text
Asia/Ho_Chi_Minh
```

API timestamps are ISO 8601 and may contain fractional seconds.

When parsing server dates, support both fractional and non-fractional ISO 8601 where the surrounding code does so.

Do not mix device-local day boundaries into meeting/attendance logic without checking the existing timezone convention.

## API and model robustness

Some server responses have evolved over time. Existing decoders intentionally tolerate selected missing fields, for example older meeting-room payloads without `imageUrl`.

When changing decoders:

- prefer `decodeIfPresent` with a sensible backward-compatible default for optional/evolving server fields
- do not silently loosen required identity/security fields
- preserve exact request coding keys where the backend contract depends on them
- log decode failures through existing diagnostics rather than swallowing all failures without context

## Security rules

- Never commit credentials, passwords, OTPs, API tokens, APNs tokens, private keys, provisioning secrets, or server login credentials.
- Do not print secrets to GitHub Actions logs.
- This repository is public; assume workflow logs and committed files are public information.
- Do not add broad `sudo`, remote shell, or arbitrary filesystem-exfiltration workflows.
- Do not weaken Keychain accessibility or biometric access-control protections without a specific product requirement.
- Keep account separation intact when caching or restoring user-scoped data.

## GitHub Actions / self-hosted runner safety

A self-hosted runner may be connected to infrastructure used by the project. Treat it as sensitive infrastructure.

Rules:

- Never run untrusted fork/PR code on a privileged self-hosted runner.
- Avoid workflows that dump server filesystem contents into public logs.
- Prefer narrow, purpose-built checks over arbitrary shell access.
- Do not grant `NOPASSWD: ALL` to runner users.
- If elevated access is required, use the narrowest possible command/path allowlist.

## Editing rules

Before modifying code:

1. Identify the owning layer/file.
2. Trace the current data flow end to end.
3. Check whether the behavior is shared with Widget/Live Activity/AppIntent code.
4. Preserve API contracts unless the task explicitly includes backend changes.
5. Avoid duplicate state owners or duplicate networking implementations.

For bug fixes, document the root cause in code comments only when the reason is non-obvious and likely to regress. Avoid comments that merely restate the code.

Prefer focused changes. Do not reformat unrelated large files while fixing a small issue.

## Validation expectations

For source changes, validate as far as the environment allows.

Preferred checks:

- compile the affected iOS target with Xcode when a macOS/Xcode runner is available
- compile `App` when shared model/network/session code changes
- compile `AttendanceWidget` when WidgetKit, ActivityKit, AppIntent, shared Live Activity attributes, entitlements, or App Group behavior changes
- inspect Release linkage when changing SwiftUI/SDK compatibility-sensitive code

Static source checks are not equivalent to an Xcode build. Never report a static check as a successful iOS compile.

When no macOS/Xcode environment is available, state that limitation explicitly.

## High-risk cross-file changes

Treat these as cross-target or architecture-sensitive:

- `MeetingLiveActivityAttributes.swift`
- `MeetingLiveActivityActionIntent.swift`
- App Group identifiers
- entitlements
- `Info.plist` Live Activity/background configuration
- Keychain service/account identifiers
- authentication refresh behavior
- APNs registration endpoints
- Xcode target membership
- deployment target or linker flags

When one of these changes, inspect all consumers before committing.

## Current engineering conventions

- Swift-only native iOS implementation.
- SwiftUI is the primary UI framework, with UIKit bridges where required for lifecycle, camera, text editing, scrolling, or compatibility.
- `SessionStore` remains the primary app state/business coordinator.
- `APIClient.shared` remains the shared API path for normal app requests.
- App Group state is used only where cross-process sharing is required.
- Meeting timeline geometry must remain faithful to actual meeting times.
- User-facing errors should use existing localized error/presentation paths rather than ad-hoc debug text.
- Keep Vietnamese user-facing copy consistent with surrounding screens.

## When debugging a regression

Start with the relevant flow, not only the visible view.

Examples:

### Meeting schedule issue

```text
PortalModels → APIClient → SessionStore.refreshMeetingSchedule → EmployeeViews timeline
```

### Meeting end/extend issue

```text
Notification/Live Activity control
→ SessionStore.performMeetingControl or MeetingLiveActivityActionIntent
→ server endpoint
→ shared/pending meeting state
→ schedule refresh
```

### Live Activity issue

```text
APNs payload / app callback
→ MeetingLiveActivityManager
→ ActivityKit activity
→ push token upload
→ AttendanceWidget Live Activity UI
→ AppIntent actions / server update
```

### Session/login issue

```text
AuthenticationViews
→ SessionStore.signIn / restore / refreshSession
→ APIClient
→ KeychainStore / BiometricKeychain
→ root state transition
```

### Notification badge issue

```text
APNs/server notifications
→ SessionStore notification counts
→ acknowledgement state
→ application icon badge
→ NotificationsView
```

Use these paths as the default starting point before introducing new abstractions.
