# iOS app (SwiftUI)

Native iPhone client in `ios/`. It talks to the server only through the
HTTPS `/api` (see [API.md](API.md)). Chat and Budget are out of scope for v1.

## Build on a Mac (free Apple ID)
1. Install Xcode 26 or newer (needed to run on iOS 26.x; the Mac must run a macOS version that supports it) and [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
2. `cd ios && xcodegen` to generate `FamilyBoard.xcodeproj` (not committed).
3. Open it in Xcode, sign in with your own Apple ID under Settings > Accounts,
   select the FamilyBoard target > Signing & Capabilities, pick your Personal
   Team and change the bundle ID (`com.example.familyboard`) to something unique.
4. Plug in the phone, enable Developer Mode, press Run.
5. Free-account builds expire after 7 days; re-run from Xcode.

When you upgrade to the paid program, only the signing team (and optionally
bundle ID) changes; then use TestFlight, widgets, and push.

## Server notes
- `JWT_SECRET` must be set; the server no longer falls back to a default.
- `GET /api/users` now requires a token.
- If the API is behind Cloudflare Access, add a Bypass policy for the path
  `/api/*` (and `/uploads/*` for photos). Every `/api` route except login,
  register and config requires a JWT, so this is safe. Leave the web UI
  itself protected.

## Status
Scaffold: server setup, login (token in Keychain), compatibility check, task
list. Next: task create/edit, grocery, calendar, inventory, meals, receipt scan.
