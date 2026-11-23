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

/// What [LinkRepository.changeDomain] did.
class DomainChange {
  DomainChange(this.from, this.to);
  final String from;
  final String to;
  int moved = 0;
  int merged = 0;

  /// Links in the group whose host isn't the domain itself, such as `youtu.be`
  /// in the `youtube.com` group. They are left as they were.
  int skipped = 0;

  @override
  String toString() {
    final parts = ['$moved changed to $to'];
    if (merged > 0) parts.add('$merged merged with links already saved');
    if (skipped > 0) parts.add('$skipped left as they were');
    return parts.join(', ');
  }
}

/// One link to merge in bulk.
class IncomingLink {
  IncomingLink(this.url, {DateTime? addedAt, Set<String>? tags, this.note, this.title})
      : addedAt = addedAt ?? DateTime.now(),
        tags = tags ?? {};
  final String url;
  final DateTime addedAt;
  final Set<String> tags;
  final String? note;
  final String? title;
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
  final Map<String, List<LinkItem>> _byPath = {};
  Future<void> _saving = Future.value();
  bool _closed = false;

  /// Called with links that were just added. [bulk] is true for imports,
  /// which must ask before fetching anything.
  void Function(List<LinkItem> added, {required bool bulk})? onAdded;

  bool get isClosed => _closed;

