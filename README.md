# Link Vault

A private link collector for Android and iOS, built with Flutter.

- Share a link to the app from any other app. **No PIN is needed to save**,
  and a saved link can't be read back until you unlock the app.
- The page title that the sharing app sends along (Chrome, YouTube and
  others on Android), or the words around the link, is kept as the link's
  title. No network is used; titles can be edited and are searchable.
- The app always opens on the PIN screen (6 digits).
- Links are grouped by website (`m.youtube.com`, `youtu.be` → `youtube.com`;
  `news.bbc.co.uk` → `bbc.co.uk`).
- Tags: type free-text tags or pick from your managed tag list. A link can
  have any number of tags. Filters require all selected tags to match.
- Sort by date added, newest or oldest first. Search across links, tags and notes.
- Duplicate checks:
  - **Exact duplicate**: same content after cleanup. Tracking parameters,
    `www.`, a trailing `/` and `#fragment` are ignored, and video or post IDs
    are matched across URL forms (`youtu.be/ID` = `youtube.com/watch?v=ID` =
    `/shorts/ID`; X/Twitter, Reddit, Instagram, TikTok, Vimeo). The link is
    not added twice.
  - **Possible duplicate**: the last meaningful part of the link (slug or ID),
    or everything after the domain (path and query), matches a link already
    saved on any website. You're warned, and the link is flagged for review.
- **Change domain**: when a website moves to a new domain, open it (or
  long-press it) in Websites and choose Change domain. Every link keeps its
  path and query; links that become identical are merged. Optionally, links
  saved or imported later from the old domain are changed too (see the menu's
  Domain changes to stop that).
- Links are **never opened** by the app: you can only copy them. The
  clipboard clears after 60 s.
- Import / export: encrypted file (password), plain JSON, or plain text
  (one URL per line). Import accepts any of these, or any text containing links.

## Security design

| Piece | How |
|---|---|
| PIN key | Argon2id (19 MiB, 2 passes), then HKDF with a random 32-byte device secret held in Android Keystore / iOS Keychain (this device only) |
| Data | All links in `vault.bin`, AES-256-GCM with a random data key. The PIN key only wraps that data key, so changing the PIN is instant |
| Share without login | Each shared link is sealed to an X25519 public key (ephemeral ECDH + HKDF + AES-GCM) into `inbox/`. The private key is wrapped by the data key, so the share screen can write but never read |
| Wrong PINs | 5 free tries, then waits of 30 s, doubling up to 1 hour. Stored in the Keystore/Keychain |
| Forgotten PIN | No recovery, by design. "Forgot PIN?" erases everything. Keep an export |
| Lock | Locks whenever the app leaves the screen; keys are dropped from memory |
| Screen | `FLAG_SECURE` on Android (no screenshots, blank app-switcher preview); a cover on iOS when inactive |
| Network | None in the `store` edition: no INTERNET permission at all. The internal-test `preview` edition uses HTTPS for opt-in thumbnails only (see Editions) |
| Backup | Android cloud backup and device transfer are off; move links with Export |

Dart can't guarantee that freed memory is wiped, so keys may stay in RAM
for a while after locking. The OS sandbox covers this.

## Run

```
flutter pub get
flutter test
flutter run
```

## Release for Google Play

