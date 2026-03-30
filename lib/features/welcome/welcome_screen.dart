import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/auth/auth_notifier.dart';
import '../../core/debug/app_debug_log.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/tv_button.dart';
import '../../providers.dart';
import '../../telegram/tdlib_facade.dart';

/// Pulls `tg://` link from TDLib JSON maps (same shape as [TdObject.toJson]).
String? _qrLinkFromTdlibUpdateMap(Map<String, dynamic> doc) {
  if (doc['@type'] != 'updateAuthorizationState') return null;
  final auth = doc['authorization_state'];
  if (auth is! Map<String, dynamic>) return null;
  if (auth['@type'] != 'authorizationStateWaitOtherDeviceConfirmation') {
    return null;
  }
  final link = auth['link'];
  if (link is String && link.isNotEmpty) return link;
  return null;
}

void _applyAuthSideEffectsFromMap(
    Map<String, dynamic> doc, void Function(String? link) setQr) {
  if (doc['@type'] != 'updateAuthorizationState') return;
  final auth = doc['authorization_state'];
  if (auth is! Map<String, dynamic>) return;
  final t = auth['@type'] as String?;
  final link = _qrLinkFromTdlibUpdateMap(doc);
  if (link != null) {
    setQr(link);
    return;
  }
  if (t == 'authorizationStateReady' ||
      t == 'authorizationStateWaitPhoneNumber') {
    if (t == 'authorizationStateReady') setQr(null);
  }
}

