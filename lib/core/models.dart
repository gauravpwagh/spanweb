import 'url_tools.dart';

/// One saved link. Only [url], [addedAt], [tags], [note] and
/// [possibleDuplicate] are stored; everything else is derived from [url] on
/// load, so improving the URL rules later re-groups old links too.
class LinkItem {
  LinkItem({
    required this.id,
    required this.url,
    required this.addedAt,
    Set<String>? tags,
    this.note,
    this.possibleDuplicate = false,
  })  : tags = tags ?? <String>{},
        parsed = parseLink(url);

  final String id;
  final String url;
  final DateTime addedAt;
  final Set<String> tags;
  String? note;
  bool possibleDuplicate;
  final ParsedLink? parsed;

  String get cleanUrl => parsed?.clean ?? url;
  String get group => parsed?.group ?? 'other';
  String get canonicalKey => parsed?.canonicalKey ?? 'raw:$url';
  String? get lastSegment => parsed?.lastSegment;

  Map<String, Object?> toJson() => {
        'id': id,
        'url': url,
        'addedAt': addedAt.toUtc().toIso8601String(),
        'tags': tags.toList()..sort(),
        if (note != null && note!.isNotEmpty) 'note': note,
        if (possibleDuplicate) 'possibleDuplicate': true,
      };

  factory LinkItem.fromJson(Map<String, Object?> j) => LinkItem(
        id: j['id'] as String,
        url: j['url'] as String,
        addedAt: DateTime.parse(j['addedAt'] as String).toLocal(),
        tags: {for (final t in (j['tags'] as List? ?? const [])) t as String},
        note: j['note'] as String?,
        possibleDuplicate: j['possibleDuplicate'] == true,
      );
}

/// Everything inside the encrypted vault.
class VaultData {
  VaultData({List<LinkItem>? links, Set<String>? tagLibrary})
      : links = links ?? [],
        tagLibrary = tagLibrary ?? <String>{};

  static const version = 1;
  final List<LinkItem> links;

  /// The fixed set of tags the user manages. Free-text tags typed on a link
  /// are added here too, so they are suggested next time.
  final Set<String> tagLibrary;

  Map<String, Object?> toJson() => {
        'version': version,
        'links': links.map((l) => l.toJson()).toList(),
        'tags': tagLibrary.toList()..sort(),
      };

  factory VaultData.fromJson(Map<String, Object?> j) => VaultData(
        links: [
          for (final l in (j['links'] as List? ?? const []))
            LinkItem.fromJson((l as Map).cast<String, Object?>()),
        ],
        tagLibrary: {for (final t in (j['tags'] as List? ?? const [])) t as String},
      );
}

/// Tags are free text, trimmed, single-spaced, lowercase, at most 40 chars.
String? normalizeTag(String raw) {
  final t = raw.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();
  if (t.isEmpty) return null;
  return t.length > 40 ? t.substring(0, 40) : t;
}
