import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/models.dart';

Timer? _clipboardTimer;
const _clipboard = MethodChannel('linkvault/clipboard');

/// Copies text and clears the clipboard after a minute, if it still holds
/// what we put there. The app never opens links itself.
Future<void> copyLink(BuildContext context, String text) async {
  final isAndroid = defaultTargetPlatform == TargetPlatform.android;
  if (isAndroid) {
    // Marked sensitive, so Android doesn't show it in the copy preview.
    await _clipboard.invokeMethod('copySensitive', text);
  } else {
    await Clipboard.setData(ClipboardData(text: text));
  }
  _clipboardTimer?.cancel();
  _clipboardTimer = Timer(const Duration(seconds: 60), () async {
    if (isAndroid) {
      await _clipboard.invokeMethod('clearIf', text);
    } else {
      final now = await Clipboard.getData(Clipboard.kTextPlain);
      if (now?.text == text) await Clipboard.setData(const ClipboardData(text: ''));
    }
  });
  if (context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(const SnackBar(content: Text('Copied. Clipboard clears in 60 s.')));
  }
}

String formatDate(DateTime d) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  final hh = d.hour.toString().padLeft(2, '0');
  final mm = d.minute.toString().padLeft(2, '0');
  return '${d.day} ${months[d.month - 1]} ${d.year}, $hh:$mm';
}

void showMessage(BuildContext context, String text) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(text)));
}

/// Edits a set of tags: type free text (comma or enter adds it) or pick from
/// [suggestions], the user's managed tag list.
class TagEditor extends StatefulWidget {
  const TagEditor({
    super.key,
    required this.tags,
    required this.suggestions,
    required this.onChanged,
  });

  final Set<String> tags;
  final List<String> suggestions;
  final ValueChanged<Set<String>> onChanged;

  @override
  State<TagEditor> createState() => _TagEditorState();
}

class _TagEditorState extends State<TagEditor> {
  late final Set<String> _tags = {...widget.tags};
  TextEditingController? _field;

  void _add(String raw) {
    var changed = false;
    for (final part in raw.split(',')) {
      final t = normalizeTag(part);
      if (t != null && _tags.add(t)) changed = true;
    }
    _field?.clear();
    if (changed) {
      setState(() {});
      widget.onChanged({..._tags});
    }
  }

  void _remove(String t) {
    setState(() => _tags.remove(t));
    widget.onChanged({..._tags});
  }

  @override
  Widget build(BuildContext context) {
    final unused = widget.suggestions.where((s) => !_tags.contains(s)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_tags.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final t in _tags.toList()..sort())
                InputChip(label: Text(t), onDeleted: () => _remove(t)),
            ],
          ),
        const SizedBox(height: 8),
        Autocomplete<String>(
          optionsBuilder: (v) {
            final q = v.text.trim().toLowerCase();
            if (q.isEmpty) return const [];
            return unused.where((s) => s.contains(q)).take(8);
          },
          onSelected: _add,
          fieldViewBuilder: (context, controller, focus, onSubmit) {
            _field = controller;
            return TextField(
              controller: controller,
              focusNode: focus,
              decoration: const InputDecoration(
                labelText: 'Add tag',
                hintText: 'Type and press enter',
                prefixIcon: Icon(Icons.sell_outlined),
              ),
              textInputAction: TextInputAction.done,
              onChanged: (v) {
                if (v.endsWith(',')) _add(v);
              },
              onSubmitted: (v) {
                _add(v);
                focus.requestFocus();
              },
            );
          },
        ),
        if (unused.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final s in unused.take(20))
                ActionChip(
                  avatar: const Icon(Icons.add, size: 16),
                  label: Text(s),
                  onPressed: () => _add(s),
                ),
            ],
          ),
        ],
      ],
    );
  }
}
