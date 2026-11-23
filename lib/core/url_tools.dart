/// URL parsing, cleanup, website grouping and duplicate keys.
///
/// Everything here is pure Dart and works offline: the app never makes a
/// network request to resolve a link.
library;

/// Query parameters that only track the click and never change the content.
const _trackingParams = {
  'fbclid', 'gclid', 'dclid', 'gbraid', 'wbraid', 'msclkid', 'yclid',
  'mc_cid', 'mc_eid', 'igshid', 'igsh', 'si', '_ga', '_gl', 'spm',
  'ref_src', 'ref_url', 'share_id', 'utm_id',
};

/// Hostname prefixes that point at the same site.
const _hostPrefixes = ['www.', 'm.', 'mobile.', 'amp.'];

/// Short or alternative hosts that belong to another site's group.
const _hostAliases = {
  'youtu.be': 'youtube.com',
  'youtube-nocookie.com': 'youtube.com',
  'twitter.com': 'x.com',
  'redd.it': 'reddit.com',
  'instagr.am': 'instagram.com',
  'fb.watch': 'facebook.com',
  'fb.com': 'facebook.com',
};

/// Public suffixes with more than one label, so `bbc.co.uk` groups as
/// `bbc.co.uk` and not `co.uk`. A short list, not the full public suffix list.
const _multiLabelSuffixes = {
  'co.uk', 'org.uk', 'ac.uk', 'gov.uk', 'me.uk', 'ltd.uk', 'plc.uk',
  'com.au', 'net.au', 'org.au', 'edu.au', 'gov.au',
  'co.in', 'net.in', 'org.in', 'gov.in', 'ac.in', 'edu.in', 'firm.in',
  'co.jp', 'ne.jp', 'or.jp', 'ac.jp',
  'co.nz', 'org.nz', 'co.za', 'co.kr', 'or.kr',
  'com.br', 'com.mx', 'com.ar', 'com.sg', 'com.my', 'com.cn', 'com.hk',
  'com.tw', 'com.tr', 'com.pk', 'com.bd', 'com.ng', 'com.eg', 'com.sa',
  // Hosting suffixes where each subdomain is a different owner.
  'github.io', 'gitlab.io', 'blogspot.com', 'wordpress.com', 'tumblr.com',
  'substack.com', 'medium.com', 'vercel.app', 'netlify.app', 'pages.dev',
  'web.app', 'firebaseapp.com', 'herokuapp.com', 'appspot.com',
};

/// Path segments too generic to say two links are the same thing.
const _genericSegments = {
  'index', 'home', 'default', 'main', 'watch', 'video', 'videos', 'post',
  'posts', 'amp', 'view', 'page', 'share', 'p', 'reel', 'reels', 'status',
  'comments', 'article', 'articles', 'news', 'blog', 'en', 'item',
};

final _urlInText = RegExp(
  r'''((?:https?://|www\.)[^\s<>"'`]+)''',
  caseSensitive: false,
);
final _bareDomain = RegExp(
  r'^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+(?::\d+)?(?:[/?#]\S*)?$',
  caseSensitive: false,
);
final _ipv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');

/// A link after parsing, with everything the app derives from it.
class ParsedLink {
  ParsedLink._({
    required this.original,
    required this.clean,
    required this.host,
    required this.group,
    required this.canonicalKey,
    required this.lastSegment,
  });

  /// The URL as it was given (trimmed).
  final String original;

  /// The URL without tracking parameters or fragment. This is what is copied.
  final String clean;

  /// Hostname without `www.` / `m.` prefixes, aliases applied.
  final String host;

  /// The website group, for example `youtube.com` or `bbc.co.uk`.
  final String group;

  /// Two links with the same key are the same content (exact duplicate).
  final String canonicalKey;

  /// The identifying last part of the link, used for possible-duplicate
  /// checks across all websites. Null when the link has none worth comparing.
  final String? lastSegment;
}

/// Pulls every http(s) link out of shared text such as
/// "Look at this https://example.com/a".
List<String> extractUrls(String text) {
  final found = <String>[];
  for (final m in _urlInText.allMatches(text)) {
    var url = m.group(1)!;
    // Trailing punctuation from the sentence around the link.
    url = url.replaceFirst(RegExp(r'[.,;:!?)\]}>]+$'), '');
    if (url.isNotEmpty) found.add(url);
  }
  if (found.isEmpty) {
    final t = text.trim();
    if (!t.contains(RegExp(r'\s')) && _bareDomain.hasMatch(t)) found.add(t);
  }
  return found;
}

