# Chladni

A music app for Mac and iPhone, with shared Rust playback and library code.

Based on Spotless by [fjenn](https://github.com/fjenn/spotless), licensed under GPL-3.0-or-later.
This is a modified fork; see [the fork notice](docs/FORK-NOTICE.md) for provenance, changes,
data migration and retained upstream artwork. No fork downloads are published here.

<!-- TODO: Add owner-provided download, website, support, privacy and bug-report links. -->

## Install on Mac

The Mac app is **not notarized** (no Apple Developer ID), so macOS will warn the first time:

1. Download `Chladni.dmg` from the Releases page, open it and drag Chladni to Applications.
2. Open Chladni once. macOS says it cannot verify the app: click **Done**.
3. Open **System Settings > Privacy & Security**, scroll to the Chladni message and click **Open Anyway**, then confirm.
   (Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Chladni.app`.)

The release is ad-hoc signed and built for Apple silicon (arm64). There is no auto-update; download new releases yourself.

## Install on iPhone

Build the iPhone app locally with your own Apple ID:

- **Build it** with Xcode and your own Apple ID, following [Build from source › iPhone](#iphone)
  (change the bundle ID and team to your own). An AI coding agent can do this from this README.

## What it does

Chladni plays music, podcasts and audiobooks. The Mac app (Tauri + Svelte) and the iPhone app
(SwiftUI) share one Rust core, so search, recommendations, the library and downloads work the
same way on both.

#### Music
- Search and browse songs, albums, artists, playlists, charts, moods and new releases.
- Radio from any song, smart shuffle, and switch a song to its music video when there is one.
- Six-band equalizer with presets, speed and pitch, reverb, crossfade and a sleep timer.
- Downloads for offline listening, with an offline mode.

#### Podcasts
- Search, follow and get a feed of new episodes. Video podcasts too.
- Chapters, playback speed and downloads.
- Optional skipping of sponsor segments ([SponsorBlock](https://sponsor.ajay.app)).
- Import and export your subscriptions as OPML.

#### Audiobooks
- Free public-domain audiobooks from [LibriVox](https://librivox.org) and the
  [Internet Archive](https://archive.org), with chapters and resume.

#### Lyrics
- Synced line by line where available, with romanization for Japanese, Korean and Chinese.
- Song credits and artist info next to the player.

#### Your library, and bring your own
- Playlists, folders, pins, liked songs, followed artists and shows, all stored on your device.
- Import playlists from a link, or from the data export of another streaming service
  (for example a Spotify account data export).
- Listening stats, kept on your device.

#### Made for you
- Personal mixes, a weekly discovery list and recommended songs for your playlists, worked out
  on your device from what you play.

#### Privacy
- No account, no analytics, no telemetry, no crash reporting. More [below](#privacy).

#### Mac extras
- Menu bar controls and a mini player.
- Media keys, global shortcuts and a full set of keyboard shortcuts.
- Automatic updates are disabled in this fork.

#### iPhone extras
- Lock Screen, Control Center and Dynamic Island playback controls.
- Picture in Picture for music videos and video podcasts.

## How it works

Chladni gets its music catalogue from public sources, mainly YouTube Music, and plays the audio
itself with [mpv](https://mpv.io). There is no web player inside, so there are no audio, video or
banner ads. Podcasts come straight from their publishers' feeds, audiobooks from LibriVox and the
Internet Archive, and lyrics from services such as [LRCLIB](https://lrclib.net).

There is no Chladni server. Your library, playlists, history, mixes and downloads are built and
kept on your device. If you want your existing YouTube Music likes and playlists, you can sign in
with your YouTube account, and only then.

## Privacy

- **No account, no analytics, no telemetry, no crash reporting.** The developer runs no server and
  receives nothing from the app.
- **Your library, playlists, history, stats and downloads stay on your device.**
- **The app talks to third-party services directly** to work: YouTube for music and videos, and
  lyrics, podcast, audiobook and metadata services (for example LRCLIB, Apple's podcast directory,
  Deezer's public search, MusicBrainz, SponsorBlock, the Internet Archive). They receive what a
  request needs, such as a search term or a song title and artist, plus your IP address, like any
  website would.
- **YouTube sign-in is optional.** The sign-in cookie is kept in the system Keychain and is sent
  only to YouTube/Google. While you are signed in, songs you play are added to your YouTube
  history unless you turn that off in Settings or use a private session.

<!-- TODO: Link the owner-provided privacy policy when available. -->

## Build from source

### Mac

You need macOS with Xcode's command line tools, [Rust](https://rustup.rs) (stable),
Node.js 20 or later with [pnpm](https://pnpm.io), and libmpv from Homebrew for development.

```bash
brew install mpv
cargo install tauri-cli --locked          # or use ui/node_modules/.bin/tauri after pnpm install
(cd ui && pnpm install)
export LIBRARY_PATH="$(brew --prefix)/lib:$LIBRARY_PATH"
cargo tauri dev                           # run with hot reload
scripts/build-mac.sh --release            # a Chladni.app that uses Homebrew's libmpv
```

For a self-contained app and DMG that runs on other Macs, use `scripts/release-mac.sh`. It bundles
libmpv and FFmpeg from a pinned, signature-checked IINA release, builds a universal binary by
default, and signs ad hoc unless you set `SIGN_IDENTITY` (and `NOTARY_PROFILE` to notarize). See
the comments at the top of the script and [docs/BUILD-PLATFORMS.md](docs/BUILD-PLATFORMS.md).

### iPhone

You need a recent Xcode, [XcodeGen](https://github.com/yonaskolb/XcodeGen) and the iOS Rust
targets.

```bash
brew install xcodegen
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
scripts/build-ios-core.sh                 # the shared core as an xcframework (--release for speed)
cd ios/Encore && xcodegen generate && open Encore.xcodeproj
```

In Xcode, pick your own team under Signing & Capabilities, then run the `Encore` scheme (the
project's internal name; the app is called Chladni). Tests: `SIM=<simulator udid> ios/Encore/scripts/test.sh`.

### Tests

```bash
export LIBRARY_PATH="$(brew --prefix)/lib:$LIBRARY_PATH"
cargo test -p limusic-app --lib
cd ui && pnpm check
```

More in [CONTRIBUTING.md](CONTRIBUTING.md).

## FAQ

<details>
<summary><b>Is it really free?</b></summary>
<br>
Yes. There is no paid tier, no subscription and nothing to unlock. Chladni is open-source
software under the GPL, and it has no servers to pay for: the app runs on your device and fetches
what you play directly from the source.
</details>

<details>
<summary><b>Why is there no account?</b></summary>
<br>
Because nothing needs one. Your library, playlists and history live on your device, and there is
no Chladni server to sign in to. The only sign-in is the optional one to YouTube, for bringing in
your existing YouTube Music library.
</details>

<details>
<summary><b>Is it legal?</b></summary>
<br>
Chladni is an independent open-source app. It does not host or redistribute any music; it plays
what YouTube and the other services serve to any other client. It is not affiliated with,
endorsed by or connected to Spotify, YouTube, Google or any other company whose services it talks
to. Whether and how you use it is up to you, in line with the laws and terms that apply where you
live.
</details>

<details>
<summary><b>Does it work on Windows, Linux or Android?</b></summary>
<br>
Not as a supported release. The Mac and iPhone apps are what we build and test. The upstream
project, <a href="https://github.com/SimoHypers/limusic">Limusic</a>, has Windows and Linux builds.
</details>

## Credits

Spotless by fjenn is a fork of [**Limusic**](https://github.com/SimoHypers/limusic) by SimoHypers and
contributors (GPL-3.0), which in turn started from the playback engine of
[Metrolist](https://github.com/mostafaalagamy/Metrolist). Thank you.

It also builds on:

- [Tauri](https://tauri.app) and [Svelte](https://svelte.dev) for the Mac app
- [mpv](https://mpv.io) / libmpv and [FFmpeg](https://ffmpeg.org) for playback; the Mac release
  bundles the libraries from [IINA](https://iina.io), and the iPhone app uses
  [MPVKit](https://github.com/mpvkit/MPVKit)
- [RustyPipe](https://codeberg.org/ThetaDev/rustypipe) and its BotGuard helper
- [UniFFI](https://github.com/mozilla/uniffi-rs) for the Rust core on iOS
- [LRCLIB](https://lrclib.net) and other lyrics providers, [SponsorBlock](https://sponsor.ajay.app),
  [LibriVox](https://librivox.org) and the [Internet Archive](https://archive.org)
- [pypinyin](https://github.com/mozillazg/python-pinyin) data for Mandarin romanization
- [Figtree](https://github.com/erikdkennedy/figtree) for the type

Third-party licences are listed in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

## License

Chladni is free software under the [GNU General Public License v3.0 or later](LICENSE).
All product names and trademarks belong to their owners.
