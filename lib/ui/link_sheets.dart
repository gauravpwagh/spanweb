import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/link_repository.dart';
import '../core/models.dart';
import '../thumbs/thumb_service.dart';
import 'common.dart';
import 'thumbnail_settings_screen.dart';

/// Details for one link: copy, tags, note, duplicates, delete. There is no
/// "open" button on purpose.
Future<void> showLinkSheet(BuildContext context, LinkRepository repo, LinkItem item,
        {ThumbService? thumbs}) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _LinkSheet(repo: repo, item: item, thumbs: thumbs),
    );

class _LinkSheet extends StatefulWidget {
  const _LinkSheet({required this.repo, required this.item, this.thumbs});
  final LinkRepository repo;
  final LinkItem item;
  final ThumbService? thumbs;

  @override
  State<_LinkSheet> createState() => _LinkSheetState();
}

class _LinkSheetState extends State<_LinkSheet> {
  late final _note = TextEditingController(text: widget.item.note ?? '');

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete link?'),
        content: Text(widget.item.cleanUrl),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok == true) {
      await widget.repo.delete(widget.item);
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final similar = widget.repo.similarTo(item);
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.thumbs case final t? when t.allowed(item)) _ThumbSection(thumbs: t, item: item),
            Text(item.group, style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            // Plain selectable text: never turned into a tappable link.
            SelectableText(item.cleanUrl, style: theme.textTheme.bodyLarge),
            const SizedBox(height: 4),
            Text('Added ${formatDate(item.addedAt)}', style: theme.textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                FilledButton.icon(
                  onPressed: () => copyLink(context, item.cleanUrl),
                  icon: const Icon(Icons.copy),
                  label: const Text('Copy link'),
                ),
                if (item.url != item.cleanUrl)
                  OutlinedButton(
                    onPressed: () => copyLink(context, item.url),
                    child: const Text('Copy original'),
                  ),
              ],
            ),
            if (item.possibleDuplicate || similar.isNotEmpty) ...[
              const SizedBox(height: 16),
              Card(
                color: theme.colorScheme.tertiaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Possible duplicate', style: theme.textTheme.titleSmall),
                      const SizedBox(height: 4),
                      Text('Same last part ("${item.lastSegment}") as:'),
                      for (final s in similar)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('• ${s.cleanUrl}', maxLines: 2, overflow: TextOverflow.ellipsis),
                        ),
                      if (item.possibleDuplicate)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () async {
                              await widget.repo.clearPossibleDuplicate(item);
                              setState(() {});
                            },
                            child: const Text('Not a duplicate'),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Text('Tags', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            TagEditor(
              tags: item.tags,
              suggestions: widget.repo.allTags,
              onChanged: (t) => widget.repo.setTags(item, t),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _note,
              decoration: const InputDecoration(labelText: 'Note', prefixIcon: Icon(Icons.notes)),
              maxLines: 3,
              minLines: 1,
              onChanged: (v) => widget.repo.setNote(item, v),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: _delete,
                icon: Icon(Icons.delete_outline, color: theme.colorScheme.error),
                label: Text('Delete', style: TextStyle(color: theme.colorScheme.error)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Paste a link by hand.
Future<void> showAddLinkSheet(BuildContext context, LinkRepository repo) =>
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _AddLinkSheet(repo: repo),
    );

class _AddLinkSheet extends StatefulWidget {
  const _AddLinkSheet({required this.repo});
  final LinkRepository repo;

  @override
  State<_AddLinkSheet> createState() => _AddLinkSheetState();
}

class _AddLinkSheetState extends State<_AddLinkSheet> {
  final _url = TextEditingController();
  Set<String> _tags = {};
  String? _error;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _paste() async {
    final d = await Clipboard.getData(Clipboard.kTextPlain);
    if (d?.text != null) setState(() => _url.text = d!.text!.trim());
  }

  Future<void> _save() async {
    final repo = widget.repo;
    final c = repo.check(_url.text);
    if (c.invalid) {
      setState(() => _error = 'Not a valid http(s) link');
      return;
    }
    if (c.exact != null) {
      final existing = c.exact!;
      final addTags = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Already saved'),
          content: Text('Saved ${formatDate(existing.addedAt)} in ${existing.group}:\n\n'
              '${existing.cleanUrl}'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('OK')),
            if (_tags.difference(existing.tags).isNotEmpty)
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Add these tags to it'),
              ),
          ],
        ),
      );
      if (addTags == true) await repo.setTags(existing, {...existing.tags, ..._tags});
      if (mounted) Navigator.pop(context);
      return;
    }
    if (c.possible.isNotEmpty) {
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Possible duplicate'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('The last part "${c.parsed!.lastSegment}" matches:'),
              for (final p in c.possible.take(5))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('• ${p.cleanUrl}', maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save anyway')),
          ],
        ),
      );
      if (go != true) return;
    }
    await repo.add(_url.text, tags: _tags);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Add link', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              autofocus: true,
              keyboardType: TextInputType.url,
              decoration: InputDecoration(
                labelText: 'Link',
                errorText: _error,
                suffixIcon: IconButton(
                  tooltip: 'Paste',
                  icon: const Icon(Icons.content_paste),
                  onPressed: _paste,
                ),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: 16),
            TagEditor(
              tags: _tags,
              suggestions: widget.repo.allTags,
              onChanged: (t) => _tags = t,
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: FilledButton(onPressed: _save, child: const Text('Save')),
            ),
          ],
        ),
      ),
    );
  }
}

/// Thumbnail and its "Load" button in the link details (preview edition).
class _ThumbSection extends StatelessWidget {
  const _ThumbSection({required this.thumbs, required this.item});
  final ThumbService thumbs;
  final LinkItem item;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: thumbs,
        builder: (context, _) {
          final has = thumbs.imageFor(item) != null;
          final status = thumbs.status(item);
          final Widget action;
          if (thumbs.isLoading(item)) {
            action = const Row(children: [
              SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
              SizedBox(width: 8),
              Text('Loading thumbnail...'),
            ]);
          } else if (status == ThumbStatus.ok) {
            action = const SizedBox.shrink();
          } else {
            action = OutlinedButton.icon(
              onPressed: () => thumbs.request([item], first: true),
              icon: const Icon(Icons.image_outlined),
              label: Text(status == ThumbStatus.failed
                  ? 'Could not load thumbnail. Try again'
                  : 'Load thumbnail'),
            );
          }
          return Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (has) LinkThumb(thumbs: thumbs, item: item, width: 240),
                action,
              ],
            ),
          );
        },
      );
}
