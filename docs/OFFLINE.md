# Last-loaded read cache

Tasks (separate snapshots for each filter), Groceries (including preferences and
suggestions), Inventory (including unit options), and Meals use online-first reads.
Only a complete, successfully decoded list load replaces its snapshot. Meals'
unavailable/unconfigured status does not replace saved recipes with an empty list.

When a connection is unavailable, lost, or times out, a saved snapshot can be shown
with **Saved data - may be out of date**, its last-loaded date and time, and a
refresh instruction. There is no automatic age cutoff: the displayed timestamp
is the freshness indicator. A successful refresh removes the stale banner.
Cached empty lists are valid only if an earlier online load actually returned
an empty list. Missing or corrupt cache data remains an explicit error.

Stale list actions are disabled; there is no offline write queue, optimistic
success, cached recipe detail, photo download cache, or background sync.
HTTP errors (including 401/403 and 5xx), invalid JSON, TLS failures, and cancellation
do not fall back to saved data. Authentication rejection is handled centrally by
the existing generation-guarded sign-out callback.

Snapshots are Codable JSON in the app's system Caches directory, with complete
file protection and atomic writes. iOS can purge these files. Keys hash the signed-in
user ID and the exact API URL built by the shared request builder, including server
origin/base path, endpoint, and query. Request headers, passwords, and tokens are
never cached. Credentials remain in the Keychain. The app requires a restored
server-matching authenticated identity before using snapshots.

Sign-out, server changes, and successful login clear all read snapshots.
Every successful non-GET request (including imports, purchase, and photo changes)
also invalidates snapshots; only a subsequent successful list GET repopulates them.
In-flight reads cannot repopulate storage after these invalidations. A failed disk
clear disables cache reads and writes for that session and surfaces an error.
Changing accounts cannot reuse another user's key. Lists refresh on revisit as
well as through pull-to-refresh; any retained stale screen still needs a refresh
before enabling changes.
