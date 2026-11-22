import 'package:flutter_test/flutter_test.dart';
import 'package:link_vault/core/url_tools.dart';

void main() {
  group('grouping', () {
    test('strips www/m and groups subdomains under the site', () {
      expect(parseLink('https://www.example.com/a')!.group, 'example.com');
      expect(parseLink('https://m.youtube.com/watch?v=dQw4w9WgXcQ')!.group, 'youtube.com');
      expect(parseLink('https://news.bbc.co.uk/x')!.group, 'bbc.co.uk');
      expect(parseLink('https://old.reddit.com/r/a')!.group, 'reddit.com');
    });

    test('aliases short hosts', () {
      expect(parseLink('https://youtu.be/dQw4w9WgXcQ')!.group, 'youtube.com');
      expect(parseLink('https://twitter.com/a/status/1')!.group, 'x.com');
    });

    test('keeps separate owners on hosting suffixes apart', () {
      expect(parseLink('https://alice.github.io/blog')!.group, 'alice.github.io');
    });
  });

  group('exact duplicates', () {
    String key(String u) => parseLink(u)!.canonicalKey;

    test('YouTube forms share one key', () {
      const id = 'youtube:dQw4w9WgXcQ';
      expect(key('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=42s'), id);
      expect(key('https://youtu.be/dQw4w9WgXcQ?si=abc123'), id);
      expect(key('https://m.youtube.com/shorts/dQw4w9WgXcQ'), id);
      expect(key('https://www.youtube.com/embed/dQw4w9WgXcQ'), id);
    });

    test('X/Twitter and Reddit IDs', () {
      expect(key('https://twitter.com/user/status/12345?s=20'), 'x:12345');
      expect(key('https://x.com/other/status/12345'), 'x:12345');
      expect(key('https://www.reddit.com/r/flutter/comments/abc123/some_title/'), 'reddit:abc123');
      expect(key('https://redd.it/abc123'), 'reddit:abc123');
    });

    test('tracking params, fragment, trailing slash and www do not matter', () {
      expect(
        key('https://www.example.com/post/my-article/?utm_source=x&fbclid=y#top'),
        key('https://example.com/post/my-article'),
      );
    });

    test('meaningful params still matter, in any order', () {
      expect(key('https://e.com/s?a=1&b=2'), key('https://e.com/s?b=2&a=1'));
      expect(key('https://e.com/s?id=1'), isNot(key('https://e.com/s?id=2')));
    });
  });

  group('last part (possible duplicates)', () {
    test('same slug on different sites', () {
      final a = parseLink('https://site-a.com/blog/flutter-state-management')!;
      final b = parseLink('https://mirror.net/2024/flutter-state-management.html')!;
      expect(a.canonicalKey, isNot(b.canonicalKey));
      expect(a.lastSegment, 'flutter-state-management');
      expect(b.lastSegment, a.lastSegment);
    });

    test('generic segments are skipped', () {
      expect(parseLink('https://e.com/great-recipe/index.html')!.lastSegment, 'great-recipe');
      expect(parseLink('https://e.com/')!.lastSegment, isNull);
      expect(parseLink('https://e.com/a/b')!.lastSegment, isNull);
    });
  });

  group('parsing', () {
    test('clean URL drops tracking only', () {
      expect(
        parseLink('https://www.example.com/a?utm_medium=x&q=flutter#frag')!.clean,
        'https://www.example.com/a?q=flutter',
      );
    });

    test('adds https to bare domains, rejects junk', () {
      expect(parseLink('example.com/page')!.clean, 'https://example.com/page');
      expect(parseLink('not a link'), isNull);
      expect(parseLink('ftp://example.com/file'), isNull);
      expect(parseLink('javascript:alert(1)'), isNull);
    });

    test('extracts links from shared text', () {
      expect(
        extractUrls('Watch this! https://youtu.be/dQw4w9WgXcQ, and www.example.com/x.'),
        ['https://youtu.be/dQw4w9WgXcQ', 'www.example.com/x'],
      );
      expect(extractUrls('example.org'), ['example.org']);
      expect(extractUrls('hello there'), isEmpty);
    });
  });
}
