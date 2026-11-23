import 'url_tools.dart';

/// One saved link. Only [url], [addedAt], [title], [tags], [note] and
/// [possibleDuplicate] are stored; everything else is derived from [url] on
/// load, so improving the URL rules later re-groups old links too.
class LinkItem {
  LinkItem({
    required this.id,
    required this.url,
    required this.addedAt,
    Set<String>? tags,
    this.title,
    this.note,
    this.possibleDuplicate = false,
  })  : tags = tags ?? <String>{},
        parsed = parseLink(url);

  final String id;
  final String url;
  final DateTime addedAt;
  final Set<String> tags;

  /// The page title sent by the app the link was shared from, or typed in.
  String? title;
  String? note;
  bool possibleDuplicate;
  final ParsedLink? parsed;

  String get cleanUrl => parsed?.clean ?? url;

  /// The site as shown: the host without `www.`/`m.`, e.g. `news.bbc.co.uk`.
  String get host => parsed?.host ?? group;

  /// What lists show: the address after the domain (`/news/articles/c123?id=2`),
  /// since the website is shown next to it. A home page shows its host.
  /// Copying always uses the whole [cleanUrl].
  String get displayPath {
    final u = Uri.tryParse(cleanUrl);
    if (u == null) return cleanUrl;
    final path = u.path == '/' ? '' : u.path;
    final rest = '$path${u.hasQuery ? '?${u.query}' : ''}';
    if (rest.isEmpty) return host;
    try {
      return Uri.decodeFull(rest); // readable: spaces and accents, not %20
    } on ArgumentError {
      return rest;
    }
  }
  String get group => parsed?.group ?? 'other';
  String get canonicalKey => parsed?.canonicalKey ?? 'raw:$url';
  String? get lastSegment => parsed?.lastSegment;
  String? get pathKey => parsed?.pathKey;

  Map<String, Object?> toJson() => {
        'id': id,
        'url': url,
        'addedAt': addedAt.toUtc().toIso8601String(),
        if (title != null && title!.isNotEmpty) 'title': title,
        'tags': tags.toList()..sort(),
        if (note != null && note!.isNotEmpty) 'note': note,
        if (possibleDuplicate) 'possibleDuplicate': true,
      };

  factory LinkItem.fromJson(Map<String, Object?> j) => LinkItem(
        id: j['id'] as String,
        url: j['url'] as String,
        addedAt: DateTime.parse(j['addedAt'] as String).toLocal(),
        tags: {for (final t in (j['tags'] as List? ?? const [])) t as String},
        title: j['title'] as String?,
        note: j['note'] as String?,
        possibleDuplicate: j['possibleDuplicate'] == true,
      );
}

/// Thumbnail choices. Off by default; sites must be switched on one by one.
class ThumbSettings {
  ThumbSettings({this.enabled = false, Set<String>? sites, this.automatic = false})
      : sites = sites ?? <String>{};

  bool enabled;

  /// Website groups allowed to be asked for thumbnails, e.g. `youtube.com`.
  final Set<String> sites;

  /// Load thumbnails for newly saved links without asking. Imports always ask.
  bool automatic;

  Map<String, Object?> toJson() => {
        'enabled': enabled,
        'sites': sites.toList()..sort(),
        'automatic': automatic,
      };

  factory ThumbSettings.fromJson(Map<String, Object?>? j) => j == null
      ? ThumbSettings()
      : ThumbSettings(
          enabled: j['enabled'] == true,
          sites: {for (final s in (j['sites'] as List? ?? const [])) s as String},
          automatic: j['automatic'] == true,
        );
}

/// Whether a thumbnail was stored, or why not. Failed ones are not retried
/// automatically.
enum ThumbStatus { ok, failed }

/// Everything inside the encrypted vault.
class VaultData {
  VaultData({
    List<LinkItem>? links,
    Set<String>? tagLibrary,
    ThumbSettings? thumbSettings,
    Map<String, ThumbStatus>? thumbs,
    Map<String, String>? domainMoves,
  })  : links = links ?? [],
        tagLibrary = tagLibrary ?? <String>{},
        thumbSettings = thumbSettings ?? ThumbSettings(),
        thumbs = thumbs ?? {},
        domainMoves = domainMoves ?? {};

  static const version = 1;
  final List<LinkItem> links;

  /// The fixed set of tags the user manages. Free-text tags typed on a link
  /// are added here too, so they are suggested next time.
  final Set<String> tagLibrary;

  final ThumbSettings thumbSettings;

  /// Thumbnail status by link canonical key. The images themselves are
  /// separate encrypted files.
  final Map<String, ThumbStatus> thumbs;

  /// Websites that moved: old group -> new domain. Links saved or imported
  /// later from the old domain are changed to the new one.
  final Map<String, String> domainMoves;

  Map<String, Object?> toJson() => {
        'version': version,
        'links': links.map((l) => l.toJson()).toList(),
        'tags': tagLibrary.toList()..sort(),
        'thumbSettings': thumbSettings.toJson(),
        if (thumbs.isNotEmpty) 'thumbs': {for (final e in thumbs.entries) e.key: e.value.name},
        if (domainMoves.isNotEmpty) 'domainMoves': domainMoves,
      };

  factory VaultData.fromJson(Map<String, Object?> j) => VaultData(
        links: [
          for (final l in (j['links'] as List? ?? const []))
            LinkItem.fromJson((l as Map).cast<String, Object?>()),
        ],
        tagLibrary: {for (final t in (j['tags'] as List? ?? const [])) t as String},
        thumbSettings: ThumbSettings.fromJson((j['thumbSettings'] as Map?)?.cast()),
        thumbs: {
          for (final e in ((j['thumbs'] as Map?) ?? const {}).entries)
            e.key as String: ?ThumbStatus.values.asNameMap()[e.value],
        },
        domainMoves: {
          for (final e in ((j['domainMoves'] as Map?) ?? const {}).entries)
            if (e.key is String && e.value is String) e.key as String: e.value as String,
        },
      );
}

/// Tags are free text, trimmed, single-spaced, lowercase, at most 40 chars.
String? normalizeTag(String raw) {
  final t = raw.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  if (t.isEmpty) return null;
  return t.length > 40 ? t.substring(0, 40) : t;
}
