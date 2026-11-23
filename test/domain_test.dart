import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:link_vault/core/crypto.dart';
import 'package:link_vault/core/link_repository.dart';
import 'package:link_vault/core/url_tools.dart';
import 'package:link_vault/core/vault_store.dart';

import 'vault_test.dart' show MemorySecrets;

void main() {
  group('moveUrlDomain', () {
    test('keeps subdomain, path, query and fragment', () {
      expect(moveUrlDomain('https://www.old.com/a/b?x=1#c', 'old.com', 'new.org'),
          'https://www.new.org/a/b?x=1#c');
      expect(moveUrlDomain('https://forum.old.com/t/9', 'old.com', 'new.org'),
          'https://forum.new.org/t/9');
      expect(moveUrlDomain('http://OLD.com:8080/p', 'old.com', 'new.co.uk'),
          'http://new.co.uk:8080/p');
      expect(moveUrlDomain('old.com/page', 'old.com', 'new.org'), 'new.org/page');
    });

    test('a target with its own subdomain replaces www. only', () {
      expect(moveUrlDomain('https://www.old.com/a', 'old.com', 'blog.new.org'),
          'https://blog.new.org/a');
      expect(moveUrlDomain('https://shop.old.com/a', 'old.com', 'blog.new.org'),
          'https://shop.blog.new.org/a');
    });

    test('other hosts are left alone', () {
      expect(moveUrlDomain('https://notold.com/a', 'old.com', 'new.org'), isNull);
      expect(moveUrlDomain('https://youtu.be/dQw4w9WgXcQ', 'youtube.com', 'yt.org'), isNull);
    });

    test('parseDomainInput accepts pasted links and rejects junk', () {
      expect(parseDomainInput(' https://www.New-Site.org/x '), 'new-site.org');
      expect(parseDomainInput('new.org'), 'new.org');
      expect(parseDomainInput('not a domain'), isNull);
      expect(parseDomainInput('10.0.0.1'), isNull);
    });
  });

  group('same address on another domain', () {
    test('path key ignores domain, tracking and parameter order', () {
      final a = parseLink('https://www.old.com/forum/t/5?page=2&utm_source=x')!;
      final b = parseLink('https://mirror.net/Forum/t/5?page=2')!;
      expect(a.pathKey, '/forum/t/5?page=2');
      expect(b.pathKey, a.pathKey);
      expect(parseLink('https://site.com/')!.pathKey, isNull);
      expect(parseLink('https://youtu.be/dQw4w9WgXcQ')!.pathKey, isNull);
    });

    test('flags a link whose address after the domain is already saved', () async {
      final tmp = await Directory.systemTemp.createTemp('path_test');
      final store = VaultStore(
        dir: Directory('${tmp.path}/v'),
        secrets: MemorySecrets(),
        kdf: const KdfParams(memoryKiB: 256, iterations: 1),
      );
      final repo = await LinkRepository.open(store, await store.setup('123456'));
      // "5" alone is too short to count as a meaningful last part.
      final first = await repo.add('https://old-forum.com/t/5');
      expect(repo.check('https://new-forum.org/t/5').possible.map((l) => l.id), [first.id]);
      expect(repo.check('https://new-forum.org/t/6').possible, isEmpty);
      expect(repo.check('https://new-forum.org/').possible, isEmpty);
      final r = await repo.merge([IncomingLink('https://new-forum.org/t/5')]);
      expect(r.possibleDuplicates, 1);
      final second = repo.query().firstWhere((l) => l.id != first.id);
      expect(second.possibleDuplicate, isTrue);
      expect(repo.similarTo(second).map((l) => l.id), [first.id]);
      await repo.close();
      await tmp.delete(recursive: true);
    });
  });

  group('changeDomain', () {
    late Directory tmp;
    late VaultStore store;
    late LinkRepository repo;

    setUp(() async {
      tmp = await Directory.systemTemp.createTemp('domain_test');
      store = VaultStore(
        dir: Directory('${tmp.path}/v'),
        secrets: MemorySecrets(),
        kdf: const KdfParams(memoryKiB: 256, iterations: 1),
      );
      repo = await LinkRepository.open(store, await store.setup('123456'));
    });
    tearDown(() => tmp.delete(recursive: true));

    test('moves the group, keeps details, merges duplicates', () async {
      final a = await repo.add('https://old.com/post/1', tags: {'x'}, title: 'One', note: 'n');
      await repo.add('https://www.old.com/post/2');
      await repo.add('https://new.org/post/2', tags: {'already'});
      final r = await repo.changeDomain('old.com', 'new.org');
      expect((r.moved, r.merged, r.skipped), (1, 1, 0));
      expect(repo.groups().map((g) => g.group), ['new.org']);
      final moved = repo.query().firstWhere((l) => l.id == a.id);
      expect(moved.url, 'https://new.org/post/1');
      expect((moved.title, moved.note), ('One', 'n'));
      expect(moved.tags, {'x'});
      expect(repo.query().length, 2);
    });

    test('remembered move applies to later saves, imports and the inbox', () async {
      await repo.add('https://old.com/a');
      await repo.changeDomain('old.com', 'new.org');
      expect(repo.domainMoves, {'old.com': 'new.org'});

      final b = await repo.add('https://m.old.com/b');
      expect(b.url, 'https://m.new.org/b');
      await repo.merge([IncomingLink('https://old.com/c')]);
      expect(repo.check('https://old.com/a').exact, isNotNull);
      expect(repo.groups().map((g) => g.group), ['new.org']);

      // Survives lock and unlock.
      await repo.close();
      final again = await LinkRepository.open(
          store, (await store.unlock('123456') as Unlocked).session);
      expect(again.domainMoves, {'old.com': 'new.org'});
    });

    test('without remember, later links keep the old domain', () async {
      await repo.add('https://old.com/a');
      await repo.changeDomain('old.com', 'new.org', remember: false);
      expect(repo.domainMoves, isEmpty);
      expect((await repo.add('https://old.com/b')).url, 'https://old.com/b');
    });

    test('chains of moves follow to the newest domain, and moving back undoes', () async {
      await repo.add('https://a.com/1');
      await repo.changeDomain('a.com', 'b.com');
      await repo.changeDomain('b.com', 'c.com');
      expect(repo.domainMoves, {'a.com': 'c.com', 'b.com': 'c.com'});
      await repo.changeDomain('c.com', 'a.com');
      expect(repo.domainMoves, {'b.com': 'a.com', 'c.com': 'a.com'});
      expect((await repo.add('https://b.com/2')).url, 'https://a.com/2');
      await repo.forgetDomainMove('b.com');
      expect((await repo.add('https://b.com/3')).url, 'https://b.com/3');
    });
  });
}