const maxTitleLength = 200;

/// Tidies a title: single spaces, no control characters, at most
/// [maxTitleLength] characters. Null if nothing is left, or if it is only a link.
String? cleanTitle(String? raw) {
  if (raw == null) return null;
  var t = raw.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty || RegExp(r'^https?://\S+$', caseSensitive: false).hasMatch(t)) return null;
  if (t.length > maxTitleLength) t = '${t.substring(0, maxTitleLength - 1).trimRight()}…';
  return t;
}

/// The title that came with a share: the subject the other app sent, or
/// else the words around the link (for apps that share "Title https://…").
/// Null when the text holds more than one link, since it isn't clear which
/// link the words belong to.
String? sharedTitle(String text, {String? subject}) {
  final urls = extractUrls(text);
  if (urls.length != 1) return null;
  final fromSubject = cleanTitle(subject);
  if (fromSubject != null) return fromSubject;
  final rest = text.replaceFirst(urls.single, ' ');
  // Separators apps put between the title and the link.
  final trimmed = rest.replaceAll(RegExp(r'^[\s\-–—|:•·]+|[\s\-–—|:•·]+$'), '');
  // A word or two ("see", "look") is chatter, not a title.
  return trimmed.length < 8 ? null : cleanTitle(trimmed);
}

/// Parses one link. Returns null if it is not a usable http(s) URL.
ParsedLink? parseLink(String input) {
  var raw = input.trim();
  if (raw.isEmpty) return null;
  if (!RegExp(r'^[a-z][a-z0-9+.-]*://', caseSensitive: false).hasMatch(raw)) {
    if (!_bareDomain.hasMatch(raw)) return null;
    raw = 'https://$raw';
  }
  final Uri uri;
  try {
    uri = Uri.parse(raw);
  } on FormatException {
    return null;
  }
  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  final rawHost = uri.host.toLowerCase();
  if (rawHost.isEmpty || (!rawHost.contains('.') && rawHost != 'localhost')) {
    return null;
  }

  final host = normalizeHost(rawHost);
  final group = groupForHost(host);

  // Drop tracking parameters and the fragment.
  final kept = <MapEntry<String, String>>[];
  if (uri.hasQuery) {
    for (final part in uri.query.split('&')) {
      if (part.isEmpty) continue;
      final eq = part.indexOf('=');
      final key = Uri.decodeQueryComponent(eq < 0 ? part : part.substring(0, eq));
      final value = eq < 0 ? '' : Uri.decodeQueryComponent(part.substring(eq + 1));
      if (_isTracking(key)) continue;
      kept.add(MapEntry(key, value));
    }
  }
  final cleanUri = uri.replace(
    scheme: scheme,
    host: rawHost,
    query: kept.isEmpty ? '' : _encodeQuery(kept),
    fragment: '',
  );
  var clean = cleanUri.toString();
  // Uri.replace leaves an empty "?" / "#" behind.
  while (clean.endsWith('?') || clean.endsWith('#')) {
    clean = clean.substring(0, clean.length - 1);
  }

  final segments = uri.pathSegments.where((s) => s.isNotEmpty).toList();
  final params = {for (final e in kept) e.key: e.value};
  final siteId = _siteSpecificId(group, host, segments, params);

  final String canonicalKey;
  final String? lastSegment;
  if (siteId != null) {
    canonicalKey = siteId;
    lastSegment = siteId.substring(siteId.indexOf(':') + 1).toLowerCase();
  } else {
    final path = segments.join('/');
    final sorted = [...kept]..sort((a, b) {
        final c = a.key.compareTo(b.key);
        return c != 0 ? c : a.value.compareTo(b.value);
      });
    final port = uri.hasPort && !_isDefaultPort(scheme, uri.port) ? ':${uri.port}' : '';
    canonicalKey = 'url:$host$port/$path${sorted.isEmpty ? '' : '?${_encodeQuery(sorted)}'}';
    lastSegment = _meaningfulLastSegment(segments);
  }

  return ParsedLink._(
    original: input.trim(),
    clean: clean,
    host: host,
    group: group,
    canonicalKey: canonicalKey,
    lastSegment: lastSegment,
  );
}