  /// Stops further saves and completes when the last pending save has
  /// finished, so the caller can then wipe the keys safely.
  Future<void> close() {
    _closed = true;
    onAdded = null;
    return _saving.catchError((Object _) {});
  }

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
          !(l.title?.toLowerCase().contains(q) ?? false) &&
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
    final parsed = parseLink(_applyMoves(url));
    if (parsed == null) return AddCheck(null, null, const []);
    final exact = _byCanonical[parsed.canonicalKey];
    final possible = exact != null
        ? const <LinkItem>[]
        : _similar(parsed.lastSegment, parsed.pathKey, null);
    return AddCheck(parsed, exact, possible);
  }

  /// Other saved links that share this link's last part, or everything
  /// after the domain.
  List<LinkItem> similarTo(LinkItem item) => _similar(item.lastSegment, item.pathKey, item.id);

  List<LinkItem> _similar(String? segment, String? pathKey, String? exceptId) {
    final seen = <String>{?exceptId};
    return [
      for (final l in [...?_bySegment[segment], ...?_byPath[pathKey]])
        if (seen.add(l.id)) l,
    ];
  }

  /// Adds a link that passed [check]. Call only when there is no exact
  /// duplicate; possible duplicates are saved with a flag for review.
  Future<LinkItem> add(String url,
      {Set<String> tags = const {}, String? note, String? title, DateTime? addedAt}) async {
    final c = check(url);
    if (c.invalid) throw ArgumentError('Not a valid link');
    if (c.exact != null) throw StateError('Already saved');
    final item =
        _insert(IncomingLink(url, addedAt: addedAt, tags: tags, note: note, title: title), c);
    await _save();
    onAdded?.call([item], bulk: false);
    return item;
  }

  /// Adds many links at once: exact duplicates are merged into the existing
  /// link (tags combined, earliest date kept), possible duplicates flagged.
  Future<MergeReport> merge(Iterable<IncomingLink> incoming, {bool bulk = false}) async {
    final r = MergeReport();
    final added = <LinkItem>[];
    for (final inc in incoming) {
      final c = check(inc.url);
      if (c.invalid) {
        r.invalid++;
      } else if (c.exact != null) {
        r.exactDuplicates++;
        _mergeInto(c.exact!, inc);
      } else {
        final item = _insert(inc, c);
        added.add(item);
        r.added++;
        if (item.possibleDuplicate) r.possibleDuplicates++;
      }
    }
    if (r.total > 0) await _save();
    if (added.isNotEmpty) onAdded?.call(added, bulk: bulk);
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
      // A title belongs to the link only when the share held just one.
      final title = urls.length == 1 ? cleanTitle(e.title) : null;
      for (final u in urls) {
        incoming.add(IncomingLink(u, addedAt: e.sharedAt, title: title));
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

  Future<void> setTitle(LinkItem item, String? title) async {
    item.title = cleanTitle(title);
    await _save();
  }

  /// The saved link with this canonical key, if any.
  LinkItem? byCanonicalKey(String key) => _byCanonical[key];

  /// Websites that moved, old group -> new domain.
  Map<String, String> get domainMoves => Map.unmodifiable(_data.domainMoves);

  /// Changes every link in [group] to [newDomain], keeping subdomains, path
  /// and query as they were. Links that become the same as one already saved
  /// are merged into it. With [remember], links saved or imported later from
  /// the old domain are changed too.
  Future<DomainChange> changeDomain(String group, String newDomain, {bool remember = true}) async {
    final to = newDomain.toLowerCase();
    final result = DomainChange(group, to);
    if (groupForHost(to) == group && to == group) return result;
    final moving = <LinkItem>[];
    for (final l in _data.links.where((l) => l.group == group).toList()) {
      final url = moveUrlDomain(l.url, group, to);
      if (url == null || parseLink(url) == null) {
        result.skipped++;
        continue;
      }
      moving.add(LinkItem(
        id: l.id,
        url: url,
        addedAt: l.addedAt,
        tags: l.tags,
        title: l.title,
        note: l.note,
        possibleDuplicate: l.possibleDuplicate,
      ));
      _data.links.remove(l);
    }
    _reindex();
    for (final m in moving) {
      final existing = _byCanonical[m.canonicalKey];
      if (existing != null) {
        _mergeInto(existing, IncomingLink(m.url,
            addedAt: m.addedAt, tags: m.tags, note: m.note, title: m.title));
        result.merged++;
      } else {
        _data.links.add(m);
        _index(m);
        result.moved++;
      }
    }
    if (remember) _rememberMove(group, to);
    await _save();
    return result;
  }

  /// Stops changing links from [oldGroup] automatically.
  Future<void> forgetDomainMove(String oldGroup) async {
    if (_data.domainMoves.remove(oldGroup) != null) await _save();
  }

  void _rememberMove(String from, String to) {
    final toGroup = groupForHost(to);
    final moves = _data.domainMoves;
    // Earlier moves that led to the old domain now lead to the new one.
    for (final k in moves.keys.toList()) {
      if (groupForHost(moves[k]!) == from) moves[k] = to;
    }
    moves[from] = to;
    // The new domain is in use again, so it must not be moved away.
    moves.remove(toGroup);
    moves.removeWhere((k, v) => groupForHost(v) == k);
  }

  String _applyMoves(String url) {
    if (_data.domainMoves.isEmpty) return url;
    final p = parseLink(url);
    final to = p == null ? null : _data.domainMoves[p.group];
    if (to == null) return url;
    return moveUrlDomain(p!.original, p.group, to) ?? url;
  }

  Future<void> clearPossibleDuplicate(LinkItem item) async {
    item.possibleDuplicate = false;
    await _save();
  }

  Future<void> delete(LinkItem item) async {
    _data.links.removeWhere((l) => l.id == item.id);
    _reindex();
    if (_data.thumbs.remove(item.canonicalKey) != null) {
      await _store.deleteThumb(_session, item.canonicalKey);
    }
    await _save();
  }

  // --- thumbnails ---

  ThumbSettings get thumbSettings => _data.thumbSettings;

  /// Whether link lists are shown as a grid of large images.
  bool get gridView => _data.gridView;

  Future<void> setGridView(bool on) {
    if (_data.gridView == on) return Future.value();
    _data.gridView = on;
    return _save();
  }

  Future<void> updateThumbSettings(void Function(ThumbSettings s) change) {
    change(_data.thumbSettings);
    return _save();
  }

  ThumbStatus? thumbStatus(String canonicalKey) => _data.thumbs[canonicalKey];

  Future<Uint8List?> loadThumb(String canonicalKey) =>
      _closed ? Future.value(null) : _store.loadThumb(_session, canonicalKey);

  /// Stores a thumbnail (or records a failure, with [jpeg] null).
  Future<void> putThumb(String canonicalKey, Uint8List? jpeg) async {
    if (_closed) return;
    if (jpeg != null) await _store.saveThumb(_session, canonicalKey, jpeg);
    if (_closed) return;
    _data.thumbs[canonicalKey] = jpeg == null ? ThumbStatus.failed : ThumbStatus.ok;
    await _save();
  }

  /// Forgets failures, so those links can be tried again.
  Future<void> clearThumbFailures() {
    _data.thumbs.removeWhere((_, s) => s == ThumbStatus.failed);
    return _save();
  }

  Future<void> deleteAllThumbs() async {
    _data.thumbs.clear();
    await _store.deleteAllThumbs();
    await _save();
  }

  /// Removes thumbnail files and records left behind by deleted links.
  Future<void> pruneThumbs() async {
    final live = {for (final l in _data.links) l.canonicalKey};
    final before = _data.thumbs.length;
    _data.thumbs.removeWhere((k, _) => !live.contains(k));
    await _store.pruneThumbs(
      _session,
      _data.thumbs.entries.where((e) => e.value == ThumbStatus.ok).map((e) => e.key),
    );
    if (_data.thumbs.length != before) await _save();
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
      title: cleanTitle(inc.title),
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
    existing.title ??= cleanTitle(inc.title);
    if (inc.addedAt.isBefore(existing.addedAt)) {
      final i = _data.links.indexOf(existing);
      final replaced = LinkItem(
        id: existing.id,
        url: existing.url,
        addedAt: inc.addedAt,
        tags: existing.tags,
        title: existing.title,
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
    _byPath.clear();
    for (final l in _data.links) {
      _index(l);
    }
  }

  void _index(LinkItem l) {
    _byCanonical.putIfAbsent(l.canonicalKey, () => l);
    final seg = l.lastSegment;
    if (seg != null) (_bySegment[seg] ??= []).add(l);
    final path = l.pathKey;
    if (path != null) (_byPath[path] ??= []).add(l);
  }

  static final _rand = Random.secure();
  String _newId() =>
      '${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}'
      '${_rand.nextInt(1 << 32).toRadixString(36)}';

  /// Saves are queued so two quick edits never write out of order.
  Future<void> _save() {
    // After locking the keys are being wiped: never write with them.
    if (_closed) return Future.value();
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
