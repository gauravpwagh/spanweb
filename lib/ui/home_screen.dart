import 'package:flutter/material.dart';

import '../app_controller.dart';
import '../core/link_repository.dart';
import '../core/models.dart';
import 'common.dart';
import 'import_export_ui.dart';
import 'link_sheets.dart';
import '../thumbs/thumb_service.dart';
import 'settings_screens.dart';
import 'thumbnail_settings_screen.dart';

/// After unlocking: links grouped by website, or all links in one list.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_showInboxReport);
    WidgetsBinding.instance.addPostFrameCallback((_) => _showInboxReport());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_showInboxReport);
    super.dispose();
  }

  void _showInboxReport() {
    final r = widget.controller.inboxReport;
    if (r == null || !mounted) return;
    widget.controller.inboxReport = null;
    showMessage(context, 'Shared links: $r');
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final repo = c.repo!;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Link Vault'),
          actions: [
            IconButton(
              tooltip: 'Lock',
              icon: const Icon(Icons.lock_outline),
              onPressed: c.lock,
            ),
            PopupMenuButton<String>(
              onSelected: (v) async {
                switch (v) {
                  case 'import':
                    await runImport(context, c);
                  case 'export':
                    await runExport(context, c);
                  case 'tags':
                    await Navigator.push(context,
                        MaterialPageRoute(builder: (_) => ManageTagsScreen(repo: repo)));
                  case 'pin':
                    await Navigator.push(context,
                        MaterialPageRoute(builder: (_) => ChangePinScreen(controller: c)));
                  case 'thumbs':
                    await Navigator.push(context,
                        MaterialPageRoute(builder: (_) => ThumbnailSettingsScreen(thumbs: c.thumbs!)));
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'import', child: Text('Import links')),
                const PopupMenuItem(value: 'export', child: Text('Export links')),
                const PopupMenuItem(value: 'tags', child: Text('Manage tags')),
                if (c.thumbs != null)
                  const PopupMenuItem(value: 'thumbs', child: Text('Video thumbnails')),
                const PopupMenuItem(value: 'pin', child: Text('Change PIN')),
              ],
            ),
          ],
          bottom: const TabBar(tabs: [Tab(text: 'Websites'), Tab(text: 'All links')]),
        ),
        floatingActionButton: FloatingActionButton(
          tooltip: 'Add link',
          onPressed: () => showAddLinkSheet(context, repo),
          child: const Icon(Icons.add_link),
        ),
        body: TabBarView(
          children: [
            _GroupsTab(repo: repo, thumbs: c.thumbs),
            LinksView(repo: repo, thumbs: c.thumbs),
          ],
        ),
      ),
    );
  }
}

class _GroupsTab extends StatelessWidget {
  const _GroupsTab({required this.repo, this.thumbs});
  final LinkRepository repo;
  final ThumbService? thumbs;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final groups = repo.groups();
        if (groups.isEmpty) return const _Empty();
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 88),
          itemCount: groups.length,
          itemBuilder: (context, i) {
            final g = groups[i];
            return ListTile(
              leading: CircleAvatar(child: Text(g.group.characters.first.toUpperCase())),
              title: Text(g.group),
              subtitle: Text('Last added ${formatDate(g.latest)}'),
              trailing: Text('${g.count}', style: Theme.of(context).textTheme.titleMedium),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => Scaffold(
                    appBar: AppBar(title: Text(g.group)),
                    body: LinksView(repo: repo, group: g.group, thumbs: thumbs),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();
  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Text(
            'No links yet.\n\nShare a link to Link Vault from any app, '
            'tap + to paste one, or import a list.',
            textAlign: TextAlign.center,
          ),
        ),
      );
}

/// A list of links with search, tag filters and date sort.
class LinksView extends StatefulWidget {
  const LinksView({super.key, required this.repo, this.group, this.thumbs});
  final LinkRepository repo;
  final String? group;
  final ThumbService? thumbs;

  @override
  State<LinksView> createState() => _LinksViewState();
}

