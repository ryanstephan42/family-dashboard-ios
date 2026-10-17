# iOS app (SwiftUI)

Native iPhone client in `ios/`. It talks to the server only through the
HTTPS `/api` (see [API.md](docs/API.md)). The goal is native SwiftUI parity with
the family-task-board webapp; Chat and Budget are out of scope for v1.

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

## CI and unit tests
The **iOS CI** GitHub Actions workflow generates the project, builds the app
and runs unit tests on an available iPhone simulator with signing disabled.
It runs on pushes and pull requests and can also be started manually.
The simulator's `.xcresult` bundle is uploaded as `ios-test-results`.

On a Mac, generate the project as above, then run:
```sh
cd ios
xcodebuild test -project FamilyBoard.xcodeproj -scheme FamilyBoard \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```
Choose an installed simulator name from `xcrun simctl list devices available`.
Tests use a stubbed URL session; no real server or credentials are required.

## Shared app foundation
Use `session.client` for authenticated requests: HTTP 401/403 clears the saved
session and returns to sign-in. Expired responses from an older sign-in cannot
clear a newer session. The token, signed-in user and server address are saved
together in the Keychain; legacy token-only installs require signing in again.
Keychain failures are shown instead of treating an unsuccessful save as a login.

`APIClient.request` decodes JSON; `send` handles empty responses. Both accept
`query: [URLQueryItem]`; use `APIClient.path("inventory", id, "photo")` to encode
dynamic path components. `upload` decodes multipart responses and `sendUpload`
returns raw data. Both use the same authenticated transport and error handling.
`LoadingStateView(title:)` and `ErrorStateView(message:retry:)` are shared native
loading and retry views. Each tab owns its own `NavigationStack`.

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
