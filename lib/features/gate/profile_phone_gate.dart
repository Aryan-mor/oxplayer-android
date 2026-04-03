import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/auth/auth_notifier.dart';
import '../../providers.dart';
import '../../router.dart';

/// After server auth, blocks with a one-time dialog until a phone number is saved.
class ProfilePhoneGate extends ConsumerStatefulWidget {
  const ProfilePhoneGate({super.key, required this.child});

  final Widget child;

  @override
  ConsumerState<ProfilePhoneGate> createState() => _ProfilePhoneGateState();
}

class _ProfilePhoneGateState extends ConsumerState<ProfilePhoneGate> {
  bool _dialogCycle = false;

  bool _needsPrompt(AuthNotifier auth) {
    return auth.ready &&
        auth.isLoggedIn &&
        auth.hasServerUserProfile &&
        auth.needsPhoneNumber;
  }

  Future<void> _openDialog() async {
    if (_dialogCycle) return;
    final navCtx = rootNavigatorKey.currentContext;
    if (navCtx == null || !navCtx.mounted) return;

    _dialogCycle = true;
    try {
      await showDialog<void>(
        context: navCtx,
        barrierDismissible: false,
        builder: (dialogCtx) => _PhoneCaptureDialog(
          onSubmit: (phone) async {
            final auth = ref.read(authNotifierProvider);
            final token = auth.apiAccessToken;
            if (token == null || token.isEmpty) {
              throw StateError('Not signed in');
            }
            final config = ref.read(appConfigProvider);
            final api = ref.read(tvAppApiServiceProvider);
            final userMap = await api.patchMeProfile(
              config: config,
              accessToken: token,
              phoneNumber: phone,
            );
            await ref.read(authNotifierProvider).mergeServerUserJson(userMap);
            if (dialogCtx.mounted) {
              Navigator.of(dialogCtx).pop();
            }
          },
        ),
      );
    } finally {
      _dialogCycle = false;
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authNotifierProvider, (prev, next) {
      if (!_needsPrompt(next)) return;
      if (_dialogCycle) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_needsPrompt(ref.read(authNotifierProvider))) return;
        if (_dialogCycle) return;
        unawaited(_openDialog());
      });
    });

    return widget.child;
  }
}

class _PhoneCaptureDialog extends StatefulWidget {
  const _PhoneCaptureDialog({required this.onSubmit});

  final Future<void> Function(String phone) onSubmit;

  @override
  State<_PhoneCaptureDialog> createState() => _PhoneCaptureDialogState();
}

class _PhoneCaptureDialogState extends State<_PhoneCaptureDialog> {
  final _controller = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final raw = _controller.text.trim();
    if (raw.length < 5) {
      setState(() => _error = 'Enter at least 5 digits (country code included).');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(raw);
    } on DioException catch (e) {
      final msg = e.response?.data;
      String text = 'Could not save. Try again.';
      if (msg is Map && msg['message'] != null) {
        text = msg['message'].toString();
      } else if (e.message != null && e.message!.isNotEmpty) {
        text = e.message!;
      }
      if (mounted) {
        setState(() {
          _busy = false;
          _error = text;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Mobile number'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Your account does not have a phone number yet. '
              'Enter a mobile number so we can reach you (include country code, e.g. +98…).',
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              autofocus: true,
              enabled: !_busy,
              keyboardType: TextInputType.phone,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9+]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Phone number',
                hintText: '+989123456789',
              ),
              onSubmitted: (_) {
                if (!_busy) {
                  unawaited(_submit());
                }
              },
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.error,
                  fontSize: 13,
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Submit'),
        ),
      ],
    );
  }
}
