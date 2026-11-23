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
  - **Possible duplicate**: the last meaningful part of the link (slug or ID)
    matches a link already saved on any website. You're warned, and the link
    is flagged for review.
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

## Thumbnails (preview edition only)

Opt-in YouTube thumbnails are built into the `preview` flavor for internal
testing; the `store` flavor doesn't include them. Images come only from
`i.ytimg.com`, using the video ID; pages are never fetched. Requests are
HTTPS only, with no cookies, a 2 MB cap and a 10 s timeout. Each image is
re-encoded in an isolate and stored encrypted. Thumbnails are off by default
and opt-in per site. More sites (Vimeo, Dailymotion, TikTok) are planned
in `docs/thumbnails-plan.md`.
