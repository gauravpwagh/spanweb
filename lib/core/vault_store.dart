import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretBoxAuthenticationError;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'crypto.dart';
import 'models.dart';

/// Small key-value store for secrets. On a phone this is the Android
/// Keystore / iOS Keychain; tests use an in-memory map.
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceSecretStore implements SecretStore {
  static const _s = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device),
  );
  @override
  Future<String?> read(String key) => _s.read(key: key);
  @override
  Future<void> write(String key, String value) => _s.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _s.delete(key: key);
}

/// Keys held in memory while the app is unlocked. Dropped on lock.
class Session {
  Session._(this._dek, this._inboxSeed, this._inboxPublic);
  final Uint8List _dek;
  final Uint8List _inboxSeed;
  final Uint8List _inboxPublic;

  void wipe() {
    _dek.fillRange(0, _dek.length, 0);
    _inboxSeed.fillRange(0, _inboxSeed.length, 0);
  }
}

sealed class UnlockResult {}

class Unlocked extends UnlockResult {
  Unlocked(this.session);
  final Session session;
}

class WrongPin extends UnlockResult {
  WrongPin(this.failures, this.lockedUntil);
  final int failures;
  final DateTime? lockedUntil;
}

class LockedOut extends UnlockResult {
  LockedOut(this.until);
  final DateTime until;
}

/// One link shared into the app while it was locked.
class InboxEntry {
  InboxEntry(this.file, this.text, this.sharedAt);
  final File file;
  final String text;
  final DateTime sharedAt;
}

/// How the vault is laid out on disk:
///
/// * `keys.json`  - Argon2id salt and settings, the data key wrapped by the
///   PIN key, the inbox public key, and the inbox private key wrapped by the
///   data key.
/// * `vault.bin`  - all links and tags, AES-256-GCM with the data key.
/// * `inbox/*.bin`- links shared without login, each sealed to the inbox
///   public key. Writable without the PIN, readable only after unlocking.
///
/// The PIN key mixes Argon2id(PIN) with a random device secret kept in the
/// Keystore/Keychain, so copying the files off the phone is not enough to
/// guess the PIN offline.
class VaultStore {
  VaultStore({required this.dir, SecretStore? secrets, this.kdf = const KdfParams()})
      : secrets = secrets ?? DeviceSecretStore();

  final Directory dir;
  final SecretStore secrets;
  final KdfParams kdf;

  static const pinLength = 6;
  static const _freeAttempts = 5;
  static const _kDeviceSecret = 'device_secret';
  static const _kFailures = 'pin_failures';
  static const _kLockUntil = 'pin_lock_until';

  File get _keysFile => File('${dir.path}/keys.json');
  File get _vaultFile => File('${dir.path}/vault.bin');
  Directory get _inboxDir => Directory('${dir.path}/inbox');

  Future<bool> isSetUp() => _keysFile.exists();

  Future<Session> setup(String pin) async {
    _checkPin(pin);
    await dir.create(recursive: true);
    final deviceSecret = randomBytes(32);
    await secrets.write(_kDeviceSecret, base64Encode(deviceSecret));
    await _resetFailures();

    final salt = randomBytes(16);
    final kek = await _pinKey(pin, salt, kdf, deviceSecret);
    final dek = randomBytes(32);
    final (seed, pub) = await newInboxKeyPair();

    await _writeKeys(
      salt: salt,
      params: kdf,
      wrappedDek: await seal(kek, dek, aad: 'dek'),
      inboxPublic: pub,
      wrappedInbox: await seal(dek, seed, aad: 'inbox-key'),
    );
    final session = Session._(dek, seed, pub);
    await saveVault(session, VaultData());
    return session;
  }

  Future<DateTime?> lockedUntil() async {
    final v = await secrets.read(_kLockUntil);
    if (v == null) return null;
    final t = DateTime.fromMillisecondsSinceEpoch(int.parse(v));
    return t.isAfter(DateTime.now()) ? t : null;
  }

  Future<UnlockResult> unlock(String pin) async {
    final until = await lockedUntil();
    if (until != null) return LockedOut(until);

    final keys = await _readKeys();
    final kdfJson = (keys['kdf'] as Map).cast<String, Object?>();
    final deviceSecret = base64Decode(await secrets.read(_kDeviceSecret) ?? '');
    final kek = await _pinKey(
      pin,
      base64Decode(kdfJson['salt'] as String),
      KdfParams.fromJson(kdfJson),
      deviceSecret,
    );
    final Uint8List dek;
    try {
      dek = await open(kek, (keys['dek'] as Map).cast(), aad: 'dek');
    } on SecretBoxAuthenticationError {
      return _recordFailure();
    }
    await _resetFailures();
    final seed = await open(dek, (keys['inboxKey'] as Map).cast(), aad: 'inbox-key');
    return Unlocked(Session._(dek, seed, base64Decode(keys['inboxPub'] as String)));
  }

  /// Re-wraps the data key under a new PIN. The links are not re-encrypted.
  Future<void> changePin(Session s, String newPin) async {
    _checkPin(newPin);
    final keys = await _readKeys();
    final deviceSecret = base64Decode(await secrets.read(_kDeviceSecret) ?? '');
    final salt = randomBytes(16);
    final kek = await _pinKey(newPin, salt, kdf, deviceSecret);
    await _writeKeys(
      salt: salt,
      params: kdf,
      wrappedDek: await seal(kek, s._dek, aad: 'dek'),
      inboxPublic: base64Decode(keys['inboxPub'] as String),
      wrappedInbox: (keys['inboxKey'] as Map).cast(),
    );
  }