/// Lowercases, strips `www.`-style prefixes and applies host aliases.
String normalizeHost(String host) {
  var h = host.toLowerCase();
  if (h.endsWith('.')) h = h.substring(0, h.length - 1);
  var changed = true;
  while (changed) {
    changed = false;
    for (final p in _hostPrefixes) {
      if (h.startsWith(p) && h.length > p.length && h.substring(p.length).contains('.')) {
        h = h.substring(p.length);
        changed = true;
      }
    }
  }
  return _hostAliases[h] ?? h;
}

/// The website a host belongs to: its registrable domain.
String groupForHost(String host) {
  final h = normalizeHost(host);
  if (_ipv4.hasMatch(h) || h.startsWith('[') || !h.contains('.')) return h;
  final labels = h.split('.');
  if (labels.length <= 2) return _hostAliases[h] ?? h;
  final lastTwo = labels.sublist(labels.length - 2).join('.');
  final String domain;
  if (_multiLabelSuffixes.contains(lastTwo)) {
    domain = labels.sublist(labels.length - 3).join('.');
  } else {
    domain = lastTwo;
  }
  return _hostAliases[domain] ?? domain;
}

bool _isTracking(String key) {
  final k = key.toLowerCase();
  return k.startsWith('utm_') || _trackingParams.contains(k);
}

bool _isDefaultPort(String scheme, int port) =>
    (scheme == 'https' && port == 443) || (scheme == 'http' && port == 80);

String _encodeQuery(List<MapEntry<String, String>> entries) => entries
    .map((e) => e.value.isEmpty
        ? Uri.encodeQueryComponent(e.key)
        : '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}')
    .join('&');

/// IDs for sites where the content ID is not simply the last path segment.
String? _siteSpecificId(
  String group,
  String host,
  List<String> seg,
  Map<String, String> params,
) {
  String? after(String marker) {
    final i = seg.indexOf(marker);
    return (i >= 0 && i + 1 < seg.length) ? seg[i + 1] : null;
  }

  switch (group) {
    case 'youtube.com':
      String? id;
      if (host == 'youtube.com' && seg.isEmpty) return null;
      if (seg.isNotEmpty && seg.length == 1 && _ytId.hasMatch(seg[0]) && params.isEmpty) {
        // youtu.be/<id> is normalized to the youtube.com group.
        id = seg[0];
      }
      id ??= (seg.isNotEmpty && seg[0] == 'watch') ? params['v'] : null;
      id ??= after('shorts') ?? after('embed') ?? after('live') ?? after('v');
      if (id == null && seg.length == 1 && _ytId.hasMatch(seg[0])) id = seg[0];
      return (id != null && _ytId.hasMatch(id)) ? 'youtube:$id' : null;
    case 'vimeo.com':
      final id = seg.firstWhere((s) => RegExp(r'^\d{5,}$').hasMatch(s), orElse: () => '');
      return id.isEmpty ? null : 'vimeo:$id';
    case 'instagram.com':
      final id = after('p') ?? after('reel') ?? after('reels') ?? after('tv');
      return id == null ? null : 'instagram:$id';
    case 'tiktok.com':
      final id = after('video');
      return (id != null && RegExp(r'^\d+$').hasMatch(id)) ? 'tiktok:$id' : null;
    case 'x.com':
      final id = after('status');
      return (id != null && RegExp(r'^\d+$').hasMatch(id)) ? 'x:$id' : null;
    case 'reddit.com':
      if (host == 'reddit.com' && seg.length == 1 && params.isEmpty &&
          RegExp(r'^[a-z0-9]{5,8}$').hasMatch(seg[0])) {
        return 'reddit:${seg[0]}'; // redd.it/<id>
      }
      final id = after('comments');
      return id == null ? null : 'reddit:$id';
    case 'dailymotion.com':
      final id = after('video');
      return id == null ? null : 'dailymotion:${id.split('_').first}';
  }
  return null;
}

final _ytId = RegExp(r'^[A-Za-z0-9_-]{11}$');

String? _meaningfulLastSegment(List<String> segments) {
  for (var i = segments.length - 1; i >= 0; i--) {
    var s = segments[i];
    try {
      s = Uri.decodeComponent(s);
    } on ArgumentError {
      // Keep the raw segment if it is not valid percent-encoding.
    }
    s = s.toLowerCase().replaceFirst(
        RegExp(r'\.(html?|php|aspx?|jsp|cfm|shtml)$'), '');
    if (s.length < 4 || _genericSegments.contains(s)) continue;
    return s;
  }
  return null;
}
