import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/import_export.dart';
import 'common.dart';

Future<String?> _askPassword(BuildContext context, {required bool confirm}) {
  final a = TextEditingController();
  final b = TextEditingController();
  String? error;
  return showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => AlertDialog(
        title: Text(confirm ? 'Protect the export' : 'File password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (confirm)
              const Text('Choose a password of at least 8 characters. Without it the '
                  'file cannot be opened.'),
            TextField(
              controller: a,
              obscureText: true,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Password'),
            ),
            if (confirm)
              TextField(
                controller: b,
                obscureText: true,
                decoration: const InputDecoration(labelText: 'Repeat password'),
              ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(error!, style: TextStyle(color: Theme.of(ctx).colorScheme.error)),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (confirm && a.text.length < 8) {
                setLocal(() => error = 'At least 8 characters');
              } else if (confirm && a.text != b.text) {
                setLocal(() => error = "Passwords don't match");
              } else {
                Navigator.pop(ctx, a.text);
              }
            },
            child: const Text('OK'),
          ),
        ],
      ),
    ),
  );
}

Future<void> runExport(BuildContext context, AppController c) async {
  final repo = c.repo!;
  if (repo.links.isEmpty) {
    showMessage(context, 'Nothing to export yet');
    return;
  }
  final format = await showDialog<ExportFormat>(
    context: context,
    builder: (ctx) => SimpleDialog(
      title: Text('Export ${repo.links.length} links'),
      children: [
        for (final f in ExportFormat.values)
          SimpleDialogOption(
            onPressed: () => Navigator.pop(ctx, f),
            child: ListTile(
              leading: Icon(f == ExportFormat.encrypted ? Icons.lock_outline : Icons.lock_open),
              title: Text(f.label),
              subtitle: Text(switch (f) {
                ExportFormat.encrypted => 'Links, dates, tags and notes. Needs a password to open.',
                ExportFormat.json => 'Links, dates, tags and notes. Anyone with the file can read it.',
                ExportFormat.text => 'Just the links, one per line. Readable by anyone.',
              }),
            ),
          ),
      ],
    ),
  );
  if (format == null || !context.mounted) return;

  String? password;
  if (format == ExportFormat.encrypted) {
    password = await _askPassword(context, confirm: true);
    if (password == null) return;
  }
  final bytes = await buildExport(repo.links, repo.allTags, format, password: password);
  final stamp = DateTime.now().toIso8601String().substring(0, 10);
  final saved = await c.withoutAutoLock(() => FilePicker.saveFile(
        fileName: 'links-$stamp.${format.extension}',
        bytes: bytes,
        mimeType: format == ExportFormat.text ? 'text/plain' : 'application/octet-stream',
        dialogTitle: 'Save export',
      ));
  if (context.mounted && saved != null) showMessage(context, 'Exported ${repo.links.length} links');
}

Future<void> runImport(BuildContext context, AppController c) async {
  final repo = c.repo!;
  final file = await c.withoutAutoLock(() => FilePicker.pickFile(dialogTitle: 'Import links'));
  if (file == null || !context.mounted) return;
  final bytes = await file.readAsBytes();
  if (bytes.length > 20 * 1024 * 1024) {
    if (context.mounted) showMessage(context, 'File is too large (over 20 MB)');
    return;
  }

  ReadyToImport ready;
  switch (readImport(bytes)) {
    case ReadyToImport r:
      ready = r;
    case NeedsPassword src:
      if (!context.mounted) return;
      final pw = await _askPassword(context, confirm: false);
      if (pw == null) return;
      try {
        ready = await decryptImport(src, pw);
      } on WrongPassword {
        if (context.mounted) showMessage(context, 'Wrong password, or the file is damaged');
        return;
      }
  }
  if (!context.mounted) return;
  if (ready.links.isEmpty) {
    showMessage(context, 'No links found in that file');
    return;
  }

  final p = previewImport(repo, ready.links);
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text('Import ${ready.links.length} links?'),
      content: Text([
        '${p.newLinks} new',
        if (p.possible > 0) '${p.possible} of them possible duplicates (flagged for review)',
        '${p.duplicates} already saved (tags will be merged)',
        if (p.invalid > 0) '${p.invalid} not valid links (skipped)',
      ].join('\n')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(
          onPressed: p.newLinks + p.duplicates > 0 ? () => Navigator.pop(ctx, true) : null,
          child: const Text('Import'),
        ),
      ],
    ),
  );
  if (go != true) return;
  for (final t in ready.tags) {
    await repo.addTagToLibrary(t);
  }
  final report = await repo.merge(ready.links, bulk: true);
  if (context.mounted) showMessage(context, 'Import: $report');

  // Preview edition: imports never fetch thumbnails without asking.
  final thumbs = c.thumbs;
  final missing = thumbs?.takeBulkAdded() ?? const [];
  if (thumbs == null || missing.isEmpty || !context.mounted) return;
  final load = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(missing.length == 1 ? 'Load 1 thumbnail?' : 'Load ${missing.length} thumbnails?'),
      content: const Text('They are downloaded one at a time, a few seconds apart, '
          'while the app is unlocked.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
        FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Load')),
      ],
    ),
  );
  if (load == true) thumbs.request(missing);
}
