import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;

import '../core/link_repository.dart';
import '../core/models.dart';
import 'link_info.dart';
import 'safe_fetch.dart';
import 'sanitize.dart';
import 'thumb_source.dart';

/// Thumbnails exist only in the preview edition (internal testing). The
/// store edition has no INTERNET permission and never creates this service.
bool get thumbnailsAvailable => appFlavor == 'preview';

typedef ImageFetcher = Future<Uint8List> Function(Uri url);

/// Downloads an oEmbed reply.
typedef InfoFetcher = Future<String> Function(Uri url);

/// Downloads the start of a web page, allowing redirects only within [hosts].
typedef PageFetcher = Future<String> Function(Uri url, Set<String> hosts);

Future<Uint8List> _defaultFetch(Uri url) =>
    safeFetchImage(url, const FetchPolicy(allowedHosts: thumbHosts));

Future<String> _defaultInfo(Uri url) => safeFetchText(
      url,
      const FetchPolicy(allowedHosts: oembedHosts, maxBytes: 64 * 1024),
      types: const {'application/json', 'text/json'},
    );

Future<String> _defaultPage(Uri url, Set<String> hosts) => safeFetchText(
      url,
      FetchPolicy(allowedHosts: hosts, maxBytes: 256 * 1024, maxRedirects: 3),
      types: const {'text/html', 'application/xhtml+xml'},
      truncate: true,
    );

/// Loads, stores and serves thumbnails while the vault is unlocked. Created
/// on unlock, closed on lock: nothing is fetched or kept in memory while
/// locked.
class ThumbService extends ChangeNotifier {
  ThumbService(
    this.repo, {
    ImageFetcher? fetch,
    InfoFetcher? info,
    PageFetcher? page,
    Duration Function()? pause,
  })  : _fetch = fetch ?? _defaultFetch,
        _info = info ?? _defaultInfo,
        _page = page ?? _defaultPage,
        _pause = pause ?? _randomPause {
    repo.onAdded = _onAdded;
    unawaited(repo.pruneThumbs());
  }

  final LinkRepository repo;
  final ImageFetcher _fetch;
  final InfoFetcher _info;
  final PageFetcher _page;
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
    final r = videoSourceFor(l.canonicalKey);
    return r != null && settings.sites.contains(r.site);
  }

  final Set<String> _pageLoading = {};

  bool isFetchingPageTitle(LinkItem l) => _pageLoading.contains(l.id);

  /// Asks the link's own website for its title, once, because the user
  /// tapped for it. Reads only the start of the page and only its title.
  /// Returns the title stored, or null if none was found.
  Future<String?> fetchPageTitle(LinkItem l) async {
    final req = pageRequestFor(l.url);
    if (req == null || _closed || !_pageLoading.add(l.id)) return null;
    notifyListeners();
    String? title;
    try {
      title = pageTitleFromHtml(await _page(req.url, req.hosts));
    } on Object {
      title = null;
    } finally {
      _pageLoading.remove(l.id);
    }
    if (_closed) return null;
    if (title != null) await repo.setTitle(l, title);
    notifyListeners();
    return title;
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
        final src = videoSourceFor(key);
        if (src != null && settings.enabled && settings.sites.contains(src.site)) {
          final (title, jpeg) = await _load(src);
          if (_closed) break; // locked while downloading: store nothing
          final link = repo.byCanonicalKey(key);
          // Never replaces a title the link already has.
          if (title != null && link != null && link.title == null) await repo.setTitle(link, title);
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

  /// The title from the site's oEmbed reply and the cleaned thumbnail.
  /// Either may be null; a failure of one doesn't stop the other.
  Future<(String?, Uint8List?)> _load(VideoSource src) async {
    String? title;
    var thumb = src.directThumb;
    try {
      final info = parseOEmbed(await _info(src.oembed), src);
      title = info.title;
      thumb ??= info.thumb;
    } on Object {
      title = null;
    }
    if (_closed || thumb == null || !hostAllowed(thumb.host, src.imageHosts)) return (title, null);
    try {
      return (title, await sanitizeThumbnail(await _fetch(thumb)));
    } on Object {
      return (title, null);
    }
  }

  /// Called on lock: stop, and drop decrypted images from memory.
  void close() {
    _closed = true;
    _queue.clear();
    _queued.clear();
    _cache.clear();
    _pageLoading.clear();
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
