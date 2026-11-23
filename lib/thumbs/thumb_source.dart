/// Where a link's thumbnail comes from. Addresses are built only from the
/// video ID the app already extracted; the saved page is never fetched.
library;

class ThumbRequest {
  const ThumbRequest(this.url, this.site);

  /// The image to download.
  final Uri url;

  /// The website group it belongs to, matched against the user's per-site
  /// switches.
  final String site;
}

/// Sites that can have thumbnails, by website group, with a display name.
const thumbSites = {'youtube.com': 'YouTube'};

/// The only hosts the downloader may contact.
const thumbHosts = {'i.ytimg.com'};

final _youtube = RegExp(r'^youtube:([A-Za-z0-9_-]{11})$');

/// The thumbnail for a link's canonical key, or null if the site isn't
/// supported.
ThumbRequest? thumbRequestFor(String canonicalKey) {
  final yt = _youtube.firstMatch(canonicalKey);
  if (yt != null) {
    // mqdefault: 320x180, exists for every video.
    return ThumbRequest(Uri.https('i.ytimg.com', '/vi/${yt[1]}/mqdefault.jpg'), 'youtube.com');
  }
  return null;
}