class _LinksViewState extends State<LinksView> {
  SortOrder _sort = SortOrder.newestFirst;
  final Set<String> _tags = {};
  String _text = '';
  bool _dupsOnly = false;

  @override
  Widget build(BuildContext context) {
    final repo = widget.repo;
    return ListenableBuilder(
      listenable: repo,
      builder: (context, _) {
        final links = repo.query(
          group: widget.group,
          tags: _tags,
          text: _text,
          sort: _sort,
          onlyPossibleDuplicates: _dupsOnly,
        );
        final scopeTags = <String>{
          for (final l in repo.query(group: widget.group)) ...l.tags,
        }.toList()
          ..sort();
        final dupCount = repo.query(group: widget.group, onlyPossibleDuplicates: true).length;

        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      decoration: const InputDecoration(
                        hintText: 'Search links, titles, tags, notes',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                      onChanged: (v) => setState(() => _text = v),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: _sort == SortOrder.newestFirst ? 'Newest first' : 'Oldest first',
                    icon: Icon(_sort == SortOrder.newestFirst
                        ? Icons.arrow_downward
                        : Icons.arrow_upward),
                    onPressed: () => setState(() => _sort = _sort == SortOrder.newestFirst
                        ? SortOrder.oldestFirst
                        : SortOrder.newestFirst),
                  ),
                ],
              ),
            ),
            if (scopeTags.isNotEmpty || dupCount > 0)
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  children: [
                    if (dupCount > 0)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          avatar: const Icon(Icons.content_copy, size: 16),
                          label: Text('Possible duplicates ($dupCount)'),
                          selected: _dupsOnly,
                          onSelected: (v) => setState(() => _dupsOnly = v),
                        ),
                      ),
                    for (final t in scopeTags)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: FilterChip(
                          label: Text(t),
                          selected: _tags.contains(t),
                          onSelected: (v) => setState(() => v ? _tags.add(t) : _tags.remove(t)),
                        ),
                      ),
                  ],
                ),
              ),
            Expanded(
              child: links.isEmpty
                  ? (repo.links.isEmpty ? const _Empty() : const Center(child: Text('No matching links')))
                  : ListView.separated(
                      padding: const EdgeInsets.only(bottom: 88),
                      itemCount: links.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, i) => _LinkTile(
                        repo: repo,
                        thumbs: widget.thumbs,
                        item: links[i],
                        showGroup: widget.group == null,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _LinkTile extends StatelessWidget {
  const _LinkTile({required this.repo, this.thumbs, required this.item, required this.showGroup});
  final LinkRepository repo;
  final ThumbService? thumbs;
  final LinkItem item;
  final bool showGroup;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = thumbs;
    return ListTile(
      leading: t != null && t.allowed(item) ? LinkThumb(thumbs: t, item: item) : null,
      title: Text(item.title ?? item.cleanUrl, maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (item.title != null)
            Text(item.cleanUrl, maxLines: 1, overflow: TextOverflow.ellipsis),
          Text(
            [if (showGroup) item.group, formatDate(item.addedAt)].join(' · '),
            style: theme.textTheme.bodySmall,
          ),
          if (item.tags.isNotEmpty || item.possibleDuplicate)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 4,
                runSpacing: 4,
                children: [
                  if (item.possibleDuplicate)
                    _Pill('possible duplicate', color: theme.colorScheme.tertiaryContainer),
                  for (final t in item.tags.toList()..sort()) _Pill(t),
                ],
              ),
            ),
        ],
      ),
      trailing: IconButton(
        tooltip: 'Copy link',
        icon: const Icon(Icons.copy),
        onPressed: () => copyLink(context, item.cleanUrl),
      ),
      // Tapping shows details. Nothing in the app opens the link.
      onTap: () => showLinkSheet(context, repo, item, thumbs: thumbs),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill(this.text, {this.color});
  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color ?? Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(text, style: Theme.of(context).textTheme.labelSmall),
      );
}