  Future<VaultData> loadVault(Session s) async {
    final sealed = jsonDecode(await _vaultFile.readAsString()) as Map<String, Object?>;
    final plain = await open(s._dek, sealed, aad: 'vault');
    return VaultData.fromJson(jsonDecode(utf8.decode(plain)) as Map<String, Object?>);
  }

  Future<void> saveVault(Session s, VaultData data) async {
    final plain = utf8.encode(jsonEncode(data.toJson()));
    final sealed = await seal(s._dek, plain, aad: 'vault');
    await _atomicWrite(_vaultFile, jsonEncode(sealed));
  }

  /// Saves shared text without the PIN. Nothing written here can be read back
  /// until the vault is unlocked.
  Future<void> addToInbox(String text) async {
    final keys = await _readKeys();
    final pub = base64Decode(keys['inboxPub'] as String);
    final payload = utf8.encode(jsonEncode({
      'text': text,
      'sharedAt': DateTime.now().toUtc().toIso8601String(),
    }));
    final sealed = await sealToPublicKey(pub, payload);
    await _inboxDir.create(recursive: true);
    final name = '${DateTime.now().microsecondsSinceEpoch}-'
        '${base64Url.encode(randomBytes(6))}.bin';
    await _atomicWrite(File('${_inboxDir.path}/$name'), jsonEncode(sealed));
  }

  Future<int> inboxCount() async {
    if (!await _inboxDir.exists()) return 0;
    return _inboxDir.list().where((e) => e.path.endsWith('.bin')).length;
  }

  /// Decrypts the inbox. Files that fail to decrypt are skipped and left in
  /// place rather than deleted.
  Future<List<InboxEntry>> readInbox(Session s) async {
    if (!await _inboxDir.exists()) return [];
    final out = <InboxEntry>[];
    final files = await _inboxDir
        .list()
        .where((e) => e is File && e.path.endsWith('.bin'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    for (final f in files) {
      try {
        final sealed = jsonDecode(await f.readAsString()) as Map<String, Object?>;
        final plain = await openFromPublicKey(s._inboxSeed, s._inboxPublic, sealed);
        final j = jsonDecode(utf8.decode(plain)) as Map<String, Object?>;
        out.add(InboxEntry(
          f,
          j['text'] as String,
          DateTime.parse(j['sharedAt'] as String).toLocal(),
        ));
      } catch (_) {
        continue;
      }
    }
    return out;
  }

  /// Deletes everything: used when the PIN is forgotten.
  Future<void> erase() async {
    if (await dir.exists()) await dir.delete(recursive: true);
    await secrets.delete(_kDeviceSecret);
    await _resetFailures();
  }

  // --- internals ---

  void _checkPin(String pin) {
    if (pin.length != pinLength || !RegExp(r'^\d+$').hasMatch(pin)) {
      throw ArgumentError('PIN must be $pinLength digits');
    }
  }

  Future<Uint8List> _pinKey(String pin, List<int> salt, KdfParams p, List<int> deviceSecret) async {
    final stretched = await argon2id(pin, salt, p);
    return hkdf([...stretched, ...deviceSecret], salt: salt, info: 'linkvault-kek-v1');
  }

  Future<UnlockResult> _recordFailure() async {
    final failures = int.parse(await secrets.read(_kFailures) ?? '0') + 1;
    await secrets.write(_kFailures, '$failures');
    DateTime? until;
    if (failures >= _freeAttempts) {
      until = DateTime.now().add(lockoutFor(failures));
      await secrets.write(_kLockUntil, '${until.millisecondsSinceEpoch}');
    }
    return WrongPin(failures, until);
  }

  /// 30 s after the 5th wrong PIN, doubling each time, at most 1 hour.
  static Duration lockoutFor(int failures) {
    if (failures < _freeAttempts) return Duration.zero;
    final steps = (failures - _freeAttempts).clamp(0, 7);
    final secs = 30 * (1 << steps);
    return Duration(seconds: secs > 3600 ? 3600 : secs);
  }

  Future<void> _resetFailures() async {
    await secrets.delete(_kFailures);
    await secrets.delete(_kLockUntil);
  }

  Future<Map<String, Object?>> _readKeys() async =>
      jsonDecode(await _keysFile.readAsString()) as Map<String, Object?>;

  Future<void> _writeKeys({
    required List<int> salt,
    required KdfParams params,
    required Map<String, Object?> wrappedDek,
    required List<int> inboxPublic,
    required Map<String, Object?> wrappedInbox,
  }) =>
      _atomicWrite(
        _keysFile,
        jsonEncode({
          'v': 1,
          'kdf': {...params.toJson(), 'salt': base64Encode(salt)},
          'dek': wrappedDek,
          'inboxPub': base64Encode(inboxPublic),
          'inboxKey': wrappedInbox,
        }),
      );

  Future<void> _atomicWrite(File f, String contents) async {
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(contents, flush: true);
    await tmp.rename(f.path);
  }
}
