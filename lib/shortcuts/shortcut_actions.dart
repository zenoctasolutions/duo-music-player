import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// Launcher-shortcut actions coming from Kotlin (AppShortcuts.kt).
/// 'shuffle_all' and 'search' are delivered here; the 'Resume' shortcut is
/// handled natively through the existing widget "play" path.
///
/// Usage (one hook in the songs page State, after the library is ready):
///   ShortcutActions.instance.attach((a) { ... });   // initState / post-frame
///   ShortcutActions.instance.detach();              // dispose
class ShortcutActions with WidgetsBindingObserver {
  ShortcutActions._();
  static final ShortcutActions instance = ShortcutActions._();

  static const _channel = MethodChannel('music_app/system');

  /// Latest un-handled action, also usable as a Listenable.
  final ValueNotifier<String?> pending = ValueNotifier<String?>(null);

  ValueChanged<String>? _handler;
  bool _observing = false;

  /// Starts listening; immediately drains a cold-start action.
  void attach(ValueChanged<String> handler) {
    _handler = handler;
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    unawaited(poll());
  }

  void detach() {
    _handler = null;
    if (_observing) {
      WidgetsBinding.instance.removeObserver(this);
      _observing = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A shortcut tapped while the app is running brings it to the front.
    if (state == AppLifecycleState.resumed) unawaited(poll());
  }

  Future<void> poll() async {
    String? action;
    try {
      action = await _channel.invokeMethod<String>('takeShortcutAction');
    } catch (_) {
      return;
    }
    if (action == null || action.isEmpty) return;
    pending.value = action;
    _handler?.call(action);
  }
}
