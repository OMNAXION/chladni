# Chladni fork notice

Chladni is a modified fork of **Spotless by fjenn**, distributed under **GPL-3.0**
(the upstream source identifies its license as GPL-3.0-or-later).

- Upstream: https://github.com/fjenn/spotless
- Upstream commit: `60d6aec61599859e43e42846d0eca32095a45e05`
- The upstream URL is provided for attribution, not as a Chladni download or support destination.
- `LICENSE`, `THIRD-PARTY-NOTICES.md`, existing copyright notices and author credits are retained.
  Spotless itself builds on Limusic by SimoHypers and contributors; existing acknowledgements remain.

## Kinds of changes

- T1: reproducible source inventory (`scripts/fork/inventory.sh`, `docs/FORK-INVENTORY.md`).
- T2: Chladni display names, native menus, notification/diagnostic/startup text, UI/localization,
  export names and player labels; desktop identifier `studio.chladni.desktop`; iPhone identifier
  `studio.chladni.ios` and XcodeGen prefix `studio.chladni`.
- T2: `chladni://` URL registration, routing, sharing and device-pairing QR generation/parsing
  across Tauri, Rust, TypeScript and Swift. The existing `encore://` compatibility alias remains;
  the `spotless://` scheme is no longer registered or accepted as the app scheme.
- T2: upstream app website/help/issue/source destinations removed from app entries, with TODOs
  for owner-provided destinations. No replacement URL was invented. Attribution and third-party
  license/service links remain. Podcast client labels no longer advertise the upstream repository.
- T2: README identity and provenance updated; upstream download and badge links removed.
- T3: automatic updates and upstream updater configuration disabled; that work is preserved.

Cargo package/crate names, Xcode targets/schemes/Swift modules, `PRODUCT_NAME = Encore`, internal
`encore.sqlite` filenames and iOS `Encore` storage subdirectories remain. Signing, notarization,
workflows, lockfiles and artwork are outside this ticket. This notice asserts no release,
signing, app-store, trademark or other public approval.

## Moving existing upstream data

Chladni resolves its desktop data root through Tauri's configured identifier. On macOS it is
`~/Library/Application Support/studio.chladni.desktop`, rather than
`~/Library/Application Support/app.spotless.desktop`.

There is **no automatic Spotless-to-Chladni folder import** in this ticket. The unchanged
`src-tauri/src/migrate.rs` is legacy Encore import logic (`app.encore.desktop`); its historical
Spotless strings and tests must not be interpreted as the fork's current destination.

For a user who wants to bring an upstream Spotless profile into a clean Chladni profile:

1. Quit Spotless, Chladni and any Encore instance, then back up all source folders. Do not merge
   or overwrite an existing Chladni profile; retain it separately before importing.
2. Copy/rename the existing `app.spotless.desktop` directory to `studio.chladni.desktop` under
   each of these macOS parents, if present:
   - `~/Library/Application Support/` — the **whole directory**, including `encore.sqlite`,
     any SQLite `-wal`/`-shm` sidecars, downloads, covers, logs, local audio caches and other files;
   - `~/Library/Caches/` and `~/Library/Logs/`;
   - `~/Library/WebKit/` and `~/Library/HTTPStorages/` — webview preferences/localStorage and caches.
3. Imported SQLite TEXT fields can contain absolute paths into the old Application Support
   directory (including generated Made for you covers). Those old path prefixes must be changed
   to the new prefix in the **copied** `encore.sqlite` before relying on those files. The existing
   `migrate::rewrite_paths` helper describes this operation, but only runs automatically for a
   folder moved by the legacy Encore importer. A manual Spotless folder copy does not trigger it.
   User-selected external music/download folders keep their original paths. Imported cached Home
   covers in localStorage are repaired by `ui/src/lib/discover/data.ts`.
4. Start Chladni and verify library, downloads and preferences against the backup. OS-specific
   WebKit storage restoration has not been tested here. Original backups should be retained.
5. Sign in to YouTube again if needed: new credentials use `studio.chladni.desktop` on Mac and
   `studio.chladni.ios` on iPhone. Copying folders does not transfer upstream Keychain credentials;
   the older Encore-only credential fallback remains unchanged. No keychain access group or
   signing permission was expanded.

On iPhone, the new bundle ID receives a separate app container. Use the upstream app's library
export and Chladni's import for supported library data; downloads, preferences and credentials do
not automatically cross containers. The target/module/app executable and internal storage folder
are still named Encore. No device migration or signed iOS build was performed in this ticket.

## Intentionally retained old identity

`docs/FORK-INVENTORY.md` is the complete recursive path/count index, including historical docs,
site/build/release scripts and workflows outside the app-identity scope. In the requested
`src-tauri`, `ui/src`, `ios` identifier/upstream-host scan, the retained matches are exactly:

- `src-tauri/src/migrate.rs`: historical `app.spotless.desktop` documentation and test destination;
- `ui/src/lib/discover/data.ts`: old `app.spotless.desktop` as a legacy-import source prefix only.

Other old-name tokens are deliberate compatibility/internal values: `spotless.discography`,
`spotless.radioSaves`, `spotless.searchPick`, `spotless:devices`; installer suppression/environment keys and its temporary
`.spotless-new` suffix; Swift dispatch queue labels; the `_spotless-sync._tcp` Bonjour protocol,
`spotless-*.local` discovery hostname and `spotless-sync` cryptographic/protocol labels; test-only
temporary names, non-executing historical/design comments, and mark/asset symbols
`SpotlessMark`, `SpotlessGlyph`, `SPOTLESS_MARK`. They do not define the visible product name.
Existing Encore and Limusic author credits, compatibility schemes, package names and storage
names are retained. The sync relay at `https://opena.tech/api/sync` in
`crates/core/src/sync/relay.rs` is an existing backend service, not a website/help/privacy/support
link; it was not reconfigured or contacted. This ticket does not detach all upstream services.

## Brand artwork

Replaced with original Chladni artwork (a real Chladni-plate nodal pattern, u = cos(2*pi*x)cos(5*pi*y) - cos(5*pi*x)cos(2*pi*y) = 0, generated by script):

- Mac app icons: all of `src-tauri/icons/*`, including `tray-template.png`.
- iPhone: `AppIcon-1024.png`, `LaunchMark2@3x.png` and `spotless-glyph.svg` (the file name is kept; the picture is new).
- In-app mark `ui/src/lib/kit/Logo.svelte`, `ui/src/lib/assets/favicon.svg` and the DMG installer icon `scripts/macos/installer-icon.{icns,png}`.
- Removed: upstream's README screenshots (`docs/readme/`) and its marketing website (`site/`).

Still upstream's, not yet replaced (verify before any wider distribution):

- `assets/brand/spotless.svg` (old master mark, unused by the Chladni build).
- Procedural marks in `ui/src/lib/devmock/smart2.ts`, `crates/core/src/smart/mfy.rs` and Swift `SpotlessMark` (generated cover art for "Made for you" mixes).
- Upstream iOS screenshot baselines under `ios/Encore/EncoreTests/__Snapshots__/`.
