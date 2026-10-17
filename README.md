# Family Board for iPhone

Native iPhone client in `ios/`. It talks to the server only through the
HTTPS `/api` (see [API.md](docs/API.md)). The goal is native SwiftUI parity with
the family-task-board webapp; Chat and Budget are out of scope for v1.
Requires iOS 17 or newer. No third-party app dependencies.

## What's available
Five tabs keep the iPhone tab bar free of overflow: **Tasks**, **Groceries**,
**Inventory**, **Meals**, and **More**.

- Tasks: create/edit/delete, steps, repeating tasks, assignees and filters.
- Groceries: grouped lists, bulk add, suggestions, edit/delete and purchase.
- Inventory: search and filters, stock adjustments, low stock/expiration,
  add/edit/delete, item photos and supported-device barcode lookup.
- Meals: Mealie status, recipes, ingredient availability and inventory linking.
- More: shared Nextcloud calendar, receipt scanning into inventory, and Settings.

The calendar is a read-only shared Nextcloud view, not a native event editor.
Add or edit events in Nextcloud. Meals require server-side Mealie configuration;
receipt recognition depends on the server's OCR/AI configuration.

## Build on a Mac (free Apple ID)
1. Install Xcode 26 or newer (needed to run on iOS 26.x; the Mac must run a macOS version that supports it) and [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
2. `cd ios && xcodegen` to generate `FamilyBoard.xcodeproj` (not committed).
3. Open it in Xcode, sign in with your own Apple ID under Settings > Accounts,
   select the FamilyBoard target > Signing & Capabilities, pick your Personal
   Team and change the bundle ID (`com.example.familyboard`) to something unique.
   To preserve signing settings across project regeneration, set
   `DEVELOPMENT_TEAM` and `PRODUCT_BUNDLE_IDENTIFIER` in `ios/project.yml` locally.
   Do not publish personal signing details or provisioning profiles.
4. Plug in and unlock the phone, trust the Mac, enable Developer Mode under
   Settings > Privacy & Security when prompted, select the phone in Xcode,
   and press Run. If prompted, trust the developer under Settings > General >
   VPN & Device Management. No paid capabilities are required.
5. Free-account builds expire after 7 days; re-run from Xcode.
6. Enter your own server address (for example `family.example.com`), connect,
   and sign in using an existing household account. The app checks API
   compatibility before sign-in. Registration/server administration stay on
   the server; no account or credentials are bundled.

After a paid-program upgrade, change the signing team (and optionally bundle
ID) to distribute through TestFlight. Widgets, App Groups, and push are not
implemented or required by this version.

## CI and unit tests
The **iOS CI** GitHub Actions workflow generates the project, builds the app
and runs unit tests and an onboarding UI smoke on an available iPhone simulator
with signing disabled.
It runs on pushes and pull requests and can also be started manually.
The simulator's `.xcresult` bundle is uploaded as `ios-test-results`.

On a Mac, generate the project as above, then run:
```sh
cd ios
xcodebuild test -project FamilyBoard.xcodeproj -scheme FamilyBoard \
  -destination 'platform=iOS Simulator,name=iPhone 16' CODE_SIGNING_ALLOWED=NO
```
Choose an installed simulator name from `xcrun simctl list devices available`.
Service tests use a stubbed URL session; no real server or credentials are required.
The UI smoke uses the real app's fresh-install Connect screen, rejects an invalid
address without networking, and checks that authenticated tabs remain unavailable.
Run it on a clean simulator installation; it does not erase a user's saved
credentials or introduce a production authentication bypass. It is not an
authenticated feature/device end-to-end test.

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
loading and retry views. Feature roots own their navigation, except Inventory
which the shell wraps. More presents Calendar and Settings as separate sheets
with their existing navigation roots; receipt scanning gets its own sheet stack.

## Permissions and privacy
Use a trusted HTTPS server with a valid certificate. Login credentials and
requests go to the server you enter; session credentials are kept in the iOS
Keychain. Never commit real server URLs, passwords, tokens, receipt images, or
household data to this public repository.

Camera permission is requested only when taking a photo or scanning a barcode.
Camera denial does not prevent manual inventory entry or selecting an image.
The system Photos picker shares only the selected image, not the entire library;
the file picker accepts JPEG/PNG receipts. Barcode scanning needs compatible
physical hardware and is not supported by the simulator.

Inventory photos upload when saved. Receipt images upload only after tapping
**Scan Receipt**; the server may forward them to a cloud AI provider. Review
items before importing and avoid sensitive receipts unless you accept the
server/provider's data handling. The shared calendar loads Nextcloud content
in an ephemeral web view; opening Nextcloud leaves the app. Ask your server
administrator about server-side storage, logs, backups, providers and deletion.
This client does not implement analytics, push notifications or background sync.

## Server notes
- `JWT_SECRET` must be set; the server no longer falls back to a default.
- `GET /api/users` now requires a token.
- If the API is behind Cloudflare Access, add a Bypass policy for the path
  `/api/*` (and `/uploads/*` for photos). Every `/api` route except login,
  register and config requires a JWT, so this is safe. Leave the web UI
  itself protected.

## Release readiness
See [the release checklist](docs/RELEASE_CHECKLIST.md) for simulator coverage and
the physical-device/live-server acceptance checks still required before release.
CI success does not verify a real household server, device permissions, signing,
Nextcloud, Mealie, barcode recognition, or receipt OCR accuracy.
