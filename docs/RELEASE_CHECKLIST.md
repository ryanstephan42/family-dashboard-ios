# Release acceptance

These are **checks to perform**, not a claim of a completed device/live-server
run. No real server, Apple account, or physical iPhone is available in the Linux
development environment. Record the actual device, iOS version, server API
version, app commit, outcome and any blockers privately when executing them;
do not put credentials or household content in public CI logs/issues.

## Automated gate

- [ ] The integrated commit passes macOS **iOS CI**: XcodeGen, simulator build,
  unit/service tests and fresh-install onboarding UI smoke.
- [ ] Download `ios-test-results` if a failure needs investigation.

The UI smoke launches the real app without credentials or an auth bypass.
It covers Connect, disabled empty input, invalid-address validation and the
absence of authenticated tabs. Stubbed network tests exercise feature contracts
and failures, not a running server or camera. The generated Xcode project and
test result bundles must not be committed.

## Install and connect on a physical iPhone

- [ ] Follow the README on a Mac with a supported Xcode/device SDK; use your
  Personal Team and a unique bundle ID. Confirm Developer Mode and trust.
- [ ] Install and open a clean app. Enter your private HTTPS server address
  and sign in. Check an incompatible-server error and an incorrect password.
- [ ] Relaunch: the saved server and account restore. Sign out and sign in;
  Change server returns to Connect. Confirm another household account cannot
  see the previous account's cached lists.
- [ ] Revoke/reject a JWT on the test server: a 401/403 returns to sign-in,
  including after a photo upload. Do not publish the token.
- [ ] Reinstall/re-sign after free provisioning expires (normally seven days).
  This build must not need push, App Groups or a paid entitlement.

## Native shell and household flows

- [ ] Exactly five tabs fit without a system overflow menu. Tasks, Groceries,
  Inventory and Meals show their own correct titles and toolbars.
- [ ] More opens Calendar, Settings and Scan Receipt; each closes back to More.
  No duplicate navigation bars or trapped sheets. Sign out from Settings
  dismisses authenticated content.
- [ ] Tasks: create with assignee/repeat options, edit, check steps, complete,
  filter mine/family/chores/done and delete. Check server/webapp agrees.
- [ ] Groceries: bulk add, choose a suggestion, edit, purchase, clear completed
  and delete. Revisit Inventory and confirm purchased stock appears without
  restarting the app.
- [ ] Inventory: search/filter, add/edit, adjust quantity, confirm zero/delete,
  verify low stock/expiration. Revisit Meals after a stock change and confirm
  ingredient availability updates.
- [ ] Meals: check configured/online, unconfigured and offline states. Open a
  recipe, link an ingredient to inventory and confirm availability after revisit.
- [ ] Calendar: load the configured Nextcloud share; refresh, close/reopen and
  open externally. Check unconfigured and unavailable states. Event editing
  occurs in Nextcloud, not in a native client editor.
- [ ] Receipt: choose a JPEG/PNG photo or file, scan, review/edit/unselect rows,
  select storage, import once and confirm success. Close and revisit Inventory
  and Meals: imported stock and availability refresh. Check server rejection,
  cancellation, an unreadable image and prevention of duplicate taps.

## Permissions, resilience and accessibility

- [ ] Take an inventory and receipt photo on the phone; deny camera permission
  first and confirm a useful error plus image-picker/manual alternatives.
- [ ] On a supported phone, scan a known/unknown barcode; confirm lookup/edit
  before saving. Verify unsupported-device messaging without a crash.
- [ ] Choose an inventory photo; upload, replace and remove it, then reopen.
  Check authenticated uploads and `/uploads` origin routing through your proxy.
- [ ] Load lists, disconnect networking, reopen tabs and inspect last-loaded
  data/staleness messaging; mutations must not pretend to succeed offline.
  Reconnect and pull to refresh. Confirm logout/change server clears scoped data.
- [ ] Check empty lists, slow responses and server error messages with Retry.
- [ ] Check large Dynamic Type, dark mode, VoiceOver control names and scrolling
  on a small iPhone. Ensure Close/Save/Cancel remain reachable with the keyboard.

## Distribution and privacy gate

- [ ] Verify camera explanation, receipt cloud-processing disclosure, TLS and
  administrator/provider retention policy before uploading personal images.
- [ ] Confirm no secrets, real domains, signing files or personal fixtures are
  present in the public diff. Do not attach real receipts to a public issue.
- [ ] For paid distribution later, configure App Store Connect/TestFlight and
  complete Apple's current privacy/distribution requirements separately.
  Widgets and push remain future work, not release promises.
