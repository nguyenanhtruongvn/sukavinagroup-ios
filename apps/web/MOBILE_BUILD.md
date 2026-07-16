# Sukavina Portal for iOS

## Application identity

- App name: Sukavina Portal
- Bundle ID: net.sukavinagroup.portal
- Production URL: https://sukavinagroup.net

## Build on macOS

1. Install Xcode 26 or newer and CocoaPods.
2. From the repository root, run `pnpm install`.
3. Run `pnpm --filter @org/web mobile:sync`.
4. Run `pnpm --filter @org/web mobile:open`.
5. In Xcode, select the Apple development team and a connected iPhone.
6. Use Product > Archive, then export an Ad Hoc or Development IPA.

An installable IPA requires Apple code signing. The generated Xcode project can
run in the iOS Simulator without a paid distribution certificate.