/// Shown when the user is not logged in: TDLib starts automatically, then QR or 2FA.
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  StreamSubscription<String?>? _qrSub;
  StreamSubscription<TdlibCloudPasswordChallenge?>? _cloudPwdSub;
  StreamSubscription<int>? _authSub;
  StreamSubscription<String?>? _tdErrSub;
  StreamSubscription<Map<String, dynamic>>? _updatesSub;
  String? _qrData;
  TdlibCloudPasswordChallenge? _cloudPasswordStep;
  final TextEditingController _passwordController = TextEditingController();
  bool _tdlibBusy = false;
  bool _passwordSubmitting = false;
  String? _configError;

  void _setQr(String? link) {
    if (!mounted) return;
    if (kDebugMode) {
      if (link != null && link.isNotEmpty) {
        AppDebugLog.instance.log('Welcome: QR payload len=${link.length}');
      } else {
        AppDebugLog.instance.log('Welcome: QR payload cleared');
      }
    }
    setState(() => _qrData = link);
  }

  void _setCloudPasswordStep(TdlibCloudPasswordChallenge? step) {
    if (!mounted) return;
    setState(() => _cloudPasswordStep = step);
  }

  Future<void> _bootstrapTelegram() async {
    if (!mounted) return;

    final config = ref.read(appConfigProvider);
    final apiId = int.tryParse(config.telegramApiId) ?? 0;
    if (!config.hasTelegramKeys || apiId <= 0) {
      setState(() {
        _configError =
            'Configure TELEGRAM_API_ID and TELEGRAM_API_HASH in assets/env/default.env.';
      });
      return;
    }

    setState(() {
      _configError = null;
      _tdlibBusy = true;
      _qrData = null;
    });

    AppDebugLog.instance.log('Welcome: bootstrap TDLib init…');
    try {
      final auth = ref.read(authNotifierProvider);
      if (auth.isLoggedIn) {
        AppDebugLog.instance
            .log('Welcome: skipping bootstrap, session already exists');
        return;
      }

      final tdlib = ref.read(tdlibFacadeProvider);
      await tdlib.init(
        apiId: apiId,
        apiHash: config.telegramApiHash,
        sessionString: '',
      );
      AppDebugLog.instance.log('Welcome: TDLib init() returned');
    } catch (e) {
      if (mounted) {
        AppDebugLog.instance.log('Welcome: TDLib init FAILED: $e');
        setState(() => _configError = 'TDLib: $e');
      }
    } finally {
      if (mounted) setState(() => _tdlibBusy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      _configError = 'Telegram sign-in is not available in this build.';
    }
    final facade = ref.read(tdlibFacadeProvider);
    _qrSub = facade.qrLoginPayload.listen(_setQr);
    _cloudPwdSub = facade.cloudPasswordChallenge.listen(_setCloudPasswordStep);
    _authSub = facade.authenticatedUserId.listen((_) {
      if (!mounted) return;
      context.go('/');
    });
    _tdErrSub = facade.functionErrors.listen((msg) {
      if (!mounted || msg == null || msg.isEmpty) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    });
    _updatesSub = facade.updates().listen((doc) {
      _applyAuthSideEffectsFromMap(doc, _setQr);
    });

    if (!kIsWeb) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        // 1. Wait for AuthNotifier to hydrate from SharedPreferences
        AuthNotifier auth = ref.read(authNotifierProvider);
        if (!auth.ready) {
          AppDebugLog.instance
              .log('Welcome: waiting for AuthNotifier to hydrate…');
          final completer = Completer<void>();
          void listener() {
            if (ref.read(authNotifierProvider).ready) {
              completer.complete();
            }
          }

          ref.read(authNotifierProvider).addListener(listener);
          await completer.future;
          ref.read(authNotifierProvider).removeListener(listener);
          auth = ref.read(authNotifierProvider);
        }

        // 2. One more post-frame hack to allow TeleCimaApp listener to finish session processing
        await Future<void>.delayed(const Duration(milliseconds: 100));
        auth = ref.read(authNotifierProvider);

        if (!auth.isLoggedIn && mounted) {
          unawaited(_bootstrapTelegram());
        } else {
          AppDebugLog.instance.log(
              'Welcome: session active (isLoggedIn=${auth.isLoggedIn}), skipping bootstrap');
        }
      });
    }
  }

  @override
  void dispose() {
    unawaited(_qrSub?.cancel());
    unawaited(_cloudPwdSub?.cancel());
    unawaited(_authSub?.cancel());
    unawaited(_tdErrSub?.cancel());
    unawaited(_updatesSub?.cancel());
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _onSubmitCloudPassword() async {
    final pwd = _passwordController.text;
    if (pwd.isEmpty || _cloudPasswordStep == null) return;
    setState(() => _passwordSubmitting = true);
    try {
      await ref.read(tdlibFacadeProvider).submitCloudPassword(pwd);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Telegram: $e')),
      );
    } finally {
      if (mounted) setState(() => _passwordSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final link = _qrData;
    final pwdStep = _cloudPasswordStep;
    final showQr =
        !kIsWeb && pwdStep == null && link != null && link.isNotEmpty;
    final showAuthProgress =
        !kIsWeb && _configError == null && pwdStep == null && !showQr;

    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Scaffold(
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: Card(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'TeleCima',
                      style:
                          TextStyle(fontSize: 40, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    if (_configError != null) ...[
                      Text(
                        _configError!,
                        style: const TextStyle(
                            color: Colors.redAccent, fontSize: 15, height: 1.4),
                        textAlign: TextAlign.center,
                      ),
                    ] else ...[
                      Text(
                        pwdStep != null
                            ? 'This account uses two-step verification. Enter your Telegram password.'
                            : 'Sign in with Telegram. Scan the QR code with your phone.',
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 16,
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (!kIsWeb && pwdStep != null) ...[
                      const SizedBox(height: 20),
                      if (pwdStep.hint.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(
                            'Hint: ${pwdStep.hint}',
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 14),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(0),
                        child: TextField(
                          controller: _passwordController,
                          obscureText: true,
                          autofocus: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Password',
                          ),
                          onSubmitted: (_) =>
                              unawaited(_onSubmitCloudPassword()),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(1),
                        child: TVButton(
                          autofocus: true,
                          onPressed: _passwordSubmitting
                              ? null
                              : () => unawaited(_onSubmitCloudPassword()),
                          child: _passwordSubmitting
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Confirm password'),
                        ),
                      ),
                    ],
                    if (showQr) ...[
                      const SizedBox(height: 24),
                      ExcludeFocus(
                        child: Container(
                          padding: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: QrImageView(
                            data: link,
                            size: 280,
                            backgroundColor: Colors.white,
                            errorCorrectionLevel: QrErrorCorrectLevel.M,
                            gapless: true,
                            errorStateBuilder: (context, err) {
                              AppDebugLog.instance
                                  .log('QrImageView build error: $err');
                              return Padding(
                                padding: const EdgeInsets.all(16),
                                child: Text(
                                  'QR render error: $err',
                                  style: const TextStyle(
                                      color: Colors.red, fontSize: 12),
                                  textAlign: TextAlign.center,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      if (kDebugMode) ...[
                        const SizedBox(height: 12),
                        SelectableText(
                          link,
                          style: const TextStyle(
                              fontSize: 11, color: AppColors.textMuted),
                        ),
                      ],
                    ],
                    if (showAuthProgress) ...[
                      const SizedBox(height: 28),
                      const SizedBox(
                        height: 28,
                        width: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        _tdlibBusy
                            ? 'Connecting to Telegram…'
                            : 'Preparing QR code…',
                        style: const TextStyle(
                            color: AppColors.textMuted, fontSize: 14),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
