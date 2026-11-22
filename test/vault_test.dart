import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:link_vault/core/crypto.dart';
import 'package:link_vault/core/import_export.dart';
import 'package:link_vault/core/link_repository.dart';
import 'package:link_vault/core/vault_store.dart';

class MemorySecrets implements SecretStore {
  final map = <String, String>{};
  @override
  Future<String?> read(String key) async => map[key];
  @override
  Future<void> write(String key, String value) async => map[key] = value;
  @override
  Future<void> delete(String key) async => map.remove(key);
}

// Cheap Argon2 settings so tests run fast; the app uses the real defaults.
const fastKdf = KdfParams(memoryKiB: 256, iterations: 1);

void main() {
  late Directory tmp;
  late VaultStore store;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('vault_test');
    store = VaultStore(dir: Directory('${tmp.path}/v'), secrets: MemorySecrets(), kdf: fastKdf);
  });
  tearDown(() => tmp.delete(recursive: true));

  test('setup, unlock with right PIN, reject wrong PIN', () async {
    expect(await store.isSetUp(), isFalse);
    await store.setup('123456');
    expect(await store.isSetUp(), isTrue);
    expect(await store.unlock('123456'), isA<Unlocked>());
    final wrong = await store.unlock('654321');
    expect(wrong, isA<WrongPin>());
    expect((wrong as WrongPin).failures, 1);
  });

  test('lockout after 5 wrong PINs', () async {
    await store.setup('123456');
    for (var i = 0; i < 4; i++) {
      expect((await store.unlock('000000') as WrongPin).lockedUntil, isNull);
    }
    expect((await store.unlock('000000') as WrongPin).lockedUntil, isNotNull);
    expect(await store.unlock('123456'), isA<LockedOut>());
    expect(VaultStore.lockoutFor(5), const Duration(seconds: 30));
    expect(VaultStore.lockoutFor(6), const Duration(seconds: 60));
    expect(VaultStore.lockoutFor(50), const Duration(hours: 1));
  });

  test('vault file holds no readable links', () async {
    final s = await store.setup('123456');
    final repo = await LinkRepository.open(store, s);
    await repo.add('https://example.com/secret-article', tags: {'Private'});
    final raw = await File('${tmp.path}/v/vault.bin').readAsString();
    expect(raw.contains('secret-article'), isFalse);
    expect(raw.contains('private'), isFalse);
  });

  test('links persist across lock and unlock', () async {
    final s = await store.setup('123456');
    final repo = await LinkRepository.open(store, s);
    await repo.add('https://example.com/a', tags: {'Work', ' to  read '});
    final s2 = (await store.unlock('123456') as Unlocked).session;
    final repo2 = await LinkRepository.open(store, s2);
    expect(repo2.links.single.cleanUrl, 'https://example.com/a');
    expect(repo2.links.single.tags, {'work', 'to read'});
  });

  test('change PIN keeps the data', () async {
    final s = await store.setup('123456');
    await (await LinkRepository.open(store, s)).add('https://example.com/a');
    await store.changePin(s, '999999');
    expect(await store.unlock('123456'), isA<WrongPin>());
    final s2 = (await store.unlock('999999') as Unlocked).session;
    expect((await LinkRepository.open(store, s2)).links, hasLength(1));
  });

  test('inbox: write without PIN, unreadable on disk, merged on unlock', () async {
    await store.setup('123456');
    await store.addToInbox('look https://youtu.be/dQw4w9WgXcQ');
    await store.addToInbox('https://www.youtube.com/watch?v=dQw4w9WgXcQ&si=x');
    await store.addToInbox('https://example.com/new-thing');
    expect(await store.inboxCount(), 3);
    for (final f in Directory('${tmp.path}/v/inbox').listSync().whereType<File>()) {
      expect(f.readAsStringSync().contains('youtu'), isFalse);
    }

    final s = (await store.unlock('123456') as Unlocked).session;
    final repo = await LinkRepository.open(store, s);
    final report = (await repo.ingestInbox())!;
    expect(report.added, 2);
    expect(report.exactDuplicates, 1);
    expect(await store.inboxCount(), 0);
    expect(repo.groups().map((g) => g.group), containsAll(['youtube.com', 'example.com']));
  });

  test('erase removes everything', () async {
    await store.setup('123456');
    await store.erase();
    expect(await store.isSetUp(), isFalse);
  });

  group('repository', () {
    late LinkRepository repo;
    setUp(() async => repo = await LinkRepository.open(store, await store.setup('123456')));

    test('exact and possible duplicates', () async {
      await repo.add('https://site-a.com/blog/great-flutter-tips');
      expect(repo.check('https://site-a.com/blog/great-flutter-tips/?utm_source=x').exact, isNotNull);
      final c = repo.check('https://other.net/great-flutter-tips');
      expect(c.exact, isNull);
      expect(c.possible, hasLength(1));
      final added = await repo.add('https://other.net/great-flutter-tips');
      expect(added.possibleDuplicate, isTrue);
      expect(repo.similarTo(added), hasLength(1));
      expect(() => repo.add('https://site-a.com/blog/great-flutter-tips'), throwsStateError);
    });

    test('sort by date and filter by tags (all must match)', () async {
      await repo.add('https://a.com/one', addedAt: DateTime(2024, 1, 1), tags: {'x', 'y'});
      await repo.add('https://a.com/two', addedAt: DateTime(2025, 1, 1), tags: {'x'});
      await repo.add('https://b.com/three', addedAt: DateTime(2023, 1, 1));
      expect(repo.query().map((l) => l.url).first, 'https://a.com/two');
      expect(repo.query(sort: SortOrder.oldestFirst).first.url, 'https://b.com/three');
      expect(repo.query(tags: {'x'}), hasLength(2));
      expect(repo.query(tags: {'x', 'y'}), hasLength(1));
      expect(repo.query(group: 'a.com'), hasLength(2));
    });

    test('rename and delete tags', () async {
      await repo.add('https://a.com/one', tags: {'old'});
      await repo.renameTag('old', 'New');
      expect(repo.links.single.tags, {'new'});
      await repo.deleteTag('new');
      expect(repo.links.single.tags, isEmpty);
      expect(repo.allTags, isEmpty);
    });
  });

  group('import / export', () {
    late LinkRepository repo;
    setUp(() async {
      repo = await LinkRepository.open(store, await store.setup('123456'));
      await repo.add('https://a.com/one', addedAt: DateTime(2024, 5, 1), tags: {'t1'});
      await repo.add('https://b.com/two', note: 'hello');
    });

    test('encrypted round trip, wrong password rejected', () async {
      final bytes = await buildExport(repo.links, repo.allTags, ExportFormat.encrypted,
          password: 'correct horse');
      expect(utf8.decode(bytes).contains('a.com'), isFalse);
      final src = readImport(bytes) as NeedsPassword;
      expect(() => decryptImport(src, 'wrong password'), throwsA(isA<WrongPassword>()));
      final ready = await decryptImport(src, 'correct horse');
      expect(ready.links.map((l) => l.url), ['https://a.com/one', 'https://b.com/two']);
      expect(ready.links.first.addedAt, DateTime(2024, 5, 1));
      expect(ready.links.first.tags, {'t1'});
    });

    test('plain JSON and text import, merge skips duplicates', () async {
      final json = await buildExport(repo.links, repo.allTags, ExportFormat.json);
      final ready = readImport(json) as ReadyToImport;
      expect(previewImport(repo, ready.links).duplicates, 2);

      final txt = utf8.encode('https://a.com/one?utm_source=z\nnoise\nhttps://c.com/three\n'
          'https://c.com/three');
      final fromText = readImport(txt) as ReadyToImport;
      final p = previewImport(repo, fromText.links);
      expect((p.newLinks, p.duplicates), (1, 2));
      final report = await repo.merge(fromText.links);
      expect((report.added, report.exactDuplicates), (1, 2));
      expect(repo.links, hasLength(3));
    });

    test('preview counts possible duplicates within the same file, like merge', () async {
      final txt = utf8.encode('https://x.com/news/flutter-security-tips\n'
          'https://y.org/blog/flutter-security-tips');
      final ready = readImport(txt) as ReadyToImport;
      final p = previewImport(repo, ready.links);
      final report = await repo.merge(ready.links);
      expect((p.newLinks, p.possible), (2, 1));
      expect((report.added, report.possibleDuplicates), (2, 1));
    });
  });
}
