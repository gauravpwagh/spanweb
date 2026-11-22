import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:link_vault/app_controller.dart';
import 'package:link_vault/core/crypto.dart';
import 'package:link_vault/core/vault_store.dart';
import 'package:link_vault/main.dart';

import 'vault_test.dart' show MemorySecrets;

Future<void> enterPin(WidgetTester tester, String pin, {Finder? until}) async {
  for (final d in pin.split('')) {
    await tester.tap(find.widgetWithText(TextButton, d));
    await tester.pump();
  }
  await settleReal(tester, until: until);
}

/// Argon2 runs in an isolate and files are real, so let real time pass.
/// (pumpAndSettle would never finish while the busy spinner spins.)
/// With [until], waits up to 15 s for that widget to appear.
Future<void> settleReal(WidgetTester tester, {Finder? until}) async {
  for (var i = 0; i < (until == null ? 20 : 300); i++) {
    await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
    if (until != null && i >= 4 && until.evaluate().isNotEmpty) break;
  }
}

void main() {
  testWidgets('set PIN, add link, lock, shared link waits in inbox, unlock merges it',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(500, 1000));
    final tmp = (await tester.runAsync(() => Directory.systemTemp.createTemp('flow')))!;
    final store = VaultStore(
      dir: Directory('${tmp.path}/v'),
      secrets: MemorySecrets(),
      kdf: const KdfParams(memoryKiB: 256, iterations: 1),
    );
    final c = AppController(store);
    await tester.pumpWidget(LinkVaultApp(controller: c));
    await tester.runAsync(c.init);
    await settleReal(tester);

    expect(find.text('Choose a 6-digit PIN'), findsOneWidget);
    await enterPin(tester, '246810', until: find.text('Type the PIN again'));
    expect(find.text('Type the PIN again'), findsOneWidget);
    await enterPin(tester, '246810', until: find.text('Link Vault'));
    expect(find.text('Link Vault'), findsOneWidget);

    await tester.runAsync(() => c.repo!.add('https://www.youtube.com/watch?v=dQw4w9WgXcQ'));
    await settleReal(tester);
    expect(find.text('youtube.com'), findsOneWidget);

    c.lock();
    await settleReal(tester);
    expect(find.text('Enter PIN'), findsOneWidget);
    expect(find.text('youtube.com'), findsNothing);

    // A share arrives while locked: no PIN asked, only Save.
    await tester.runAsync(() => c.saveShared('see https://example.com/great-article'));
    await settleReal(tester);

    await enterPin(tester, '111111', until: find.textContaining('Wrong PIN'));
    expect(find.textContaining('Wrong PIN'), findsOneWidget);
    await enterPin(tester, '246810', until: find.text('example.com'));
    expect(find.text('example.com'), findsOneWidget);
    expect(find.text('youtube.com'), findsOneWidget);

    // Let the last encrypted save finish, then clean up (best effort: Windows
    // may still hold a handle for a moment).
    await settleReal(tester);
    await tester.runAsync(() async {
      try {
        await tmp.delete(recursive: true);
      } on FileSystemException {
        // Left in the system temp folder.
      }
    });
  });

  test('real PIN hashing settings take a reasonable time', () async {
    final sw = Stopwatch()..start();
    await argon2id('123456', randomBytes(16), const KdfParams());
    sw.stop();
    // ignore: avoid_print
    print('Argon2id (19 MiB, t=2) on this machine: ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsed, lessThan(const Duration(seconds: 10)));
  });
}
