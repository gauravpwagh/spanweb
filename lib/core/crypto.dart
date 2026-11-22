import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// Crypto building blocks. All primitives come from package:cryptography:
/// Argon2id for PIN/password stretching, AES-256-GCM for encryption,
/// X25519 + HKDF-SHA256 for the write-only share inbox.

final _rng = Random.secure();
final _aes = AesGcm.with256bits();
final _x25519 = X25519();

Uint8List randomBytes(int n) =>
    Uint8List.fromList(List<int>.generate(n, (_) => _rng.nextInt(256)));

/// Argon2id settings (OWASP minimum: 19 MiB, 2 passes). Stored with the
/// data, so they can be raised later without breaking old vaults.
class KdfParams {
  const KdfParams({this.memoryKiB = 19456, this.iterations = 2, this.parallelism = 1});
  final int memoryKiB;
  final int iterations;
  final int parallelism;

  Map<String, Object?> toJson() =>
      {'alg': 'argon2id', 'm': memoryKiB, 't': iterations, 'p': parallelism};

  factory KdfParams.fromJson(Map<String, Object?> j) {
    if (j['alg'] != 'argon2id') throw const FormatException('Unknown KDF');
    return KdfParams(
      memoryKiB: j['m'] as int,
      iterations: j['t'] as int,
      parallelism: j['p'] as int,
    );
  }
}

/// Stretches a PIN or password into 32 bytes. Runs in a background isolate
/// because Argon2id is deliberately slow.
Future<Uint8List> argon2id(String secret, List<int> salt, KdfParams p) {
  final secretBytes = utf8.encode(secret);
  final saltCopy = List<int>.of(salt);
  return Isolate.run(() async {
    final algo = Argon2id(
      memory: p.memoryKiB,
      iterations: p.iterations,
      parallelism: p.parallelism,
      hashLength: 32,
    );
    final key = await algo.deriveKey(secretKey: SecretKey(secretBytes), nonce: saltCopy);
    return Uint8List.fromList(await key.extractBytes());
  });
}

Future<Uint8List> hkdf(List<int> ikm, {required List<int> salt, required String info}) async {
  final algo = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  final key = await algo.deriveKey(
    secretKey: SecretKey(ikm),
    nonce: salt,
    info: utf8.encode(info),
  );
  return Uint8List.fromList(await key.extractBytes());
}

/// AES-256-GCM. [aad] binds the ciphertext to its purpose, so a blob from
/// one place cannot be swapped into another.
Future<Map<String, String>> seal(List<int> key, List<int> plain, {String aad = ''}) async {
  final box = await _aes.encrypt(
    plain,
    secretKey: SecretKey(key),
    aad: utf8.encode(aad),
  );
  return {
    'nonce': base64Encode(box.nonce),
    'ct': base64Encode(box.cipherText),
    'mac': base64Encode(box.mac.bytes),
  };
}

/// Throws [SecretBoxAuthenticationError] if the key is wrong or the data
/// was changed.
Future<Uint8List> open(List<int> key, Map<String, Object?> sealed, {String aad = ''}) async {
  final box = SecretBox(
    base64Decode(sealed['ct'] as String),
    nonce: base64Decode(sealed['nonce'] as String),
    mac: Mac(base64Decode(sealed['mac'] as String)),
  );
  final plain = await _aes.decrypt(box, secretKey: SecretKey(key), aad: utf8.encode(aad));
  return Uint8List.fromList(plain);
}

/// A new X25519 key pair as (privateSeed, publicKey).
Future<(Uint8List, Uint8List)> newInboxKeyPair() async {
  final kp = await _x25519.newKeyPair();
  final seed = await kp.extractPrivateKeyBytes();
  final pub = await kp.extractPublicKey();
  return (Uint8List.fromList(seed), Uint8List.fromList(pub.bytes));
}

const _inboxInfo = 'linkvault-inbox-v1';

/// Encrypts [plain] so that only the holder of the inbox private key can read
/// it. The sender keeps nothing that could decrypt it again.
Future<Map<String, String>> sealToPublicKey(List<int> recipientPublic, List<int> plain) async {
  final eph = await _x25519.newKeyPair();
  final ephPub = (await eph.extractPublicKey()).bytes;
  final shared = await _x25519.sharedSecretKey(
    keyPair: eph,
    remotePublicKey: SimplePublicKey(recipientPublic, type: KeyPairType.x25519),
  );
  final key = await hkdf(
    await shared.extractBytes(),
    salt: [...ephPub, ...recipientPublic],
    info: _inboxInfo,
  );
  return {'epk': base64Encode(ephPub), ...await seal(key, plain, aad: _inboxInfo)};
}

Future<Uint8List> openFromPublicKey(
  List<int> recipientSeed,
  List<int> recipientPublic,
  Map<String, Object?> sealed,
) async {
  final me = await _x25519.newKeyPairFromSeed(recipientSeed);
  final ephPub = base64Decode(sealed['epk'] as String);
  final shared = await _x25519.sharedSecretKey(
    keyPair: me,
    remotePublicKey: SimplePublicKey(ephPub, type: KeyPairType.x25519),
  );
  final key = await hkdf(
    await shared.extractBytes(),
    salt: [...ephPub, ...recipientPublic],
    info: _inboxInfo,
  );
  return open(key, sealed, aad: _inboxInfo);
}

/// Password-protected blob for exports: Argon2id + AES-256-GCM.
Future<Map<String, Object?>> sealWithPassword(String password, List<int> plain,
    {KdfParams params = const KdfParams(), required String aad}) async {
  final salt = randomBytes(16);
  final key = await argon2id(password, salt, params);
  return {
    'kdf': {...params.toJson(), 'salt': base64Encode(salt)},
    ...await seal(key, plain, aad: aad),
  };
}

Future<Uint8List> openWithPassword(String password, Map<String, Object?> sealed,
    {required String aad}) async {
  final kdf = (sealed['kdf'] as Map).cast<String, Object?>();
  final key = await argon2id(
    password,
    base64Decode(kdf['salt'] as String),
    KdfParams.fromJson(kdf),
  );
  return open(key, sealed, aad: aad);
}
