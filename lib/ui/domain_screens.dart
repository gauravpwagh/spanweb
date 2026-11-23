import 'package:flutter/material.dart';

import '../core/link_repository.dart';
import '../core/url_tools.dart';
import 'common.dart';

/// Asks for a website's new domain and changes every link in [group] to it.
/// Returns true when links were changed.
Future<bool> showChangeDomainDialog(BuildContext context, LinkRepository repo, String group) async {
  final result = await showDialog<DomainChange>(
    context: context,
    builder: (_) => _ChangeDomainDialog(repo: repo, group: group),
  );
  if (result == null || !context.mounted) return false;
  showMessage(context, result.toString());
  return true;
}

class _ChangeDomainDialog extends StatefulWidget {
  const _ChangeDomainDialog({required this.repo, required this.group});
  final LinkRepository repo;
  final String group;

  @override
  State<_ChangeDomainDialog> createState() => _ChangeDomainDialogState();
}

class _ChangeDomainDialogState extends State<_ChangeDomainDialog> {
  final _input = TextEditingController();
  bool _remember = true;
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  String? get _domain => parseDomainInput(_input.text);

  /// The first link in the group, as it would look after the change.
  String? get _example {
    final to = _domain;
    if (to == null) return null;
    for (final l in widget.repo.query(group: widget.group)) {
      final moved = moveUrlDomain(l.cleanUrl, widget.group, to);
      if (moved != null) return '${l.cleanUrl}\n→ $moved';
    }
    return null;
  }

  Future<void> _apply() async {
    final to = _domain;
    if (to == null) return;
    setState(() => _busy = true);
    final r = await widget.repo.changeDomain(widget.group, to, remember: _remember);
    if (mounted) Navigator.pop(context, r);
  }

  @override
  Widget build(BuildContext context) {
    final to = _domain;
    final same = to != null && to == widget.group;
    final example = same ? null : _example;
    final count = widget.repo.query(group: widget.group).length;
    return AlertDialog(
      title: const Text('Change domain'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Changes the domain of $count link${count == 1 ? '' : 's'} on '
                '${widget.group}. The rest of each link stays the same.'),
            const SizedBox(height: 12),
            TextField(
              controller: _input,
              autofocus: true,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: 'New domain',
                hintText: 'new-site.org',
                errorText: _input.text.trim().isEmpty
                    ? null
                    : to == null
                        ? 'Not a valid domain'
                        : same
                            ? 'That is the current domain'
                            : null,
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (example != null) ...[
              const SizedBox(height: 12),
              Text('Example', style: Theme.of(context).textTheme.labelMedium),
              Text(example, style: Theme.of(context).textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _remember,
              onChanged: (v) => setState(() => _remember = v ?? true),
              title: Text('Also change links saved later from ${widget.group}'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy || to == null || same ? null : _apply,
          child: const Text('Change'),
        ),
      ],
    );
  }
}

/// Domains that are changed automatically when links are saved or imported.
class DomainMovesScreen extends StatelessWidget {
  const DomainMovesScreen({super.key, required this.repo});
  final LinkRepository repo;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Domain changes')),
      body: ListenableBuilder(
        listenable: repo,
        builder: (context, _) {
          final moves = repo.domainMoves.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
          if (moves.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No domain changes. Open a website and choose Change domain to add one.',
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('New links from these domains are changed to the new domain '
                    'when they are saved or imported.'),
              ),
              for (final m in moves)
                ListTile(
                  title: Text('${m.key} → ${m.value}'),
                  trailing: IconButton(
                    tooltip: 'Stop changing ${m.key}',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => repo.forgetDomainMove(m.key),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}
