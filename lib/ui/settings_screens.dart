import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/link_repository.dart';
import 'common.dart';
import 'pin_screens.dart';

/// The fixed tag list: add, rename, delete. Tags typed on links show up here.
class ManageTagsScreen extends StatelessWidget {
  const ManageTagsScreen({super.key, required this.repo});
  final LinkRepository repo;

  Future<String?> _ask(BuildContext context, String title, [String initial = '']) {
    final c = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: c,
          autofocus: true,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, c.text), child: const Text('Save')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Tags')),
      floatingActionButton: FloatingActionButton(
        tooltip: 'New tag',
        onPressed: () async {
          final t = await _ask(context, 'New tag');
          if (t != null) await repo.addTagToLibrary(t);
        },
        child: const Icon(Icons.add),
      ),
      body: ListenableBuilder(
        listenable: repo,
        builder: (context, _) {
          final tags = repo.allTags;
          if (tags.isEmpty) {
            return const Center(child: Text('No tags yet. Tap + to create your set.'));
          }
          return ListView(
            children: [
              for (final t in tags)
                ListTile(
                  leading: const Icon(Icons.sell_outlined),
                  title: Text(t),
                  subtitle: Text('${repo.tagUseCount(t)} links'),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        tooltip: 'Rename',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () async {
                          final n = await _ask(context, 'Rename tag', t);
                          if (n != null) await repo.renameTag(t, n);
                        },
                      ),
                      IconButton(
                        tooltip: 'Delete',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text('Delete "$t"?'),
                              content: const Text('It is removed from every link. Links stay.'),
                              actions: [
                                TextButton(
                                    onPressed: () => Navigator.pop(ctx, false),
                                    child: const Text('Cancel')),
                                FilledButton(
                                    onPressed: () => Navigator.pop(ctx, true),
                                    child: const Text('Delete')),
                              ],
                            ),
                          );
                          if (ok == true) await repo.deleteTag(t);
                        },
                      ),
                    ],
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// New PIN, typed twice. The current session proves the old PIN.
class ChangePinScreen extends StatefulWidget {
  const ChangePinScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<ChangePinScreen> createState() => _ChangePinScreenState();
}

class _ChangePinScreenState extends State<ChangePinScreen> {
  String? _first;
  String? _error;

  Future<void> _onPin(String pin) async {
    if (_first == null) {
      setState(() {
        _first = pin;
        _error = null;
      });
    } else if (pin == _first) {
      await widget.controller.changePin(pin);
      if (!mounted) return;
      showMessage(context, 'PIN changed');
      Navigator.pop(context);
    } else {
      setState(() {
        _first = null;
        _error = "PINs didn't match. Start again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Change PIN')),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: PinPad(
            key: ValueKey(_first == null),
            title: _first == null ? 'New 6-digit PIN' : 'Type the new PIN again',
            message: _error,
            isError: _error != null,
            onComplete: _onPin,
          ),
        ),
      ),
    );
  }
}
