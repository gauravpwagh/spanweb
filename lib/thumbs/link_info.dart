/// Reads titles and thumbnail addresses out of downloaded replies. Pure
/// functions: the downloads themselves are in safe_fetch.dart.
library;

import 'dart:convert';

import '../core/url_tools.dart';
import 'safe_fetch.dart';
import 'thumb_source.dart';

/// The title and thumbnail address in an oEmbed reply. A thumbnail on a host
/// the source doesn't allow is dropped.
({String? title, Uri? thumb}) parseOEmbed(String body, VideoSource source) {
  final Object? j;
  try {
    j = jsonDecode(body);
  } on FormatException {
    return (title: null, thumb: null);
  }
  if (j is! Map) return (title: null, thumb: null);
  final title = j['title'] is String ? cleanTitle(j['title'] as String) : null;
  Uri? thumb;
  if (j['thumbnail_url'] case final String t) {
    final u = Uri.tryParse(t);
    if (u != null && u.scheme == 'https' && u.userInfo.isEmpty && hostAllowed(u.host, source.imageHosts)) {
      thumb = u;
    }
  }
  return (title: title, thumb: thumb);
}

/// Where to ask for a page's title: the cleaned link over HTTPS, and the
/// hosts it may redirect to (the same website only).
({Uri url, Set<String> hosts})? pageRequestFor(String link) {
  final p = parseLink(link);
  if (p == null) return null;
  var uri = Uri.parse(p.clean);
  if (uri.scheme == 'http') uri = uri.replace(scheme: 'https', port: uri.port == 80 ? 443 : uri.port);
  if (uri.host.isEmpty || !uri.host.contains('.')) return null;
  return (url: uri, hosts: {uri.host.toLowerCase(), p.group, '.${p.group}'});
}

final _meta = RegExp(r'<meta\b[^>]*>', caseSensitive: false);
final _attr = RegExp(r'''([a-zA-Z][\w:-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))''');
final _titleTag = RegExp(r'<title\b[^>]*>([\s\S]*?)</title>', caseSensitive: false);

/// A page's title from the start of its HTML: `og:title`, then
/// `twitter:title`, then `<title>`. Only these are read; nothing in the page
/// is run or followed.
String? pageTitleFromHtml(String html) {
  final metas = <String, String>{};
  for (final m in _meta.allMatches(html)) {
    final attrs = <String, String>{};
    for (final a in _attr.allMatches(m[0]!)) {
      attrs[a[1]!.toLowerCase()] = a[2] ?? a[3] ?? a[4] ?? '';
    }
    final key = (attrs['property'] ?? attrs['name'])?.toLowerCase();
    final content = attrs['content'];
    if (key != null && content != null) metas.putIfAbsent(key, () => content);
  }
  for (final raw in [metas['og:title'], metas['twitter:title'], _titleTag.firstMatch(html)?[1]]) {
    final t = raw == null ? null : cleanTitle(decodeEntities(raw.replaceAll(RegExp(r'<[^>]*>'), ' ')));
    if (t != null) return t;
  }
  return null;
}

final _linkTag = RegExp(r'<link\b[^>]*>', caseSensitive: false);

/// The page's preview image (`og:image`, then `twitter:image`, then
/// `<link rel="image_src">`), resolved against [page]. Only an HTTPS address
/// with no credentials is accepted; the image may be on another host (sites
/// often keep images on a separate server).
Uri? pageImageFromHtml(String html, Uri page) {
  final metas = <String, String>{};
  for (final m in _meta.allMatches(html)) {
    final attrs = _attrsOf(m[0]!);
    final key = (attrs['property'] ?? attrs['name'])?.toLowerCase();
    final content = attrs['content'];
    if (key != null && content != null) metas.putIfAbsent(key, () => content);
  }
  String? linkImage;
  for (final m in _linkTag.allMatches(html)) {
    final attrs = _attrsOf(m[0]!);
    if (attrs['rel']?.toLowerCase() == 'image_src' && attrs['href'] != null) {
      linkImage = attrs['href'];
      break;
    }
  }
  for (final raw in [
    metas['og:image:secure_url'],
    metas['og:image'],
    metas['og:image:url'],
    metas['twitter:image'],
    metas['twitter:image:src'],
    linkImage,
  ]) {
    if (raw == null || raw.trim().isEmpty) continue;
    final Uri u;
    try {
      u = page.resolve(decodeEntities(raw.trim()));
    } on FormatException {
      continue;
    }
    if (u.scheme == 'https' && u.host.isNotEmpty && u.userInfo.isEmpty) return u;
  }
  return null;
}

Map<String, String> _attrsOf(String tag) => {
      for (final a in _attr.allMatches(tag)) a[1]!.toLowerCase(): a[2] ?? a[3] ?? a[4] ?? '',
    };

final _entity = RegExp(r'&(#x[0-9a-fA-F]{1,6}|#\d{1,7}|[a-zA-Z]{2,8});');
const _named = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'", 'nbsp': ' ', 'ndash': '–', 'mdash': '—', 'hellip': '…', 'rsquo': '’', 'lsquo': '‘', 'rdquo': '”', 'ldquo': '“'};

/// Decodes the HTML character references that appear in titles.
String decodeEntities(String s) => s.replaceAllMapped(_entity, (m) {
      final e = m[1]!;
      int? code;
      if (e.startsWith('#x')) {
        code = int.tryParse(e.substring(2), radix: 16);
      } else if (e.startsWith('#')) {
        code = int.tryParse(e.substring(1));
      } else {
        return _named[e.toLowerCase()] ?? m[0]!;
      }
      if (code == null || code == 0 || code > 0x10ffff || (code >= 0xd800 && code <= 0xdfff)) return ' ';
      return String.fromCharCode(code);
    });
