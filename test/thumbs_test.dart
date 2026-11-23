import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:link_vault/core/link_repository.dart';
import 'package:link_vault/core/models.dart';
import 'package:link_vault/core/url_tools.dart';
import 'package:link_vault/core/vault_store.dart';
import 'package:link_vault/thumbs/safe_fetch.dart';
import 'package:link_vault/thumbs/sanitize.dart';
import 'package:link_vault/thumbs/thumb_service.dart';
import 'package:link_vault/thumbs/thumb_source.dart';

import 'vault_test.dart' show MemorySecrets, fastKdf;

Uint8List jpeg(int w, int h) => img.encodeJpg(img.Image(width: w, height: h));

/// No oEmbed service in tests: every request fails.
Future<String> noInfo(Uri u) async => throw FetchRefused('offline');

void main() {
  group('thumb source', () {
    test('every YouTube link form gives the same image address', () {
      const id = 'dQw4w9WgXcQ';
      for (final u in [
        'https://youtu.be/$id?si=abc',
        'https://m.youtube.com/watch?v=$id&feature=share',
        'https://www.youtube.com/shorts/$id',
      ]) {
        final r = videoSourceFor(parseLink(u)!.canonicalKey)!;
        expect(r.directThumb.toString(), 'https://i.ytimg.com/vi/$id/mqdefault.jpg');
        expect(r.site, 'youtube.com');
        expect(r.oembed.host, 'www.youtube.com');
        expect(r.oembed.queryParameters['url'], 'https://www.youtube.com/watch?v=$id');
        expect(thumbHosts, contains(r.directThumb!.host));
      }
    });

    test('Vimeo and Dailymotion use their oEmbed services', () {
      final v = videoSourceFor(parseLink('https://vimeo.com/76979871')!.canonicalKey)!;
      expect(v.oembed.toString(), 'https://vimeo.com/api/oembed.json?url=https%3A%2F%2Fvimeo.com%2F76979871');
      expect(v.directThumb, isNull);
      final d = videoSourceFor(parseLink('https://www.dailymotion.com/video/x7tgad0_some-slug')!.canonicalKey)!;
      expect(d.oembed.queryParameters['url'], 'https://www.dailymotion.com/video/x7tgad0');
      for (final s in [v, d]) {
        expect(oembedHosts, contains(s.oembed.host));
      }
    });

    test('plain pages get nothing', () {
      for (final u in ['https://bbc.co.uk/news/x', 'https://www.youtube.com/', 'https://x.com/a/status/1']) {
        expect(videoSourceFor(parseLink(u)!.canonicalKey), isNull, reason: u);
      }
    });
  });

  group('address checks', () {
    test('private, local and reserved addresses are refused', () {
      for (final a in [
        '127.0.0.1', '10.1.2.3', '172.16.0.1', '172.31.255.255', '192.168.1.1', '169.254.1.1',
        '100.64.0.1', '0.0.0.0', '224.0.0.1', '255.255.255.255', '::1', '::', 'fe80::1',
        'fd00::1', 'ff02::1', '::ffff:192.168.1.1', '64:ff9b::a00:1', '2001:db8::1',
      ]) {
        expect(isPublicAddress(InternetAddress(a)), isFalse, reason: a);
      }
    });

    test('public addresses pass', () {
      for (final a in ['142.250.183.14', '8.8.8.8', '172.32.0.1', '2607:f8b0:4004:800::200e', '::ffff:8.8.8.8']) {
        expect(isPublicAddress(InternetAddress(a)), isTrue, reason: a);
      }
    });
  });

  group('safe fetch (local test server)', () {
    late HttpServer server;
    late Uri base;
    final handlers = <String, Future<void> Function(HttpRequest)>{};
    const testPolicy = FetchPolicy(
      allowedHosts: {'127.0.0.1'},
      allowHttpForTests: true,
      allowPrivateForTests: true,
      maxBytes: 50 * 1024,
      timeout: Duration(seconds: 2),
    );

    setUpAll(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      base = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((req) async {
        final h = handlers[req.uri.path];
        if (h == null) {
          req.response.statusCode = 404;
        } else {
          await h(req);
        }
        await req.response.close();
      });
      Future<void> image(HttpRequest r, String type, List<int> body) async {
        r.response.headers.contentType = ContentType.parse(type);
        r.response.add(body);
      }

      handlers['/ok.jpg'] = (r) => image(r, 'image/jpeg', jpeg(64, 36));
      handlers['/html'] = (r) => image(r, 'text/html', utf8.encode('<html></html>'));
      handlers['/fake.jpg'] = (r) => image(r, 'image/jpeg', utf8.encode('<html>not a jpeg</html>'));
      handlers['/big.jpg'] = (r) => image(r, 'image/jpeg', [0xff, 0xd8, 0xff, ...List.filled(60 * 1024, 0)]);
      handlers['/big-chunked.jpg'] = (r) async {
        r.response.headers.contentType = ContentType.parse('image/jpeg');
        r.response.bufferOutput = false;
        for (var i = 0; i < 20; i++) {
          r.response.add(List.filled(4096, i == 0 ? 0xff : 0));
          await r.response.flush();
        }
      };
      handlers['/slow.jpg'] = (r) => Future.delayed(const Duration(seconds: 4));
      handlers['/to-ok'] = (r) async => r.response.redirect(base.resolve('/ok.jpg'));
      handlers['/to-other-host'] = (r) async =>
          r.response.redirect(Uri.parse('http://localhost:${server.port}/ok.jpg'));
      handlers['/loop'] = (r) async => r.response.redirect(base.resolve('/loop'));
    });

    tearDownAll(() => server.close(force: true));

    Future<String> refusal(String path, [FetchPolicy p = testPolicy]) async {
      try {
        await safeFetchImage(base.resolve(path), p);
        return 'fetched';
      } on FetchRefused catch (e) {
        return e.reason;
      }
    }

    test('downloads an allowed image, following a same-host redirect', () async {
      expect((await safeFetchImage(base.resolve('/ok.jpg'), testPolicy)).take(3), [0xff, 0xd8, 0xff]);
      expect(await refusal('/to-ok'), 'fetched');
    });

    test('the real policy refuses plain HTTP and local addresses', () async {
      const real = FetchPolicy(allowedHosts: {'127.0.0.1'});
      expect(await refusal('/ok.jpg', real), 'not https');
      const httpOnly = FetchPolicy(allowedHosts: {'127.0.0.1'}, allowHttpForTests: true);
      expect(await refusal('/ok.jpg', httpOnly), 'private address');
    });

    test('refuses other hosts, also through redirects, and redirect loops', () async {
      expect(await refusal('/ok.jpg', const FetchPolicy(allowedHosts: {'i.ytimg.com'}, allowHttpForTests: true)),
          startsWith('host not allowed'));
      expect(await refusal('/to-other-host'), 'host not allowed: localhost');
      expect(await refusal('/loop'), 'bad redirect');
    });

    test('refuses non-images, disguised content, oversized and slow responses', () async {
      expect(await refusal('/html'), startsWith('wrong type'));
      expect(await refusal('/fake.jpg'), startsWith('content does not match'));
      expect(await refusal('/big.jpg'), 'too large');
      expect(await refusal('/big-chunked.jpg'), 'too large');
      expect(await refusal('/slow.jpg'), 'timed out');
      expect(await refusal('/missing.jpg'), 'status 404');
    });

    test('text: page start is read and cut quietly, JSON over the cap is refused', () async {
      handlers['/page'] = (r) async {
        r.response.headers.contentType = ContentType.html;
        r.response.write('<html><head><title>Hello</title></head>${'x' * 100000}');
      };
      handlers['/data'] = (r) async {
        r.response.headers.contentType = ContentType.json;
        r.response.write('{"title":"${'y' * 100000}"}');
      };
      const p = FetchPolicy(
        allowedHosts: {'.0.0.1', 'example.org'},
        maxBytes: 4096,
        allowHttpForTests: true,
        allowPrivateForTests: true,
      );
      final page = await safeFetchText(base.resolve('/page'), p, types: {'text/html'}, truncate: true);
      expect(page.length, 4096);
      expect(page, startsWith('<html><head><title>Hello'));
      await expectLater(safeFetchText(base.resolve('/data'), p, types: {'application/json'}),
          throwsA(isA<FetchRefused>().having((e) => e.reason, 'reason', 'too large')));
      await expectLater(safeFetchText(base.resolve('/page'), p, types: {'application/json'}),
          throwsA(isA<FetchRefused>()));
      expect(hostAllowed('s2.dmcdn.net', {'.dmcdn.net'}), isTrue);
      expect(hostAllowed('dmcdn.net.evil.com', {'.dmcdn.net'}), isFalse);
      expect(hostAllowed('evildmcdn.net', {'.dmcdn.net'}), isFalse);
    });
  });

  group('sanitize', () {
    test('re-encodes JPEG and PNG to a 320 px JPEG without metadata', () {
      final src = img.Image(width: 640, height: 360)..exif.imageIfd['Artist'] = 'secret-name';
      for (final bytes in [img.encodeJpg(src), img.encodePng(src)]) {
        final out = sanitizeThumbnailSync(bytes)!;
        final back = img.decodeJpg(out)!;
        expect((back.width, back.height), (320, 180));
        expect(latin1.decode(out, allowInvalid: true).contains('secret-name'), isFalse);
      }
    });

    test('small images are not enlarged', () {
      expect(img.decodeJpg(sanitizeThumbnailSync(jpeg(120, 90))!)!.width, 120);
    });

    test('rejects junk, truncated files and huge dimensions', () {
      expect(sanitizeThumbnailSync(Uint8List.fromList(utf8.encode('<svg/>'))), isNull);
      expect(sanitizeThumbnailSync(Uint8List.fromList(List.generate(500, (i) => i % 256))), isNull);
      final full = jpeg(640, 360);
      expect(sanitizeThumbnailSync(Uint8List.sublistView(full, 0, 40)), isNull);
      // A tiny file that claims to be 5000 px wide is refused before decoding.
      expect(sanitizeThumbnailSync(img.encodePng(img.Image(width: 5000, height: 1))), isNull);
    });

    test('works in a background isolate', () async {
      expect(await sanitizeThumbnail(jpeg(640, 360)), isNotNull);
    });
  });

  group('storage and service', () {
    late Directory tmp;
    late VaultStore store;
    late LinkRepository repo;
    const ytUrl = 'https://youtu.be/dQw4w9WgXcQ';
    const id = 'dQw4w9WgXcQ';

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('thumbs');
      store = VaultStore(dir: Directory('${tmp.path}/v'), secrets: MemorySecrets(), kdf: fastKdf);
      repo = await LinkRepository.open(store, await store.setup('123456'));
    });
    tearDown(() async {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // Windows may still hold a handle.
      }
    });

    List<File> thumbFiles() {
      final d = Directory('${tmp.path}/v/thumbs');
      return d.existsSync() ? d.listSync().whereType<File>().toList() : [];
    }

    test('stored encrypted, names hide the video, deleted with the link', () async {
      final link = await repo.add(ytUrl);
      final pic = jpeg(320, 180);
      await repo.putThumb(link.canonicalKey, pic);
      expect(thumbFiles(), hasLength(1));
      final f = thumbFiles().single;
      expect(f.path.contains(id), isFalse);
      expect(f.readAsStringSync().contains(id), isFalse);
      expect(await repo.loadThumb(link.canonicalKey), pic);
      expect(repo.thumbStatus(link.canonicalKey), ThumbStatus.ok);

      await repo.delete(link);
      expect(thumbFiles(), isEmpty);
      expect(repo.thumbStatus(link.canonicalKey), isNull);
    });

    test('orphaned files are pruned, and settings survive a reload', () async {
      final link = await repo.add(ytUrl);
      await repo.putThumb(link.canonicalKey, jpeg(32, 18));
      await store.saveThumb((await _session(store))!, 'youtube:AAAAAAAAAAA', jpeg(32, 18));
      await repo.updateThumbSettings((s) => s
        ..enabled = true
        ..sites.add('youtube.com'));
      expect(thumbFiles(), hasLength(2));
      await repo.pruneThumbs();
      expect(thumbFiles(), hasLength(1));

      final again = await LinkRepository.open(store, (await _session(store))!);
      expect(again.thumbSettings.enabled, isTrue);
      expect(again.thumbSettings.sites, {'youtube.com'});
      expect(again.thumbStatus(link.canonicalKey), ThumbStatus.ok);
    });

    test('nothing is fetched until the user turns thumbnails on for the site', () async {
      final fetched = <Uri>[];
      final svc = ThumbService(repo, info: noInfo, fetch: (u) async {
        fetched.add(u);
        return jpeg(640, 360);
      }, pause: () => Duration.zero);
      final link = await repo.add(ytUrl);
      svc.request([link]);
      await repo.updateThumbSettings((s) => s.enabled = true);
      svc.request([link]); // enabled, but YouTube not switched on
      await repo.updateThumbSettings((s) => s.automatic = true);
      await repo.add('https://youtu.be/BBBBBBBBBBB');
      await pumpEventQueue();
      expect(fetched, isEmpty);
      expect(svc.allowed(link), isFalse);
      svc.dispose();
    });

    test('manual and automatic loading, imports wait for a yes', () async {
      final fetched = <Uri>[];
      final svc = ThumbService(repo, info: noInfo, fetch: (u) async {
        fetched.add(u);
        return jpeg(640, 360);
      }, pause: () => Duration.zero);
      await repo.updateThumbSettings((s) => s
        ..enabled = true
        ..sites.add('youtube.com'));

      final a = await repo.add(ytUrl);
      await pumpEventQueue();
      expect(fetched, isEmpty, reason: 'manual mode: only when asked');
      svc.request([a], first: true);
      await _until(() => svc.status(a) == ThumbStatus.ok);
      expect(fetched.single.host, 'i.ytimg.com');

      await repo.updateThumbSettings((s) => s.automatic = true);
      final b = await repo.add('https://youtu.be/BBBBBBBBBBB');
      await _until(() => svc.status(b) == ThumbStatus.ok);

      await repo.merge([IncomingLink('https://youtu.be/CCCCCCCCCCC')], bulk: true);
      await pumpEventQueue();
      expect(fetched, hasLength(2), reason: 'imports never fetch without asking');
      expect(svc.takeBulkAdded(), hasLength(1));
      svc.dispose();
    });

    test('a failed or unsafe image is recorded, not retried automatically', () async {
      var calls = 0;
      final svc = ThumbService(repo, info: noInfo, fetch: (u) async {
        calls++;
        return Uint8List.fromList(utf8.encode('<html>'));
      }, pause: () => Duration.zero);
      await repo.updateThumbSettings((s) => s
        ..enabled = true
        ..sites.add('youtube.com'));
      final a = await repo.add(ytUrl);
      svc.request([a]);
      await _until(() => svc.status(a) == ThumbStatus.failed);
      expect(svc.missing([a]), isEmpty);
      expect(thumbFiles(), isEmpty);
      expect(calls, 1);
      svc.dispose();
    });

    test('locking mid-download stores nothing', () async {
      final gate = Completer<Uint8List>();
      final svc = ThumbService(repo, info: noInfo, fetch: (u) => gate.future, pause: () => Duration.zero);
      await repo.updateThumbSettings((s) => s
        ..enabled = true
        ..sites.add('youtube.com'));
      final a = await repo.add(ytUrl);
      svc.request([a]);
      await pumpEventQueue();
      svc.dispose();
      await repo.close();
      gate.complete(jpeg(640, 360));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(thumbFiles(), isEmpty);
    });
  });

  test('locking waits for the last save, so the vault is never written with a wiped key', () async {
    final tmp = await Directory.systemTemp.createTemp('lock');
    final store = VaultStore(dir: Directory('${tmp.path}/v'), secrets: MemorySecrets(), kdf: fastKdf);
    final session = await store.setup('123456');
    final repo = await LinkRepository.open(store, session);
    final link = await repo.add('https://example.com/a');
    unawaited(repo.setNote(link, 'written just before locking'));
    await repo.close(); // what AppController.lock waits for
    session.wipe();
    await repo.setNote(link, 'after lock: must not be written');

    final reopened = await LinkRepository.open(store, (await _session(store))!);
    expect(reopened.links.single.note, 'written just before locking');
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold a handle.
    }
  });
}

Future<Session?> _session(VaultStore store) async {
  final r = await store.unlock('123456');
  return r is Unlocked ? r.session : null;
}

Future<void> _until(bool Function() done) async {
  for (var i = 0; i < 200 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue);
}
