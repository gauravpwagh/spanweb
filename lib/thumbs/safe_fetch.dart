import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The only code in the app that uses the network. It downloads one image,
/// one small JSON reply or the start of one web page from an allowed host,
/// and refuses everything else.
class FetchPolicy {
  const FetchPolicy({
    required this.allowedHosts,
    this.maxBytes = 2 * 1024 * 1024,
    this.timeout = const Duration(seconds: 10),
    this.maxRedirects = 2,
    this.allowHttpForTests = false,
    this.allowPrivateForTests = false,
  });

  /// Exact host names; an entry starting with `.` also allows any host
  /// ending in it (`.dmcdn.net` allows `s2.dmcdn.net`).
  final Set<String> allowedHosts;
  final int maxBytes;

  /// For the whole download, including redirects.
  final Duration timeout;
  final int maxRedirects;

  /// Tests run a server on 127.0.0.1 over plain HTTP. Never set in the app.
  final bool allowHttpForTests;
  final bool allowPrivateForTests;
}

class FetchRefused implements Exception {
  FetchRefused(this.reason);
  final String reason;
  @override
  String toString() => 'FetchRefused: $reason';
}

const _imageTypes = {'image/jpeg', 'image/png', 'image/webp'};

/// Downloads an image. Throws [FetchRefused] for anything outside the
/// policy, and on timeouts or network errors.
Future<Uint8List> safeFetchImage(Uri url, FetchPolicy policy) async {
  final r = await _download(url, policy, accept: 'image/jpeg,image/png,image/webp', types: _imageTypes);
  if (!_looksLike(r.type, r.bytes)) throw FetchRefused('content does not match ${r.type}');
  return r.bytes;
}

/// Downloads text of one of [types], decoded as UTF-8. With [truncate],
/// stops quietly after `maxBytes` (enough to read a page's head) instead of
/// refusing a longer reply.
Future<String> safeFetchText(
  Uri url,
  FetchPolicy policy, {
  required Set<String> types,
  bool truncate = false,
}) async {
  final r = await _download(url, policy, accept: types.join(','), types: types, truncate: truncate);
  return utf8.decode(r.bytes, allowMalformed: true);
}

Future<({Uint8List bytes, String type})> _download(
  Uri url,
  FetchPolicy policy, {
  required String accept,
  required Set<String> types,
  bool truncate = false,
}) async {
  final client = HttpClient()
    ..userAgent = 'Mozilla/5.0'
    ..connectionTimeout = policy.timeout
    ..findProxy = ((_) => 'DIRECT');
  // Resolve the name ourselves and connect to an address we checked, so a
  // second DNS answer can't point the connection somewhere private.
  client.connectionFactory = (uri, proxyHost, proxyPort) async {
    final address = await _checkedAddress(uri.host, policy);
    return uri.scheme == 'https'
        ? SecureSocket.startConnect(address, uri.port)
        : Socket.startConnect(address, uri.port);
  };
  try {
    return await _fetch(client, url, policy, accept, types, truncate).timeout(
      policy.timeout,
      onTimeout: () => throw FetchRefused('timed out'),
    );
  } on FetchRefused {
    rethrow;
  } on Object catch (e) {
    throw FetchRefused('network error: ${e.runtimeType}');
  } finally {
    client.close(force: true);
  }
}

Future<({Uint8List bytes, String type})> _fetch(
  HttpClient client,
  Uri url,
  FetchPolicy policy,
  String accept,
  Set<String> types,
  bool truncate,
) async {
  var uri = url;
  for (var hop = 0;; hop++) {
    _checkUri(uri, policy);
    final req = await client.getUrl(uri);
    req
      ..followRedirects = false
      ..persistentConnection = false;
    req.headers
      ..set(HttpHeaders.acceptHeader, accept)
      ..removeAll(HttpHeaders.refererHeader);
    final res = await req.close();

    if (res.isRedirect) {
      final location = res.headers.value(HttpHeaders.locationHeader);
      await res.drain<void>().catchError((_) {});
      if (location == null || hop >= policy.maxRedirects) throw FetchRefused('bad redirect');
      uri = uri.resolve(location);
      continue; // the next loop checks the new address
    }
    if (res.statusCode != HttpStatus.ok) {
      await res.drain<void>().catchError((_) {});
      throw FetchRefused('status ${res.statusCode}');
    }
    final type = res.headers.contentType?.mimeType;
    if (type == null || !types.contains(type)) {
      await res.drain<void>().catchError((_) {});
      throw FetchRefused('wrong type: $type');
    }
    if (!truncate && res.contentLength > policy.maxBytes) throw FetchRefused('too large');

    final out = BytesBuilder(copy: false);
    await for (final chunk in res) {
      out.add(chunk);
      if (out.length > policy.maxBytes) {
        if (!truncate) throw FetchRefused('too large');
        break; // closing the client drops the rest
      }
    }
    final bytes = out.takeBytes();
    return (bytes: truncate && bytes.length > policy.maxBytes
        ? Uint8List.sublistView(bytes, 0, policy.maxBytes)
        : bytes, type: type);
  }
}

