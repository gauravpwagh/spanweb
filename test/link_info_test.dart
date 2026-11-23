import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:link_vault/core/crypto.dart';
import 'package:link_vault/core/link_repository.dart';
import 'package:link_vault/core/models.dart';
import 'package:link_vault/core/vault_store.dart';
import 'package:link_vault/thumbs/link_info.dart';
import 'package:link_vault/thumbs/safe_fetch.dart';
import 'package:link_vault/thumbs/thumb_service.dart';
import 'package:link_vault/thumbs/thumb_source.dart';

import 'vault_test.dart' show MemorySecrets;

Uint8List jpeg() => Uint8List.fromList(img.encodeJpg(img.Image(width: 640, height: 360)));

Future<void> until(bool Function() ok) async {
  for (var i = 0; i < 200 && !ok(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  expect(ok(), isTrue);
}

void main() {
  final vimeo = videoSourceFor('vimeo:76979871')!;

  group('oEmbed reply', () {
    test('reads title and an allowed thumbnail', () {
      final r = parseOEmbed(
          '{"title":"  The  New Vimeo Player ","thumbnail_url":"https://i.vimeocdn.com/video/1-d_295x166"}',
          vimeo);
      expect(r.title, 'The New Vimeo Player');
      expect(r.thumb!.host, 'i.vimeocdn.com');
    });

    test('drops thumbnails on other hosts, over HTTP or with credentials', () {
      for (final t in [
        'https://evil.com/a.jpg',
        'http://i.vimeocdn.com/a.jpg',
        'https://user:pw@i.vimeocdn.com/a.jpg',
        'https://i.vimeocdn.com.evil.com/a.jpg',
      ]) {
        expect(parseOEmbed('{"title":"T","thumbnail_url":"$t"}', vimeo).thumb, isNull, reason: t);
      }
    });

    test('junk gives nothing', () {
      for (final body in ['', 'not json', '[1,2]', '{"title":5}', '<html>']) {
        final r = parseOEmbed(body, vimeo);
        expect(r.title, isNull, reason: body);
        expect(r.thumb, isNull, reason: body);
      }
    });
  });

  group('page title', () {
    test('prefers og:title, then twitter:title, then <title>', () {
      expect(
          pageTitleFromHtml(
              '<title>Site | Long</title><meta content="Short &amp; sweet" property="og:title">'),
          'Short & sweet');
      expect(pageTitleFromHtml("<meta name='twitter:title' content='Tw'><title>T</title>"), 'Tw');
      expect(pageTitleFromHtml('<html><head><TITLE lang="en">\n  Caf&eacute; &#8211; news&#x21;\n</TITLE>'),
          'Caf&eacute; – news!');
      expect(pageTitleFromHtml('<html><body>no title</body>'), isNull);
      expect(pageTitleFromHtml('<title></title><meta property="og:title" content="">'), isNull);
    });

    test('markup inside the title is removed, not run', () {
      expect(pageTitleFromHtml('<title>A <b>x</b> B</title>'), 'A x B');
      expect(decodeEntities('&#0;&#xD800;&#99999999;ok'), endsWith('ok'));
    });

    test('request goes to the link itself over HTTPS, redirects stay on the site', () {
      final r = pageRequestFor('http://news.example.co.uk/a?utm_source=x&id=2#top')!;
      expect(r.url.toString(), 'https://news.example.co.uk/a?id=2');
      expect(r.hosts, {'news.example.co.uk', 'example.co.uk', '.example.co.uk'});
      expect(hostAllowed('www.example.co.uk', r.hosts), isTrue);
      expect(hostAllowed('example.com', r.hosts), isFalse);
      expect(pageRequestFor('not a link'), isNull);
    });
  });

  group('page image address', () {
    final page = Uri.parse('https://blog.example/posts/1');

    test('prefers og:image, resolves relative addresses', () {
      expect(pageImageFromHtml('<meta property="og:image" content="/a.png"><meta name="twitter:image" content="https://x/b.png">', page).toString(),
          'https://blog.example/a.png');
      expect(pageImageFromHtml("<meta name='twitter:image' content='//cdn.example/t.jpg'>", page).toString(),
          'https://cdn.example/t.jpg');
      expect(pageImageFromHtml('<link rel="image_src" href="img/c.webp">', page).toString(),
          'https://blog.example/posts/img/c.webp');
      expect(pageImageFromHtml('<meta property="og:image" content="https://cdn.example/a.jpg?w=1&amp;h=2">', page)!.query,
          'w=1&h=2');
    });

    test('refuses non-HTTPS, data and credential addresses', () {
      for (final c in ['http://cdn.example/a.jpg', 'data:image/png;base64,AAAA', 'https://u:p@cdn.example/a.jpg', 'javascript:alert(1)', '']) {
        expect(pageImageFromHtml('<meta property="og:image" content="$c">', page), isNull, reason: c);
      }
      expect(pageImageFromHtml('<title>No image</title>', page), isNull);
    });
  });

  group('service', () {
    late Directory tmp;
    late VaultStore store;
    late LinkRepository repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('info_test');
      store = VaultStore(
        dir: Directory('${tmp.path}/v'),
        secrets: MemorySecrets(),
        kdf: const KdfParams(memoryKiB: 256, iterations: 1),
      );
      repo = await LinkRepository.open(store, await store.setup('123456'));
      await repo.updateThumbSettings((s) => s
        ..enabled = true
        ..sites.addAll(thumbSites.keys));
    });
    tearDown(() async {
      await repo.close();
      await tmp.delete(recursive: true);
    });

    test('video: title and thumbnail from oEmbed; an existing title is kept', () async {
      final asked = <Uri>[];
      final svc = ThumbService(
        repo,
        info: (u) async {
          asked.add(u);
          return '{"title":"From Vimeo","thumbnail_url":"https://i.vimeocdn.com/v/1.jpg"}';
        },
        fetch: (u) async {
          asked.add(u);
          return jpeg();
        },
        pause: () => Duration.zero,
      );
      final a = await repo.add('https://vimeo.com/76979871');
      final b = await repo.add('https://vimeo.com/11111111', title: 'Mine');
      svc.request([a, b]);
      await until(() => svc.status(a) == ThumbStatus.ok && svc.status(b) == ThumbStatus.ok);
      expect(a.title, 'From Vimeo');
      expect(b.title, 'Mine');
      expect(asked.map((u) => u.host).toSet(), {'vimeo.com', 'i.vimeocdn.com'});
      svc.dispose();
    });

    test('YouTube: thumbnail by ID even when oEmbed fails', () async {
      final svc = ThumbService(
        repo,
        info: (u) async => throw FetchRefused('offline'),
        fetch: (u) async {
          expect(u.host, 'i.ytimg.com');
          return jpeg();
        },
        pause: () => Duration.zero,
      );
      final a = await repo.add('https://youtu.be/dQw4w9WgXcQ');
      svc.request([a]);
      await until(() => svc.status(a) == ThumbStatus.ok);
      expect(a.title, isNull);
      svc.dispose();
    });

    test("page title only when asked, from the link's own site, stored encrypted", () async {
      final pages = <(Uri, Set<String>)>[];
      final svc = ThumbService(
        repo,
        info: (u) async => fail('no oEmbed for plain pages'),
        fetch: (u) async => fail('no images for plain pages'),
        page: (u, hosts) async {
          pages.add((u, hosts));
          return '<title>Banana Bread Recipe</title>';
        },
      );
      final a = await repo.add('https://www.example.com/recipes/42?utm_source=x');
      expect(svc.allowed(a), isFalse);
      await pumpEventQueue();
      expect(pages, isEmpty);
      expect(await svc.fetchPageInfo(a), (title: 'Banana Bread Recipe', image: false));
      expect(pages.single.$1.toString(), 'https://www.example.com/recipes/42');
      expect(pages.single.$2, contains('.example.com'));
      expect(a.title, 'Banana Bread Recipe');
      await repo.close();
      expect(File('${tmp.path}/v/vault.bin').readAsStringSync().contains('Banana'), isFalse);
      svc.dispose();
    });

    test('a failed page fetch leaves the title alone', () async {
      final svc = ThumbService(repo, page: (u, h) async => throw FetchRefused('status 403'));
      final a = await repo.add('https://example.com/x', title: 'Kept');
      expect(await svc.fetchPageInfo(a), (title: null, image: false));
      expect(a.title, 'Kept');
      svc.dispose();
    });

    test('page preview image: fetched from its own host, cleaned, stored encrypted, shown', () async {
      final images = <Uri>[];
      final svc = ThumbService(
        repo,
        page: (u, h) async => '<meta property="og:image" content="https://cdn.other-host.net/p/1.jpg">'
            '<title>Small Blog Post</title>',
        pageImage: (u) async {
          images.add(u);
          return jpeg();
        },
      );
      final a = await repo.add('https://smallblog.example/post/7');
      expect(svc.hasImage(a), isFalse);
      expect(await svc.fetchPageInfo(a), (title: 'Small Blog Post', image: true));
      expect(images.single.toString(), 'https://cdn.other-host.net/p/1.jpg');
      expect(svc.hasImage(a), isTrue);
      expect(svc.imageFor(a), isNotNull, reason: 'shown even with video info switched off');
      await repo.updateThumbSettings((s) => s.enabled = false);
      expect(svc.imageFor(a), isNotNull);
      final files = Directory('${tmp.path}/v/thumbs').listSync().whereType<File>().toList();
      expect(files, hasLength(1));
      expect(files.single.path.contains('smallblog'), isFalse);
      svc.dispose();
    });

    test('a bad page image still keeps the title', () async {
      final svc = ThumbService(
        repo,
        page: (u, h) async => '<title>T</title><meta name="twitter:image" content="/img.jpg">',
        pageImage: (u) async {
          expect(u.toString(), 'https://site.example/img.jpg');
          return Uint8List.fromList([1, 2, 3]);
        },
      );
      final a = await repo.add('https://site.example/a');
      expect(await svc.fetchPageInfo(a), (title: 'T', image: false));
      expect(svc.hasImage(a), isFalse);
      svc.dispose();
    });
  });
}
