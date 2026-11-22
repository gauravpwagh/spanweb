import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../core/vault_store.dart';

/// Six dots and a number pad. Calls [onComplete] when all digits are in.
class PinPad extends StatefulWidget {
  const PinPad({
    super.key,
    required this.title,
    required this.onComplete,
    this.message,
    this.isError = false,
    this.enabled = true,
  });

  final String title;
  final String? message;
  final bool isError;
  final bool enabled;
  final Future<void> Function(String pin) onComplete;

  @override
  State<PinPad> createState() => PinPadState();
}

class PinPadState extends State<PinPad> {
  String _pin = '';
  bool _busy = false;

  void clear() => setState(() => _pin = '');

  Future<void> _tap(String d) async {
    if (_busy || !widget.enabled || _pin.length >= VaultStore.pinLength) return;
    HapticFeedback.selectionClick();
    setState(() => _pin += d);
    if (_pin.length == VaultStore.pinLength) {
      setState(() => _busy = true);
      try {
        await widget.onComplete(_pin);
      } finally {
        if (mounted) {
          setState(() {
            _busy = false;
            _pin = '';
          });
        }
      }
    }
  }

  void _back() {
    if (_busy || _pin.isEmpty) return;
    setState(() => _pin = _pin.substring(0, _pin.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget key(String label, {VoidCallback? onTap, Widget? child}) => SizedBox(
          width: 76,
          height: 76,
          child: TextButton(
            style: TextButton.styleFrom(shape: const CircleBorder()),
            onPressed: widget.enabled && !_busy ? onTap : null,
            child: child ?? Text(label, style: Theme.of(context).textTheme.headlineMedium),
          ),
        );

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var i = 0; i < VaultStore.pinLength; i++)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: 8),
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: i < _pin.length ? scheme.primary : null,
                  border: Border.all(color: scheme.outline, width: 1.5),
                ),
              ),
          ],
        ),
        SizedBox(
          height: 56,
          child: Center(
            child: _busy
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                : Text(
                    widget.message ?? '',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: widget.isError ? scheme.error : scheme.onSurfaceVariant),
                  ),
          ),
        ),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [for (final d in row) key(d, onTap: () => _tap(d))],
          ),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(width: 76),
            key('0', onTap: () => _tap('0')),
            key('', onTap: _back, child: const Icon(Icons.backspace_outlined)),
          ],
        ),
      ],
    );
  }
}

/// First run: choose a PIN, then type it again.
class SetupPinScreen extends StatefulWidget {
  const SetupPinScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<SetupPinScreen> createState() => _SetupPinScreenState();
}

class _SetupPinScreenState extends State<SetupPinScreen> {
  String? _first;
  String? _error;

  Future<void> _onPin(String pin) async {
    if (_first == null) {
      setState(() {
        _first = pin;
        _error = null;
      });
    } else if (pin == _first) {
      await widget.controller.setup(pin);
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
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.lock_outline, size: 40),
                const SizedBox(height: 12),
                Text(
                  'There is no PIN recovery. If you forget it, the only way back in '
                  'is to erase all links. Export a backup now and then.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 24),
                PinPad(
                  key: ValueKey(_first == null),
                  title: _first == null ? 'Choose a 6-digit PIN' : 'Type the PIN again',
                  message: _error,
                  isError: _error != null,
                  onComplete: _onPin,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Where the app always starts.
class LockScreen extends StatefulWidget {
  const LockScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  String? _message;
  bool _error = false;
  DateTime? _lockedUntil;
  Timer? _timer;
  int _inbox = 0;

  @override
  void initState() {
    super.initState();
    widget.controller.store.lockedUntil().then(_startLockout);
    widget.controller.store.inboxCount().then((n) {
      if (mounted) setState(() => _inbox = n);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _startLockout(DateTime? until) {
    _timer?.cancel();
    if (!mounted) return;
    setState(() => _lockedUntil = until);
    if (until == null) return;
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) return;
      if (DateTime.now().isAfter(until)) {
        t.cancel();
        setState(() {
          _lockedUntil = null;
          _message = null;
        });
      } else {
        setState(() {});
      }
    });
  }

  Future<void> _onPin(String pin) async {
    final r = await widget.controller.unlock(pin);
    if (!mounted) return;
    switch (r) {
      case Unlocked():
        break;
      case WrongPin(:final failures, :final lockedUntil):
        setState(() {
          _error = true;
          _message = lockedUntil == null
              ? 'Wrong PIN. ${5 - failures} more tries before a wait.'
              : 'Wrong PIN.';
        });
        _startLockout(lockedUntil);
      case LockedOut(:final until):
        _startLockout(until);
    }
  }

  Future<void> _forgot() async {
    final confirm = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Erase everything?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Without the PIN your links cannot be decrypted. Erasing deletes all '
                'links and tags on this phone and cannot be undone. You can then set '
                'a new PIN and import a backup.\n\nType ERASE to confirm.',
              ),
              TextField(controller: confirm, onChanged: (_) => setLocal(() {})),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
              onPressed: confirm.text.trim() == 'ERASE' ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Erase'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) await widget.controller.eraseEverything();
  }

  @override
  Widget build(BuildContext context) {
    final until = _lockedUntil;
    String? message = _message;
    if (until != null) {
      final left = until.difference(DateTime.now()).inSeconds + 1;
      message = 'Too many wrong PINs. Try again in ${left}s.';
    }
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                const Icon(Icons.lock_outline, size: 40),
                if (_inbox > 0) ...[
                  const SizedBox(height: 8),
                  Text('$_inbox shared link${_inbox == 1 ? '' : 's'} waiting'),
                ],
                const SizedBox(height: 24),
                PinPad(
                  title: 'Enter PIN',
                  message: message,
                  isError: _error || until != null,
                  enabled: until == null,
                  onComplete: _onPin,
                ),
                const SizedBox(height: 16),
                TextButton(onPressed: _forgot, child: const Text('Forgot PIN?')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
