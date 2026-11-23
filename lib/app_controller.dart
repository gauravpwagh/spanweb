import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:share_handler/share_handler.dart';

import 'core/link_repository.dart';
import 'core/url_tools.dart';
import 'core/vault_store.dart';
import 'thumbs/thumb_service.dart';

enum Stage { loading, needsSetup, locked, unlocked }

/// App-wide state: locked or not, links shared from other apps, and the
/// open vault while unlocked.
class AppController extends ChangeNotifier with WidgetsBindingObserver {
  AppController(this.store);

  final VaultStore store;
  Stage stage = Stage.loading;
  LinkRepository? repo;
  Session? _session;

  /// Video thumbnails, preview edition only. Null in the store edition.
  ThumbService? thumbs;

  /// Creates the thumbnail service on unlock; tests replace it.
  ThumbService Function(LinkRepository repo)? thumbFactory =
      thumbnailsAvailable ? ThumbService.new : null;

  /// Text shared from other apps, waiting to be saved to the inbox.
  final List<String> pendingShares = [];

  /// Page titles that came with [pendingShares], by shared text.
  final Map<String, String> shareTitles = {};

  /// Asks the Android side for the subject sent with a share; tests replace it.
  Future<String?> Function(String text) shareSubject = _platformShareSubject;

  static const _shareChannel = MethodChannel('linkvault/share');

  static Future<String?> _platformShareSubject(String text) async {
    try {
      return await _shareChannel.invokeMethod<String>('takeTitle', text);
    } on MissingPluginException {
      return null; // iOS, tests and desktop: no subject channel.
    } on PlatformException {
      return null;
    }
  }

  /// Shown once after unlocking, when shared links were merged in.
  MergeReport? inboxReport;

  /// True while the app is not in front: the screen is covered so the app
  /// switcher thumbnail shows nothing.
  bool obscured = false;

  int _noAutoLock = 0;
  StreamSubscription<SharedMedia>? _shareSub;

  Future<void> init() async {
    WidgetsBinding.instance.addObserver(this);
    stage = await store.isSetUp() ? Stage.locked : Stage.needsSetup;
    notifyListeners();
    try {
      final handler = ShareHandler.instance;
      final initial = await handler.getInitialSharedMedia();
      if (initial != null) {
        _onShared(initial);
        await handler.resetInitialSharedMedia();
      }
      _shareSub = handler.sharedMediaStream.listen(_onShared);
    } on Exception {
      // No share plugin on this platform (tests, desktop).
    }
  }

  void _onShared(SharedMedia media) {
    final text = media.content?.trim();
    if (text == null || text.isEmpty) return;
    // A share always comes from another app, so the user was away: lock,
    // even if the background event was missed. Opening the app after a share
    // must always ask for the PIN.
    lock();
    pendingShares.add(text);
    quickSaveOpen = true;
    notifyListeners();
    _findTitle(media.content!, text);
  }

  Future<void> _findTitle(String raw, String text) async {
    String? subject;
    try {
      subject = await shareSubject(raw.trim());
    } on Object {
      subject = null;
    }
    final title = sharedTitle(text, subject: subject);
    if (title == null || !pendingShares.contains(text)) return;
    shareTitles[text] = title;
    notifyListeners();
  }

  /// The share screen stays up until the user leaves it, even once every
  /// pending share has been saved or discarded.
  bool quickSaveOpen = false;

  void closeQuickSave() {
    quickSaveOpen = false;
    pendingShares.clear();
    shareTitles.clear();
    notifyListeners();
  }

  /// A link was shared before any PIN was chosen, so there is nowhere to
  /// save it yet. Go to PIN setup and keep the shares; [setup] saves them.
  void setUpFirst() {
    quickSaveOpen = false;
    notifyListeners();
  }

  // --- PIN ---

  Future<void> setup(String pin) async {
    _open(await store.setup(pin));
    await _finishUnlock();
    // Links shared before the PIN existed go straight into the new vault.
    final r = repo;
    if (r == null || pendingShares.isEmpty) return;
    final incoming = <IncomingLink>[];
    for (final text in pendingShares) {
      final urls = extractUrls(text);
      final title = urls.length == 1 ? (shareTitles[text] ?? sharedTitle(text)) : null;
      incoming.addAll(urls.map((u) => IncomingLink(u, title: title)));
    }
    pendingShares.clear();
    shareTitles.clear();
    inboxReport = await r.merge(incoming);
    notifyListeners();
  }

  Future<UnlockResult> unlock(String pin) async {
    final r = await store.unlock(pin);
    if (r is Unlocked) {
      _open(r.session);
      await _finishUnlock();
    }
    return r;
  }

  void _open(Session s) => _session = s;

  Future<void> _finishUnlock() async {
    final r = await LinkRepository.open(store, _session!);
    repo = r;
    thumbs = thumbFactory?.call(r);
    stage = Stage.unlocked;
    notifyListeners();
    inboxReport = await r.ingestInbox();
    notifyListeners();
  }

  void lock() {
    if (stage != Stage.unlocked) return;
    thumbs?.dispose();
    thumbs = null;
    final r = repo;
    final s = _session;
    repo = null;
    _session = null;
    // Wipe the keys only after the last save has finished; wiping mid-save
    // would encrypt the vault with a zeroed key.
    if (r == null) {
      s?.wipe();
    } else {
      r.close().whenComplete(() {
        s?.wipe();
        r.dispose();
      });
    }
    inboxReport = null;
    stage = Stage.locked;
    notifyListeners();
  }

  Future<void> changePin(String newPin) => store.changePin(_session!, newPin);

  Future<void> eraseEverything() async {
    lock();
    await store.erase();
    pendingShares.clear();
    shareTitles.clear();
    stage = Stage.needsSetup;
    notifyListeners();
  }

  // --- sharing without login ---

  Future<void> saveShared(String text) async {
    // Always via the encrypted inbox; it is merged at the next unlock.
    await store.addToInbox(text, title: shareTitles.remove(text) ?? sharedTitle(text));
    pendingShares.remove(text);
    notifyListeners();
  }

  void discardShared(String text) {
    pendingShares.remove(text);
    shareTitles.remove(text);
    notifyListeners();
  }

  // --- auto-lock ---

  /// File pickers send the app to the background; don't lock for those.
  Future<T> withoutAutoLock<T>(Future<T> Function() action) async {
    _noAutoLock++;
    try {
      return await action();
    } finally {
      // The resume event arrives just after the picker returns.
      Future.delayed(const Duration(milliseconds: 800), () => _noAutoLock--);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final hidden = state != AppLifecycleState.resumed;
    if (hidden != obscured && _noAutoLock == 0) {
      obscured = hidden;
      notifyListeners();
    }
    if ((state == AppLifecycleState.hidden ||
            state == AppLifecycleState.paused ||
            state == AppLifecycleState.detached) &&
        _noAutoLock == 0) {
      lock();
    }
    if (state == AppLifecycleState.resumed && obscured) {
      obscured = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareSub?.cancel();
    thumbs?.dispose();
    repo?.dispose();
    super.dispose();
  }
}
