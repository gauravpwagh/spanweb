import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;

import '../core/link_repository.dart';
import '../core/models.dart';
import 'safe_fetch.dart';
import 'sanitize.dart';
import 'thumb_source.dart';

/// Thumbnails exist only in the preview edition (internal testing). The
/// store edition has no INTERNET permission and never creates this service.
bool get thumbnailsAvailable => appFlavor == 'preview';

typedef ImageFetcher = Future<Uint8List> Function(Uri url);

Future<Uint8List> _defaultFetch(Uri url) =>
    safeFetchImage(url, const FetchPolicy(allowedHosts: thumbHosts));

/// Loads, stores and serves thumbnails while the vault is unlocked. Created
/// on unlock, closed on lock: nothing is fetched or kept in memory while
/// locked.
class ThumbService extends ChangeNotifier {
  ThumbService(
    this.repo, {
    ImageFetcher? fetch,
    Duration Function()? pause,
  })  : _fetch = fetch ?? _defaultFetch,
        _pause = pause ?? _randomPause {
    repo.onAdded = _onAdded;
    unawaited(repo.pruneThumbs());
  }

  final LinkRepository repo;
  final ImageFetcher _fetch;
  final Duration Function() _pause;

  final Map<String, Uint8List> _cache = {};
  final Set<String> _diskLoading = {};
  final Queue<String> _queue = Queue();
  final Set<String> _queued = {};
  String? _current;
  bool _running = false;
  bool _closed = false;
  List<LinkItem> _bulkAdded = const [];

  static final _rng = Random.secure();

  /// 1 to 3 s between downloads, so a long list isn't requested in a burst.
  static Duration _randomPause() => Duration(milliseconds: 1000 + _rng.nextInt(2000));

  ThumbSettings get settings => repo.thumbSettings;

  /// Whether the user's settings allow a thumbnail for this link at all.
  bool allowed(LinkItem l) {
    if (!settings.enabled) return false;
    final r = thumbRequestFor(l.canonicalKey);
    return r != null && settings.sites.contains(r.site);
  }

  /// The decrypted thumbnail, if stored. Loads it from disk in the
  /// background the first time and notifies when ready.
  Uint8List? imageFor(LinkItem l) {
    if (!settings.enabled) return null;
    final key = l.canonicalKey;
    final hit = _cache[key];
    if (hit != null) return hit;
    if (repo.thumbStatus(key) == ThumbStatus.ok && _diskLoading.add(key)) {
      repo.loadThumb(key).then((bytes) {
        _diskLoading.remove(key);
        if (_closed || bytes == null) return;
        _cache[key] = bytes;
        notifyListeners();
      });
    }
    return null;
  }

  bool isLoading(LinkItem l) => _queued.contains(l.canonicalKey) || _current == l.canonicalKey;

  ThumbStatus? status(LinkItem l) => repo.thumbStatus(l.canonicalKey);

  /// Links in [links] that are allowed and have nothing stored or queued.
  List<LinkItem> missing(Iterable<LinkItem> links) => [
        for (final l in links)
          if (allowed(l) && status(l) == null && !isLoading(l)) l,
      ];

  /// Queues downloads. [first] puts them ahead of the queue (a tap on
  /// "Load thumbnail").
  void request(Iterable<LinkItem> links, {bool first = false}) {
    if (_closed) return;
    final keys = [
      for (final l in links)
        if (allowed(l) && status(l) != ThumbStatus.ok && _queued.add(l.canonicalKey)) l.canonicalKey,
    ];
    if (keys.isEmpty) return;
    if (first) {
      for (final k in keys.reversed) {
        _queue.addFirst(k);
      }
    } else {
      _queue.addAll(keys);
    }
    notifyListeners();
    unawaited(_pump());
  }

  /// Links added by the last import, for the "Load N thumbnails?" question.
  List<LinkItem> takeBulkAdded() {
    final out = missing(_bulkAdded);
    _bulkAdded = const [];
    return out;
  }

  void _onAdded(List<LinkItem> added, {required bool bulk}) {
    if (bulk) {
      _bulkAdded = added;
    } else if (settings.enabled && settings.automatic) {
      request(added);
    }
  }

  /// Stops the queue and forgets everything not on disk, e.g. when switched off.
  void cancelAll() {
    _queue.clear();
    _queued.clear();
    notifyListeners();
  }

  void clearMemory() {
    _cache.clear();
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_queue.isNotEmpty && !_closed) {
        final key = _queue.removeFirst();
        _current = key;
        _queued.remove(key);
        notifyListeners();
        final req = thumbRequestFor(key);
        Uint8List? jpeg;
        if (req != null && settings.enabled && settings.sites.contains(req.site)) {
          try {
            jpeg = await sanitizeThumbnail(await _fetch(req.url));
          } on Object {
            jpeg = null;
          }
          if (_closed) break; // locked while downloading: store nothing
          if (jpeg != null) _cache[key] = jpeg;
          await repo.putThumb(key, jpeg);
        }
        _current = null;
        notifyListeners();
        if (_queue.isNotEmpty && !_closed) await Future<void>.delayed(_pause());
      }
    } finally {
      _current = null;
      _running = false;
    }
  }

  /// Called on lock: stop, and drop decrypted images from memory.
  void close() {
    _closed = true;
    _queue.clear();
    _queued.clear();
    _cache.clear();
    _bulkAdded = const [];
  }

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    close();
    _disposed = true;
    super.dispose();
  }
}
