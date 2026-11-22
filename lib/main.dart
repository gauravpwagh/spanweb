import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_controller.dart';
import 'core/vault_store.dart';
import 'ui/home_screen.dart';
import 'ui/pin_screens.dart';
import 'ui/quick_save_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final support = await getApplicationSupportDirectory();
  final controller = AppController(VaultStore(dir: Directory('${support.path}/vault')));
  runApp(LinkVaultApp(controller: controller));
  await controller.init();
}

class LinkVaultApp extends StatelessWidget {
  const LinkVaultApp({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    ThemeData theme(Brightness b) => ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo, brightness: b),
          useMaterial3: true,
        );
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final Widget home;
        if (controller.quickSaveOpen && controller.stage != Stage.loading) {
          // Sharing works without the PIN, but only adds to the inbox.
          home = QuickSaveScreen(controller: controller);
        } else {
          home = switch (controller.stage) {
            Stage.loading => const Scaffold(body: Center(child: CircularProgressIndicator())),
            Stage.needsSetup => SetupPinScreen(controller: controller),
            Stage.locked => LockScreen(controller: controller),
            Stage.unlocked => HomeScreen(controller: controller),
          };
        }
        return MaterialApp(
          // A new key per stage rebuilds the navigator, so locking drops every
          // open screen and sheet instead of leaving them under the PIN screen.
          key: ValueKey('${controller.stage}-${controller.quickSaveOpen}'),
          title: 'Link Vault',
          debugShowCheckedModeBanner: false,
          theme: theme(Brightness.light),
          darkTheme: theme(Brightness.dark),
          home: home,
          builder: (context, child) => Stack(
            children: [
              child!,
              // Hides content in the app switcher (iOS) and while inactive.
              if (controller.obscured)
                const Positioned.fill(
                  child: ColoredBox(
                    color: Colors.black,
                    child: Center(child: Icon(Icons.lock, color: Colors.white54, size: 48)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}
