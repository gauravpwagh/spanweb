import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:link_vault/core/crypto.dart';
import 'package:link_vault/core/import_export.dart';
import 'package:link_vault/core/link_repository.dart';
import 'package:link_vault/core/models.dart';
import 'package:link_vault/core/url_tools.dart';
import 'package:link_vault/core/vault_store.dart';

import 'vault_test.dart' show MemorySecrets;

void main() {
  group('sharedTitle', () {
    test('uses the subject the other app sent', () {
      expect(sharedTitle('https://example.com/a', subject: '  Great   article\n'), 'Great article');
    });

    test('falls back to the words around the link', () {
      expect(sharedTitle('Never Gonna Give You Up - https://youtu.be/dQw4w9WgXcQ'),
          'Never Gonna Give You Up');
      expect(sharedTitle('https://example.com/a | How to cook rice'), 'How to cook rice');
    });

    test('ignores chatter, bare links and multi-link shares', () {
      expect(sharedTitle('see https://example.com/a'), isNull);
      expect(sharedTitle('https://example.com/a'), isNull);
      expect(sharedTitle('https://example.com/a', subject: 'https://example.com/a'), isNull);
      expect(sharedTitle('Two links https://a.com/x https://b.com/y', subject: 'Title'), isNull);
    });

    test('limits length and strips control characters', () {
      final t = cleanTitle('A\u0000B ${'x' * 500}')!;
      expect(t.length, maxTitleLength);
      expect(t.startsWith('A B '), isTrue);
      expect(t.endsWith('…'), isTrue);
    });
  });

  group('display without the domain', () {
    LinkItem item(String url) => LinkItem(id: 'x', url: url, addedAt: DateTime(2026));

    test('shows path and query; copying uses the whole link', () {
      final l = item('https://www.bbc.co.uk/news/articles/c123?id=2&utm_source=x#top');
      expect(l.displayPath, '/news/articles/c123?id=2');
      expect(l.host, 'bbc.co.uk');
      expect(l.cleanUrl, 'https://www.bbc.co.uk/news/articles/c123?id=2');
    });

    test('subdomain, home page, short links and encoded characters', () {
      expect(item('https://news.ycombinator.com/item?id=1').host, 'news.ycombinator.com');
      expect(item('https://example.com/').displayPath, 'example.com');
      expect(item('https://www.example.com').displayPath, 'example.com');
      expect(item('https://youtu.be/dQw4w9WgXcQ').displayPath, '/dQw4w9WgXcQ');
      expect(item('https://de.wikipedia.org/wiki/K%C3%B6ln').displayPath, '/wiki/Köln');
    });
  });

  group('stored titles', () {
    late Directory tmp;
    late VaultStore store;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('titles_test');
      store = VaultStore(
        dir: Directory('${tmp.path}/v'),
        secrets: MemorySecrets(),
        kdf: const KdfParams(memoryKiB: 256, iterations: 1),
      );
    });
    tearDown(() => tmp.delete(recursive: true));

    test('title goes through the encrypted inbox and stays unreadable on disk', () async {
      final s = await store.setup('123456');
      await store.addToInbox('https://example.com/a', title: 'Secret Recipe Title');
      for (final f in Directory('${tmp.path}/v/inbox').listSync().whereType<File>()) {
        expect(f.readAsStringSync().contains('Secret Recipe'), isFalse);
      }
      final repo = await LinkRepository.open(store, s);
      await repo.ingestInbox();
      expect(repo.query().single.title, 'Secret Recipe Title');
      expect(File('${tmp.path}/v/vault.bin').readAsStringSync().contains('Secret Recipe'), isFalse);

      // Survives lock and unlock.
      await repo.close();
      final again = await LinkRepository.open(store, (await store.unlock('123456') as Unlocked).session);
      expect(again.query().single.title, 'Secret Recipe Title');
    });

    test('a share with several links gives none of them its title', () async {
      final s = await store.setup('123456');
      await store.addToInbox('https://a.com/x https://b.com/y', title: 'Which one?');
      final repo = await LinkRepository.open(store, s);
      await repo.ingestInbox();
      expect(repo.query().map((l) => l.title), everyElement(isNull));
    });

    test('duplicate fills a missing title but never replaces one', () async {
      final s = await store.setup('123456');
      final repo = await LinkRepository.open(store, s);
      await repo.add('https://youtu.be/dQw4w9WgXcQ');
      await repo.merge([IncomingLink('https://www.youtube.com/watch?v=dQw4w9WgXcQ', title: 'First')]);
      expect(repo.query().single.title, 'First');
      await repo.merge([IncomingLink('https://youtube.com/shorts/dQw4w9WgXcQ', title: 'Second')]);
      expect(repo.query().single.title, 'First');
    });

    test('search finds titles; editing to blank removes the title', () async {
      final s = await store.setup('123456');
      final repo = await LinkRepository.open(store, s);
      final item = await repo.add('https://example.com/p/123', title: 'Banana Bread');
      expect(repo.query(text: 'banana').single.id, item.id);
      await repo.setTitle(item, '   ');
      expect(item.title, isNull);
      expect(repo.query(text: 'banana'), isEmpty);
    });

    test('JSON export and import keep titles', () async {
      final s = await store.setup('123456');
      final repo = await LinkRepository.open(store, s);
      await repo.add('https://example.com/p/1', title: 'Kept');
      final bytes = await buildExport(repo.query(), [], ExportFormat.json);
      expect(jsonDecode(utf8.decode(bytes)).toString().contains('Kept'), isTrue);
      final ready = readImport(bytes) as ReadyToImport;
      expect(ready.links.single.title, 'Kept');
    });
  });
}
