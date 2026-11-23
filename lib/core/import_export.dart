import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'link_repository.dart';
import 'models.dart';
import 'url_tools.dart';

/// Export file formats.
enum ExportFormat {
  /// Password-protected JSON (Argon2id + AES-256-GCM). Recommended.
  encrypted('Encrypted (recommended)', 'linkvault'),

  /// Readable JSON with dates and tags. Anyone with the file can read it.
  json('Plain JSON', 'json'),

  /// One URL per line, for pasting into other apps.
  text('Plain text (URLs only)', 'txt');

  const ExportFormat(this.label, this.extension);
  final String label;
  final String extension;
}

const _plainFormat = 'linkvault-export';
const _encryptedFormat = 'linkvault-encrypted';
const _exportAad = 'linkvault-export-v1';

Map<String, Object?> _exportJson(List<LinkItem> links, List<String> tags) => {
      'format': _plainFormat,
      'version': 1,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'tags': tags,
      'links': [
        for (final l in links)
          {
            'url': l.url,
            'addedAt': l.addedAt.toUtc().toIso8601String(),
            if (l.title != null) 'title': l.title,
            'tags': l.tags.toList()..sort(),
            if (l.note != null) 'note': l.note,
          },
      ],
    };

Future<Uint8List> buildExport(
  List<LinkItem> links,
  List<String> tags,
  ExportFormat format, {
  String? password,
}) async {
  switch (format) {
    case ExportFormat.text:
      return Uint8List.fromList(utf8.encode('${links.map((l) => l.cleanUrl).join('\n')}\n'));
    case ExportFormat.json:
      return Uint8List.fromList(
          utf8.encode(const JsonEncoder.withIndent('  ').convert(_exportJson(links, tags))));
    case ExportFormat.encrypted:
      if (password == null || password.length < 8) {
        throw ArgumentError('Password must be at least 8 characters');
      }
      final plain = utf8.encode(jsonEncode(_exportJson(links, tags)));
      final sealed = await sealWithPassword(password, plain, aad: _exportAad);
      return Uint8List.fromList(
          utf8.encode(jsonEncode({'format': _encryptedFormat, 'version': 1, ...sealed})));
  }
}

/// What a picked file turned out to be.
sealed class ImportSource {}

class NeedsPassword extends ImportSource {
  NeedsPassword(this.sealed);
  final Map<String, Object?> sealed;
}

class ReadyToImport extends ImportSource {
  ReadyToImport(this.links, this.tags);
  final List<IncomingLink> links;
  final Set<String> tags;
}

class WrongPassword implements Exception {}

/// Reads an export from this app, or any text with links in it
/// (one per line, or a list copied from elsewhere).
ImportSource readImport(Uint8List bytes) {
  final text = utf8.decode(bytes, allowMalformed: true);
  final trimmed = text.trimLeft();
  if (trimmed.startsWith('{')) {
    try {
      final j = jsonDecode(trimmed) as Map<String, Object?>;
      if (j['format'] == _encryptedFormat) return NeedsPassword(j);
      if (j['format'] == _plainFormat) return _fromExportJson(j);
    } on FormatException {
      // Not JSON after all; fall through and scan it for links.
    } on TypeError {
      // JSON of an unexpected shape; scan it for links.
    }
  }
  final links = [
    for (final line in text.split(RegExp(r'\r?\n')))
      for (final u in extractUrls(line)) IncomingLink(u),
  ];
  return ReadyToImport(links, {});
}

Future<ReadyToImport> decryptImport(NeedsPassword src, String password) async {
  final Uint8List plain;
  try {
    plain = await openWithPassword(password, src.sealed, aad: _exportAad);
  } catch (_) {
    throw WrongPassword();
  }
  return _fromExportJson(jsonDecode(utf8.decode(plain)) as Map<String, Object?>);
}

ReadyToImport _fromExportJson(Map<String, Object?> j) {
  final links = <IncomingLink>[];
  for (final raw in (j['links'] as List? ?? const [])) {
    if (raw is! Map) continue;
    final url = raw['url'];
    if (url is! String) continue;
    DateTime? addedAt;
    final a = raw['addedAt'];
    if (a is String) addedAt = DateTime.tryParse(a)?.toLocal();
    links.add(IncomingLink(
      url,
      addedAt: addedAt,
      tags: {for (final t in (raw['tags'] as List? ?? const [])) if (t is String) t},
      note: raw['note'] is String ? raw['note'] as String : null,
      title: raw['title'] is String ? raw['title'] as String : null,
    ));
  }
  final tags = {
    for (final t in (j['tags'] as List? ?? const []))
      if (t is String) ?normalizeTag(t),
  };
  return ReadyToImport(links, tags);
}

/// Counts what an import would do, without changing anything.
({int newLinks, int duplicates, int possible, int invalid}) previewImport(
    LinkRepository repo, List<IncomingLink> links) {
  var n = 0, d = 0, p = 0, inv = 0;
  final seen = <String>{};
  // Last parts of links earlier in this file, which the import also checks.
  final seenSegments = <String>{};
  for (final l in links) {
    final c = repo.check(l.url);
    if (c.invalid) {
      inv++;
    } else if (c.exact != null || !seen.add(c.parsed!.canonicalKey)) {
      d++;
    } else {
      n++;
      final seg = c.parsed!.lastSegment;
      final inFile = seg != null && !seenSegments.add(seg);
      if (c.possible.isNotEmpty || inFile) p++;
    }
  }
  return (newLinks: n, duplicates: d, possible: p, invalid: inv);
}
