import 'package:flutter/material.dart';

import '../core/models.dart';
import '../thumbs/thumb_service.dart';
import '../thumbs/thumb_source.dart';
import 'common.dart';

/// Opt-in for video titles and thumbnails (preview edition only).
class ThumbnailSettingsScreen extends StatelessWidget {
  const ThumbnailSettingsScreen({super.key, required this.thumbs});
  final ThumbService thumbs;

  Future<void> _setEnabled(BuildContext context, bool on) async {
    final repo = thumbs.repo;
    if (on) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Turn on video info?'),
          content: const Text(
            "To get a title and thumbnail, Link Vault asks the video site's "
            'official info service (oEmbed) about the video. That site sees '
            'which video you asked about and your IP address.\n\n'
            'The video page itself is never loaded. Titles and thumbnails are '
            'stored encrypted with your links. Nothing is sent anywhere else.',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Turn on')),
          ],
        ),
      );
      if (ok != true) return;
    } else {
      thumbs.cancelAll();
    }
    await repo.updateThumbSettings((s) => s.enabled = on);
  }

  @override
  Widget build(BuildContext context) {
    final repo = thumbs.repo;
    return Scaffold(
      appBar: AppBar(title: const Text('Video titles & thumbnails')),
      body: ListenableBuilder(
        listenable: Listenable.merge([repo, thumbs]),
        builder: (context, _) {
          final s = thumbs.settings;
          final missing = thumbs.missing(repo.links);
          final failed = repo.links.where((l) => thumbs.status(l) == ThumbStatus.failed).length;
          return ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text('Preview feature, for internal testing. Off by default.'),
              ),
              SwitchListTile(
                title: const Text('Load video titles and thumbnails'),
                subtitle: const Text("From the site's official info service, never the page"),
                value: s.enabled,
                onChanged: (v) => _setEnabled(context, v),
              ),
              if (s.enabled) ...[
                const Divider(),
                const _Header('Sites'),
                for (final e in thumbSites.entries)
                  SwitchListTile(
                    title: Text(e.value),
                    subtitle: Text('${e.value} sees which videos you load and your IP address'),
                    value: s.sites.contains(e.key),
                    onChanged: (v) => repo.updateThumbSettings(
                      (s) => v ? s.sites.add(e.key) : s.sites.remove(e.key),
                    ),
                  ),
                const Divider(),
                const _Header('When to load'),
                RadioGroup<bool>(
                  groupValue: s.automatic,
                  onChanged: (v) => repo.updateThumbSettings((s) => s.automatic = v ?? false),
                  child: const Column(
                    children: [
                      RadioListTile(
                        value: false,
                        title: Text('Only when I tap "Load title and thumbnail"'),
                      ),
                      RadioListTile(
                        value: true,
                        title: Text('Automatically for new links'),
                        subtitle: Text('Imports still ask first'),
                      ),
                    ],
                  ),
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.download_outlined),
                  title: Text(missing.isEmpty
                      ? 'All allowed links are loaded'
                      : 'Load titles and thumbnails for ${missing.length} saved '
                          '${missing.length == 1 ? 'link' : 'links'}'),
                  subtitle: const Text('One at a time, a few seconds apart'),
                  enabled: missing.isNotEmpty,
                  onTap: () {
                    thumbs.request(missing);
                    showMessage(context, 'Loading ${missing.length} ${missing.length == 1 ? 'link' : 'links'}');
                  },
                ),
                if (failed > 0)
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: Text('Try $failed failed ${failed == 1 ? 'link' : 'links'} again'),
                    onTap: () => repo.clearThumbFailures(),
                  ),
              ],
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('Delete all thumbnails'),
                onTap: () async {
                  thumbs.cancelAll();
                  thumbs.clearMemory();
                  await repo.deleteAllThumbs();
                  if (context.mounted) showMessage(context, 'Thumbnails deleted');
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall),
      );
}

/// A link's thumbnail, or nothing. Never tappable on its own.
class LinkThumb extends StatelessWidget {
  const LinkThumb({super.key, required this.thumbs, required this.item, this.width = 72});
  final ThumbService thumbs;
  final LinkItem item;
  final double width;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: thumbs,
        builder: (context, _) {
          final bytes = thumbs.imageFor(item);
          if (bytes == null) {
            // Keeps list rows aligned until (or unless) a thumbnail exists.
            return Container(
              width: width,
              height: width * 9 / 16,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(Icons.smart_display_outlined,
                  color: Theme.of(context).colorScheme.onSurfaceVariant),
            );
          }
          return ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.memory(
              bytes,
              width: width,
              height: width * 9 / 16,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              excludeFromSemantics: true,
            ),
          );
        },
      );
}
