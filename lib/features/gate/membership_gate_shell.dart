import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:tdlib/td_api.dart' as td;

import '../../core/debug/app_debug_log.dart';
import '../../core/debug/layout_probe.dart';
import '../../providers.dart';
import '../../services/membership_service.dart';

/// Hard-blocks the child until required channel + bot membership is satisfied (auto-heal).
class MembershipGateShell extends ConsumerStatefulWidget {
  const MembershipGateShell({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<MembershipGateShell> createState() =>
      _MembershipGateShellState();
}

class _MembershipGateShellState extends ConsumerState<MembershipGateShell> {
  bool _running = true;
  String? _error;
  String? _lastLoggedGatePhase;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final config = ref.read(appConfigProvider);
    if (config.requiredChannelUsername.trim().isEmpty &&
        config.providerBotUsername.trim().isEmpty &&
        config.botUsername.trim().isEmpty) {
      AppDebugLog.instance.log(
        'MembershipGateShell: no mandatory channel/bots configured — skip gate',
        category: AppDebugLogCategory.membership,
      );
      setState(() {
        _running = false;
        _error = null;
      });
      return;
    }

    setState(() {
      _running = true;
      _error = null;
    });
    try {
      AppDebugLog.instance.log(
        'MembershipGateShell: running gate channel="${config.requiredChannelUsername}" '
        'bot="${config.botUsername}" secondBot="${config.providerBotUsername}"',
        category: AppDebugLogCategory.membership,
      );
      // Let TDLib finish post-auth updates before a burst of chat/member requests (reduces native crashes on some builds).
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (!mounted) return;
      final td = ref.read(tdlibFacadeProvider);
      final ok = await ensureMembershipRequirements(tdlib: td, config: config);
      if (!mounted) return;
      if (!ok) {
        AppDebugLog.instance.log(
          'MembershipGateShell: verify failed — showing Retry',
          category: AppDebugLogCategory.membership,
        );
        setState(() {
          _running = false;
          _error =
              'Join the required channel and open each bot (tap Start if shown), then tap Retry.';
        });
        return;
      }
      AppDebugLog.instance.log(
        'MembershipGateShell: gate passed',
        category: AppDebugLogCategory.membership,
      );
      setState(() {
        _running = false;
        _error = null;
      });
    } catch (e, st) {
      AppDebugLog.instance.log(
        'MembershipGateShell: exception: $e\n$st',
        category: AppDebugLogCategory.membership,
      );
      if (!mounted) return;
      final message = e is td.TdError ? '${e.message} (${e.code})' : e.toString();
      setState(() {
        _running = false;
        _error = message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final phase = _running ? 'running' : (_error != null ? 'error' : 'child');
    if (kDebugMode && phase != _lastLoggedGatePhase) {
      _lastLoggedGatePhase = phase;
      AppDebugLog.instance.log(
        'MembershipGateShell.build: phase=$phase',
        category: AppDebugLogCategory.membership,
      );
    }

    if (_running) {
      return const LayoutProbe(
        label: 'gate_running',
        child: Scaffold(
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Preparing Telegram access…'),
              ],
            ),
          ),
        ),
      );
    }
    if (_error != null) {
      return LayoutProbe(
        label: 'gate_error',
        child: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Could not complete required Telegram setup.\n$_error',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _run,
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    return LayoutProbe(
      label: 'gate_home_child',
      child: widget.child,
    );
  }
}

