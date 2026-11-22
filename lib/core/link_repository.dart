import 'dart:math';

import 'package:flutter/foundation.dart';

import 'models.dart';
import 'url_tools.dart';
import 'vault_store.dart';

enum SortOrder { newestFirst, oldestFirst }

/// Result of checking a link before it is added.
class AddCheck {
  AddCheck(this.parsed, this.exact, this.possible);
  final ParsedLink? parsed;

  /// The same content is already saved (same canonical key).
  final LinkItem? exact;

  /// Different URL, but the same last part (for example the same slug or
  /// video ID on another site).
  final List<LinkItem> possible;

  bool get invalid => parsed == null;
}

/// Summary of a bulk add (import or inbox).
class MergeReport {
  int added = 0;
  int exactDuplicates = 0;
  int possibleDuplicates = 0;
  int invalid = 0;

  int get total => added + exactDuplicates + invalid;

  @override
  String toString() {
    final parts = <String>['$added added'];
    if (possibleDuplicates > 0) parts.add('$possibleDuplicates flagged as possible duplicates');
    if (exactDuplicates > 0) parts.add('$exactDuplicates already saved');
    if (invalid > 0) parts.add('$invalid not valid links');
    return parts.join(', ');
  }
}

/// One link to merge in bulk.
class IncomingLink {
  IncomingLink(this.url, {DateTime? addedAt, Set<String>? tags, this.note})
      : addedAt = addedAt ?? DateTime.now(),
        tags = tags ?? {};
  final String url;
  final DateTime addedAt;
  final Set<String> tags;
  final String? note;
}

/// The unlocked vault: all links, kept in memory and saved encrypted after
/// every change.
class LinkRepository extends ChangeNotifier {
  LinkRepository._(this._store, this._session, this._data) {
    _reindex();
  }

  static Future<LinkRepository> open(VaultStore store, Session session) async =>
      LinkRepository._(store, session, await store.loadVault(session));

  final VaultStore _store;
  final Session _session;
  final VaultData _data;
  final Map<String, LinkItem> _byCanonical = {};
  final Map<String, List<LinkItem>> _bySegment = {};
  Future<void> _saving = Future.value();

  List<LinkItem> get links => List.unmodifiable(_data.links);

  /// All tags: the managed list plus any in use.
  List<String> get allTags {
    final s = {..._data.tagLibrary, for (final l in _data.links) ...l.tags};
    return s.toList()..sort();
  }

  int tagUseCount(String tag) => _data.links.where((l) => l.tags.contains(tag)).length;

  /// Website groups, the most recently added-to first.
  List<({String group, int count, DateTime latest})> groups() {
    final map = <String, List<LinkItem>>{};
    for (final l in _data.links) {
      (map[l.group] ??= []).add(l);
    }
    final out = [
      for (final e in map.entries)
        (
          group: e.key,
          count: e.value.length,
          latest: e.value.map((l) => l.addedAt).reduce((a, b) => a.isAfter(b) ? a : b),
        ),
    ];
    out.sort((a, b) => b.latest.compareTo(a.latest));
    return out;
  }

  List<LinkItem> query({
    String? group,
    Set<String> tags = const {},
    String text = '',
    SortOrder sort = SortOrder.newestFirst,
    bool onlyPossibleDuplicates = false,
  }) {
    final q = text.trim().toLowerCase();
    final out = _data.links.where((l) {
      if (group != null && l.group != group) return false;
      if (onlyPossibleDuplicates && !l.possibleDuplicate) return false;
      if (!tags.every(l.tags.contains)) return false;
      if (q.isNotEmpty &&
          !l.cleanUrl.toLowerCase().contains(q) &&
          !(l.note?.toLowerCase().contains(q) ?? false) &&
          !l.tags.any((t) => t.contains(q))) {
        return false;
      }
      return true;
    }).toList();
    out.sort((a, b) => sort == SortOrder.newestFirst
        ? b.addedAt.compareTo(a.addedAt)
        : a.addedAt.compareTo(b.addedAt));
    return out;
  }

  int get possibleDuplicateCount => _data.links.where((l) => l.possibleDuplicate).length;

  AddCheck check(String url) {
    final parsed = parseLink(url);
    if (parsed == null) return AddCheck(null, null, const []);
    final exact = _byCanonical[parsed.canonicalKey];
    final possible = exact != null || parsed.lastSegment == null
        ? const <LinkItem>[]
        : List<LinkItem>.of(_bySegment[parsed.lastSegment] ?? const []);
    return AddCheck(parsed, exact, possible);
  }

  /// Other saved links that share this link's last part.
  List<LinkItem> similarTo(LinkItem item) {
    final seg = item.lastSegment;
    if (seg == null) return const [];
    return (_bySegment[seg] ?? const []).where((l) => l.id != item.id).toList();
  }

  /// Adds a link that passed [check]. Call only when there is no exact
  /// duplicate; possible duplicates are saved with a flag for review.
  Future<LinkItem> add(String url, {Set<String> tags = const {}, String? note, DateTime? addedAt}) async {
    final c = check(url);
    if (c.invalid) throw ArgumentError('Not a valid link');
    if (c.exact != null) throw StateError('Already saved');
    final item = _insert(IncomingLink(url, addedAt: addedAt, tags: tags, note: note), c);
    await _save();
    return item;
  }