Package name: `io.github.gauravpwagh.spanweb` (can't change after the first upload).

1. Create the upload key once, and back up the `.jks` file and its password:
   ```
   keytool -genkey -v -keystore C:/Users/WR/keys/spanweb-upload.jks -keyalg RSA -keysize 2048 -validity 10000 -alias upload
   ```
2. Copy `android/key.properties.example` to `android/key.properties` and fill in the passwords.
3. Raise `version:` in `pubspec.yaml` for every upload (`1.0.0+1` → `1.0.1+2`; the number after `+` must go up).
4. `flutter build appbundle --release` → `build/app/outputs/bundle/storeRelease/app-store-release.aab`
   (Flutter's message may name `bundle/release/`; the file is in `storeRelease/`).
5. Play Console → your app → Testing → Internal testing → Create release → upload the `.aab`.
   Keep Play App Signing on (the default).

Without `key.properties` the release build is signed with the debug key, which Play rejects.

App icon: drawn by `python tool/make_icon.py` (needs Pillow), which writes the
Android adaptive and themed icons, all iOS sizes, and `assets/icon/play-store-512.png`
for the Play listing. Edit the script and re-run it to change the icon.

## Editions (Android flavors)

| Flavor | For | Network | Build |
|---|---|---|---|
| `store` (default) | Play Store | None: INTERNET permission removed | `flutter build appbundle --release` |
| `preview` | Internal testing only | HTTPS only, for opt-in video thumbnails | `flutter build appbundle --release --flavor preview` |

Run on a device with `flutter run` (store) or `flutter run --flavor preview`.
Thumbnails are built only from YouTube video IDs (`i.ytimg.com`), never by
fetching pages; see `docs/thumbnails-plan.md`. Upload preview bundles only to
the **Internal testing** track, and give each upload a higher build number
(`+N` in `pubspec.yaml`) than any earlier upload of either flavor.

## iOS: Share Extension (needs a Mac with Xcode)

The Android share target is already set up. On iOS, the share sheet needs a
separate app extension target, which can only be added in Xcode:

1. `open ios/Runner.xcworkspace`
2. **File → New → Target → Share Extension**, name it `ShareExtension`
   (language Swift). Don't activate its scheme.
3. Set the extension's **iOS Deployment Target** to match Runner.
4. On **Runner** and **ShareExtension**, under Signing & Capabilities, add the
   **App Groups** capability with the same group, e.g. `group.com.linkvault.linkVault`.
5. Replace `ios/ShareExtension/ShareViewController.swift` with:
   ```swift
   import share_handler_ios_models

   class ShareViewController: ShareHandlerIosViewController {}
   ```
6. Add to `ios/Podfile`, then run `pod install` in `ios/`:
   ```ruby
   target 'ShareExtension' do
     inherit! :search_paths
     pod "share_handler_ios_models", :path => ".symlinks/plugins/share_handler_ios/ios/Models"
   end
   ```
7. In `ios/ShareExtension/Info.plist`, set `NSExtensionActivationRule` to
   accept web URLs and text (`NSExtensionActivationSupportsWebURLWithMaxCount` = 1,
   `NSExtensionActivationSupportsText` = YES). Then add the `AppGroupId` and
   URL-scheme keys described in the
   [share_handler README](https://pub.dev/packages/share_handler) to both Info.plists.

On iOS, the shared text waits briefly in the App Group container until the
main app opens and seals it into the encrypted inbox.

## Titles and thumbnails (preview edition only)

Built into the `preview` flavor for internal testing; the `store` flavor has
no network access and doesn't include them.

- **Video sites** (YouTube, Vimeo, Dailymotion): off by default, opt-in per
  site. The title and thumbnail come from each site's official oEmbed
  service, asked about the video ID; the video page is never loaded. YouTube
  thumbnails come straight from `i.ytimg.com`. Thumbnails are accepted only
  from each site's own image hosts. A title you already have is never replaced.
- **Any other link**: a "Fetch title and image from <site>" button in link
  details asks that website for the start of the page (256 KB at most) and
  reads only its title (`og:title`, `twitter:title`, `<title>`) and preview
  image address (`og:image`, `twitter:image`, `rel="image_src"`). Only on a
  tap, one link at a time; page redirects must stay on the same website. The
  image may be on another HTTPS host (sites often use an image server); it is
  fetched from that host alone, with the same checks and re-encoding as video
  thumbnails, and shown in lists like a video thumbnail.
- **Grid view**: the button next to sort switches link lists between a list
  and a grid of cards with large images (or the site's name when there is
  none), for browsing by picture. Tap a card for details, long-press or use
  its copy button to copy the link. The choice is kept in the vault.
- All requests are HTTPS only, with no cookies or referrer, size caps and a
  10 s timeout, and refuse private network addresses. Images are re-encoded
  in an isolate; titles and images are stored encrypted. TikTok is left out
  because it isn't reachable in India.
- Details: `docs/thumbnails-plan.md`.