void _checkUri(Uri uri, FetchPolicy p) {
  final schemeOk = uri.scheme == 'https' || (p.allowHttpForTests && uri.scheme == 'http');
  if (!schemeOk) throw FetchRefused('not https');
  if (uri.userInfo.isNotEmpty) throw FetchRefused('credentials in address');
  if (!hostAllowed(uri.host, p.allowedHosts)) {
    throw FetchRefused('host not allowed: ${uri.host}');
  }
}

/// Whether [host] matches [allowed]: exactly, or by a `.suffix` entry.
bool hostAllowed(String host, Set<String> allowed) {
  final h = host.toLowerCase();
  return allowed.contains(h) || allowed.any((a) => a.startsWith('.') && h.endsWith(a));
}

Future<InternetAddress> _checkedAddress(String host, FetchPolicy p) async {
  final addresses = await InternetAddress.lookup(host);
  if (addresses.isEmpty) throw FetchRefused('no address');
  if (!p.allowPrivateForTests && !addresses.every(isPublicAddress)) {
    throw FetchRefused('private address');
  }
  return addresses.first;
}

/// False for loopback, private, link-local, shared (CGNAT), multicast and
/// reserved ranges, IPv4 and IPv6.
bool isPublicAddress(InternetAddress a) {
  final b = a.rawAddress;
  if (a.type == InternetAddressType.IPv4) return _publicV4(b);
  if (a.type != InternetAddressType.IPv6 || b.length != 16) return false;
  // IPv4-mapped (::ffff:a.b.c.d) and NAT64 (64:ff9b::a.b.c.d): judge the IPv4 part.
  final mapped = b.sublist(0, 10).every((x) => x == 0) && b[10] == 0xff && b[11] == 0xff;
  final nat64 = b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b &&
      b.sublist(4, 12).every((x) => x == 0);
  if (mapped || nat64) return _publicV4(b.sublist(12));
  if (b.every((x) => x == 0)) return false; // ::
  if (b.sublist(0, 15).every((x) => x == 0) && b[15] == 1) return false; // ::1
  if ((b[0] & 0xfe) == 0xfc) return false; // fc00::/7 unique local
  if (b[0] == 0xfe && (b[1] & 0xc0) == 0x80) return false; // fe80::/10 link-local
  if (b[0] == 0xff) return false; // multicast
  if (b[0] == 0x20 && b[1] == 0x01 && b[2] == 0x0d && b[3] == 0xb8) return false; // documentation
  return true;
}

bool _publicV4(List<int> b) {
  final (x, y) = (b[0], b[1]);
  if (x == 0 || x == 10 || x == 127) return false;
  if (x == 100 && y >= 64 && y <= 127) return false; // 100.64/10 CGNAT
  if (x == 169 && y == 254) return false; // link-local
  if (x == 172 && y >= 16 && y <= 31) return false;
  if (x == 192 && y == 168) return false;
  if (x == 192 && y == 0 && (b[2] == 0 || b[2] == 2)) return false;
  if (x == 198 && (y == 18 || y == 19)) return false; // benchmarking
  if (x == 198 && y == 51 && b[2] == 100) return false; // documentation
  if (x == 203 && y == 0 && b[2] == 113) return false; // documentation
  if (x >= 224) return false; // multicast and reserved
  return true;
}

bool _looksLike(String type, Uint8List b) {
  bool starts(List<int> sig, [int at = 0]) =>
      b.length >= at + sig.length && [for (var i = 0; i < sig.length; i++) b[at + i]].join(',') == sig.join(',');
  return switch (type) {
    'image/jpeg' => starts([0xff, 0xd8, 0xff]),
    'image/png' => starts([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    'image/webp' => starts([0x52, 0x49, 0x46, 0x46]) && starts([0x57, 0x45, 0x42, 0x50], 8),
    _ => false,
  };
}