  /// Adds many links at once: exact duplicates are merged into the existing
  /// link (tags combined, earliest date kept), possible duplicates flagged.
  Future<MergeReport> merge(Iterable<IncomingLink> incoming) async {
    final r = MergeReport();
    for (final inc in incoming) {
      final c = check(inc.url);
      if (c.invalid) {
        r.invalid++;
      } else if (c.exact != null) {
        r.exactDuplicates++;
        _mergeInto(c.exact!, inc);
      } else {
        final item = _insert(inc, c);
        r.added++;
        if (item.possibleDuplicate) r.possibleDuplicates++;
      }
    }
    if (r.total > 0) await _save();
    return r;
  }

  /// Moves links shared while locked into the vault, then deletes the inbox
  /// files that were read.
  Future<MergeReport?> ingestInbox() async {
    final entries = await _store.readInbox(_session);
    if (entries.isEmpty) return null;
    final incoming = <IncomingLink>[];
    var unreadable = 0;
    for (final e in entries) {
      final urls = extractUrls(e.text);
      if (urls.isEmpty) unreadable++;
      for (final u in urls) {
        incoming.add(IncomingLink(u, addedAt: e.sharedAt));
      }
    }
    final report = await merge(incoming);
    report.invalid += unreadable;
    await _saving;
    for (final e in entries) {
      await e.file.delete();
    }
    return report;
  }

  Future<void> setTags(LinkItem item, Set<String> tags) async {
    item.tags
      ..clear()
      ..addAll(tags.map(normalizeTag).whereType<String>());
    _data.tagLibrary.addAll(item.tags);
    await _save();
  }

  Future<void> setNote(LinkItem item, String? note) async {
    item.note = (note == null || note.trim().isEmpty) ? null : note.trim();
    await _save();
  }

  Future<void> clearPossibleDuplicate(LinkItem item) async {
    item.possibleDuplicate = false;
    await _save();
  }

  Future<void> delete(LinkItem item) async {
    _data.links.removeWhere((l) => l.id == item.id);
    _reindex();
    await _save();
  }

  Future<void> addTagToLibrary(String raw) async {
    final t = normalizeTag(raw);
    if (t == null) return;
    _data.tagLibrary.add(t);
    await _save();
  }

  Future<void> renameTag(String from, String toRaw) async {
    final to = normalizeTag(toRaw);
    if (to == null || to == from) return;
    _data.tagLibrary
      ..remove(from)
      ..add(to);
    for (final l in _data.links) {
      if (l.tags.remove(from)) l.tags.add(to);
    }
    await _save();
  }

  /// Removes the tag from the list and from every link.
  Future<void> deleteTag(String tag) async {
    _data.tagLibrary.remove(tag);
    for (final l in _data.links) {
      l.tags.remove(tag);
    }
    await _save();
  }

  // --- internals ---

  LinkItem _insert(IncomingLink inc, AddCheck c) {
    final tags = inc.tags.map(normalizeTag).whereType<String>().toSet();
    final item = LinkItem(
      id: _newId(),
      url: c.parsed!.original,
      addedAt: inc.addedAt,
      tags: tags,
      note: inc.note,
      possibleDuplicate: c.possible.isNotEmpty,
    );
    _data.links.add(item);
    _data.tagLibrary.addAll(tags);
    _index(item);
    return item;
  }

  void _mergeInto(LinkItem existing, IncomingLink inc) {
    final tags = inc.tags.map(normalizeTag).whereType<String>();
    existing.tags.addAll(tags);
    _data.tagLibrary.addAll(tags);
    if (inc.addedAt.isBefore(existing.addedAt)) {
      final i = _data.links.indexOf(existing);
      final replaced = LinkItem(
        id: existing.id,
        url: existing.url,
        addedAt: inc.addedAt,
        tags: existing.tags,
        note: existing.note ?? inc.note,
        possibleDuplicate: existing.possibleDuplicate,
      );
      _data.links[i] = replaced;
      _reindex();
    } else if (existing.note == null && inc.note != null) {
      existing.note = inc.note;
    }
  }

  void _reindex() {
    _byCanonical.clear();
    _bySegment.clear();
    for (final l in _data.links) {
      _index(l);
    }
  }

  void _index(LinkItem l) {
    _byCanonical.putIfAbsent(l.canonicalKey, () => l);
    final seg = l.lastSegment;
    if (seg != null) (_bySegment[seg] ??= []).add(l);
  }

  static final _rand = Random.secure();
  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_rand.nextInt(1 << 32).toRadixString(36)}';

  /// Saves are queued so two quick edits never write out of order.
  Future<void> _save() {
    notifyListeners();
    // A failed earlier save must not block later ones; its error was already
    // returned to whoever made that change.
    final next = _saving
        .catchError((Object _) {})
        .then((_) => _store.saveVault(_session, _data));
    _saving = next;
    return next;
  }
}
