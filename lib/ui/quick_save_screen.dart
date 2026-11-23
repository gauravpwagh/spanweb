import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/url_tools.dart';

/// Shown when a link is shared into the app while it is locked. It can only
/// add to the inbox; nothing already saved is visible here.
class QuickSaveScreen extends StatefulWidget {
  const QuickSaveScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<QuickSaveScreen> createState() => _QuickSaveScreenState();
}

class _QuickSaveScreenState extends State<QuickSaveScreen> {
  int _saved = 0;
  bool _busy = false;

  Future<void> _save(String text) async {
    setState(() => _busy = true);
    try {
      await widget.controller.saveShared(text);
      _saved++;
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('Could not save the link. Try again.')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final pending = c.pendingShares;
    return Scaffold(
      appBar: AppBar(title: const Text('Save shared link')),
      body: SafeArea(
        child: c.stage == Stage.needsSetup
            ? _setUpFirst(context)
            : pending.isEmpty
            ? _done(context)
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  for (final text in List.of(pending)) _card(context, text),
                ],
              ),
      ),
    );
  }

  Widget _card(BuildContext context, String text) {
    final urls = extractUrls(text);
    final parsed = urls.map(parseLink).whereType<ParsedLink>().toList();
    final title = widget.controller.shareTitles[text];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (parsed.isEmpty)
              Text('No link found in the shared text.',
                  style: TextStyle(color: Theme.of(context).colorScheme.error))
            else ...[
              if (title != null) ...[
                Text(title, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 6),
              ],
              for (final p in parsed) ...[
                Text(p.group, style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                Text(p.clean, maxLines: 4, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 8),
              ],
            ],
            const SizedBox(height: 8),
            Text(
              'Saved links are encrypted and added to your groups the next time you unlock.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: _busy ? null : () => widget.controller.discardShared(text),
                  child: const Text('Discard'),
                ),
                const SizedBox(width: 8),
                FilledButton.icon(
                  onPressed: _busy || parsed.isEmpty ? null : () => _save(text),
                  icon: const Icon(Icons.download_done),
                  label: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _setUpFirst(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.lock_outline, size: 48),
              const SizedBox(height: 12),
              Text('Choose a PIN first', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 8),
              Text(
                widget.controller.pendingShares.length == 1
                    ? "Link Vault isn't set up yet. Choose a PIN, and the shared link is saved right after."
                    : "Link Vault isn't set up yet. Choose a PIN, and the shared links are saved right after.",
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: widget.controller.setUpFirst,
                child: const Text('Choose PIN'),
              ),
            ],
          ),
        ),
      );

  Widget _done(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(_saved > 0 ? Icons.check_circle_outline : Icons.inbox_outlined, size: 48),
              const SizedBox(height: 12),
              Text(_saved > 0 ? 'Saved' : 'Nothing saved',
                  style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 24),
              FilledButton(
                onPressed: () {
                  widget.controller.closeQuickSave();
                  SystemNavigator.pop();
                },
                child: const Text('Done'),
              ),
              const SizedBox(height: 8),
              TextButton(
                // Goes to the PIN screen (or back to the links if unlocked).
                onPressed: widget.controller.closeQuickSave,
                child: const Text('Open app'),
              ),
            ],
          ),
        ),
      );
}
