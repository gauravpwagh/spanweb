# Plan: video thumbnails (version 2)

**Status:** Phases 1 and 2 (YouTube, Vimeo, Dailymotion via oEmbed, plus a
tap-to-fetch page title for other links) are built in the `preview` flavor, for internal
testing only. The `store` flavor is unchanged and has no network access.

Goal: show a small thumbnail next to video links, without scraping pages and
without weakening the vault. Off by default; the user opts in per site.

## Principles

1. **Never fetch the saved page.** Thumbnail addresses are built from the video
   ID the app already extracts (`canonicalKey`, e.g. `youtube:dQw4w9WgXcQ`), or
   come from a site's official oEmbed endpoint.
2. **Fixed allowlist of hosts**, checked on every request, including redirects.
3. **Opt-in, per site**, and only while the app is unlocked.
4. **Untrusted bytes never reach the platform image decoder.** Every image is
   decoded and re-encoded in pure Dart in a background isolate first.
5. **Stored encrypted** with the vault's data key, deleted with the link.

## Phase 1: YouTube only

| Item | Detail |
|---|---|
| Source | `https://i.ytimg.com/vi/<id>/hqdefault.jpg` (480×360, exists for every video; shown cropped to 16:9). ID already validated by `_ytId` in `url_tools.dart` |
| What leaks | Google learns the video ID and your IP. Nothing else: no page, no cookies, no account |

### New code

```
lib/thumbs/
  thumb_source.dart    canonicalKey -> ThumbRequest (url + allowed image hosts), or null
  safe_fetch.dart      the only code that touches the network
  sanitize.dart        decode -> size check -> resize -> re-encode, in Isolate.run
  thumb_store.dart     encrypted files in vault/thumbs/
  thumb_service.dart   queue, consent checks, memory cache, lock handling
lib/ui/thumbnail_settings_screen.dart
```

### `safe_fetch.dart` rules

- HTTPS only; host must be in the allowlist (exact match, or a listed suffix for CDNs).
- `followRedirects = false`. A redirect is followed manually only if the new host is also allowed. Maximum 2 redirects.
- Resolve DNS first and refuse loopback, private, link-local, CGNAT and multicast addresses (IPv4 and IPv6). Connect to the checked address, so a second DNS answer can't swap it.
- No cookies, no `Referer`, generic `User-Agent`.
- 10 s total timeout; stream the body and abort above 2 MB.
- `Content-Type` must be `image/jpeg`, `image/png` or `image/webp`, and the first bytes must match that format.

### `sanitize.dart`

- Uses the pure-Dart `image` package inside `Isolate.run`.
- Reads the header first and rejects images over 4096×4096 before decoding, which blocks decompression bombs.
- Resizes to 480 px wide and re-encodes as JPEG (quality 75). Metadata (EXIF, ICC) is dropped as a side effect.
- Any exception means "no thumbnail". Nothing is retried in a loop.

### Storage

- `vault/thumbs/<name>.bin`, sealed with the data key (AES-256-GCM), AAD `thumb:<canonicalKey>`.
- `<name>` = HMAC-SHA256(key derived from the data key, canonicalKey), so file names don't reveal video IDs.
- Kept separate from `vault.bin`, so saving a tag doesn't rewrite every image.
- `VaultData` gains a small map `canonicalKey -> {state: ok|none|failed, at}`. "none" and "failed" are not fetched again automatically.
- Deleting a link deletes its thumbnail. "Erase everything" deletes the folder. On unlock, orphaned files are removed.
- Decrypted thumbnails are kept in memory only while unlocked, and cleared on lock.
- Exports don't include thumbnails; they can be fetched again.

### UI and consent

- Settings → **Video thumbnails**:
  - Master switch, off by default. Turning it on shows what leaks: "YouTube will see which video IDs you load, and your IP address."
  - Per-site switch (YouTube for now).
  - Mode: **Only when I tap** (default), or **Automatically for new links**.
- Link details: a **Load thumbnail** button when the mode is manual.
- Lists: the thumbnail is shown on the left of the tile when available. Tapping it opens the details, as now; links are still never opened.
- Imports never fetch automatically. Instead the app offers "Load N thumbnails?". The queue fetches one at a time with a random 1–3 s gap, and pauses on lock.

### Platform

- **Android:** the INTERNET permission is fixed at install, so the choice is between editions (see open decisions below). If thumbnails ship, add a `network_security_config.xml` that forbids cleartext and trusts only system certificates.
- **iOS:** no permission is needed. The default App Transport Security already forbids plain HTTP.

### Store and policy updates (before release)

- Privacy policy: replace "no internet access" with an exact description of thumbnail requests.
- Play listing: remove "No internet access at all". Say "Optional thumbnails, off by default".
- Data safety form: the app still sends nothing to the developer. Requests to YouTube are user-initiated and leave only the video ID with YouTube. Answer the form according to Google's definitions at the time.

### Tests

- `thumb_source`: correct URL for each YouTube link form; null for unsupported sites.
- `safe_fetch`, against a local test server:
  - refuses HTTP, other hosts, redirects to other hosts, and private IPs;
  - aborts over 2 MB, on a slow response, and on a wrong content type.
- `sanitize`: valid JPEG/PNG/WebP, truncated files, oversized dimensions, and random bytes.
- Storage: no ID or image bytes in plaintext on disk; delete and erase leave no files.
- Widget test: thumbnails off by default, and no network call happens without consent.
- Emulator run: enable, load, lock, check the cache is gone, unlock.

## Phase 2: more sites (same pipeline)

| Site | Endpoint (JSON, capped at 64 KB) | Image hosts |
|---|---|---|
| Vimeo | `https://vimeo.com/api/oembed.json?url=<clean url>` → `thumbnail_url` | `i.vimeocdn.com` |
| Dailymotion | `https://api.dailymotion.com/video/<id>?fields=thumbnail_360_url` | `*.dmcdn.net` |
| TikTok | `https://www.tiktok.com/oembed?url=<clean url>` → `thumbnail_url` | `*.tiktokcdn.com` (signed links that expire, so fetch immediately) |

The JSON is parsed with strict types, and only the one field is read. The image
address it contains must also pass the allowlist. oEmbed sends the clean link
(not just the ID) to that site; the settings text will say so.

Not planned: Instagram and Facebook (oEmbed needs a Meta developer token), X
(no thumbnail in its oEmbed), Reddit, and any general page scraping.

## Open decisions

1. **Editions on Android.**
   - (a) One app with thumbnails. The INTERNET permission is always present, and the "no internet" claim goes.
   - (b) Two flavors: `offline` (today's app) and `thumbs`, each with its own listing.
   - (c) Keep thumbnails in an internal-test build only, until you decide.
   - Recommendation: (c), then (b) if testers value thumbnails.
2. **Default mode once enabled.** Recommendation: "Only when I tap".

## Order of work

1. `thumb_source` and `sanitize`, with tests (no network yet).
2. `safe_fetch`, with tests against a local server.
3. `thumb_store`, plus the `VaultData` state map and the delete/erase hooks.
4. Settings screen, the Load button, tiles, and the import prompt.
5. Android flavor and network config, then an emulator run.
6. Policy, listing and Data safety updates, then an internal test release.
7. Phase 2 sites.
