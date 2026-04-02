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
import '../../core/update/app_update_notifier.dart';
import '../../providers.dart';
import '../../telegram/tdlib_facade.dart';

void _welcomeLog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.app);

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

String _loginCodeInstruction(TdlibSmsCodeChallenge? s) {
  if (s == null || s.phoneNumber.isEmpty) {
    return 'Enter the login code Telegram sent to your phone.';
  }
  return 'Enter the login code Telegram sent to ${s.phoneNumber}.';
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
  if (t == 'authorizationStateReady') {
    setQr(null);
  }
}

enum _WelcomeLoginPath { unset, qr, phone }

/// Shown when the user is not logged in: TDLib starts automatically, then QR or 2FA.
class WelcomeScreen extends ConsumerStatefulWidget {
  const WelcomeScreen({super.key});

  @override
  ConsumerState<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends ConsumerState<WelcomeScreen> {
  StreamSubscription<String?>? _qrSub;
  StreamSubscription<TdlibCloudPasswordChallenge?>? _cloudPwdSub;
  StreamSubscription<TdlibSmsCodeChallenge?>? _smsSub;
  StreamSubscription<bool>? _waitPhoneSub;
  StreamSubscription<int>? _authSub;
  StreamSubscription<String?>? _tdErrSub;
  StreamSubscription<Map<String, dynamic>>? _updatesSub;
  String? _qrData;
  TdlibCloudPasswordChallenge? _cloudPasswordStep;
  TdlibSmsCodeChallenge? _smsChallenge;
  bool _authWaitPhoneNumber = false;
  _WelcomeLoginPath _loginPath = _WelcomeLoginPath.unset;
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _loginCodeController = TextEditingController();
  bool _tdlibBusy = false;
  bool _serverAuthBusy = false;
  bool _passwordSubmitting = false;
  bool _phoneSubmitting = false;
  bool _codeSubmitting = false;
  String? _configError;

  void _setQr(String? link) {
    if (!mounted) return;
    if (kDebugMode) {
      if (link != null && link.isNotEmpty) {
        _welcomeLog('Welcome: QR payload len=${link.length}');
      } else {
        _welcomeLog('Welcome: QR payload cleared');
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
      _loginPath = _WelcomeLoginPath.unset;
    });

    _welcomeLog('Welcome: bootstrap TDLib init…');
    try {
      final auth = ref.read(authNotifierProvider);
      if (auth.hasTelegramSession) {
        _welcomeLog('Welcome: skipping bootstrap, session already exists');
        return;
      }

      final tdlib = ref.read(tdlibFacadeProvider);
      if (tdlib.isInitialized) {
        _welcomeLog(
          'Welcome: TDLib already initialized — skipping init (prevents td.binlog lock)',
        );
        return;
      }

      await tdlib.init(
        apiId: apiId,
        apiHash: config.telegramApiHash,
        sessionString: '',
      );
      _welcomeLog('Welcome: TDLib init() returned');
    } catch (e) {
      if (mounted) {
        _welcomeLog('Welcome: TDLib init FAILED: $e');
        setState(() => _configError = 'TDLib: $e');
      }
    } finally {
      if (mounted) setState(() => _tdlibBusy = false);
    }
  }

  Future<void> _ensureServerAuthAndEnterHome() async {
    if (!mounted || _serverAuthBusy) return;
    setState(() => _serverAuthBusy = true);
    try {
      final config = ref.read(appConfigProvider);
      if (!config.hasApiConfig) {
        throw StateError(
          'TV_APP_API_BASE_URL and one of TV_APP_WEBAPP_SHORT_NAME / TV_APP_WEBAPP_URL must be set in assets/env/default.env',
        );
      }
      final tdlib = ref.read(tdlibFacadeProvider);
      await tdlib.ensureAuthorized();
      final api = ref.read(tvAppApiServiceProvider);
      final accessToken =
          await api.authenticateWithTelegram(tdlib: tdlib, config: config);
      await ref.read(authNotifierProvider).setApiAccessToken(accessToken);
      if (!mounted) return;
      context.go('/');
    } catch (e) {
      _welcomeLog('Welcome: server auth failed: $e');
      if (!mounted) return;
      setState(() => _configError = 'Server auth failed: $e');
    } finally {
      if (mounted) setState(() => _serverAuthBusy = false);
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
    _smsSub = facade.smsCodeChallenge.listen((c) {
      if (!mounted) return;
      setState(() => _smsChallenge = c);
    });
    _waitPhoneSub = facade.authorizationWaitPhoneNumber.listen((v) {
      if (!mounted) return;
      setState(() => _authWaitPhoneNumber = v);
    });
    _authSub = facade.authenticatedUserId.listen((_) {
      unawaited(_ensureServerAuthAndEnterHome());
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
          _welcomeLog('Welcome: waiting for AuthNotifier to hydrate…');
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

        await ref.read(appUpdateNotifierProvider.notifier).waitUntilGateReleased();
        if (!mounted) return;

        if (!auth.hasTelegramSession && mounted) {
          unawaited(_bootstrapTelegram());
        } else {
          _welcomeLog(
              'Welcome: Telegram session active (hasTelegramSession=${auth.hasTelegramSession}), ensuring server auth');
          unawaited(_ensureServerAuthAndEnterHome());
        }
      });
    }
  }

  @override
  void dispose() {
    unawaited(_qrSub?.cancel());
    unawaited(_cloudPwdSub?.cancel());
    unawaited(_smsSub?.cancel());
    unawaited(_waitPhoneSub?.cancel());
    unawaited(_authSub?.cancel());
    unawaited(_tdErrSub?.cancel());
    unawaited(_updatesSub?.cancel());
    _passwordController.dispose();
    _phoneController.dispose();
    _loginCodeController.dispose();
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

  Future<void> _onPickQrLogin() async {
    if (_loginPath != _WelcomeLoginPath.unset) return;
    setState(() => _loginPath = _WelcomeLoginPath.qr);
    try {
      await ref.read(tdlibFacadeProvider).startQrLogin();
    } catch (e) {
      if (!mounted) return;
      setState(() => _loginPath = _WelcomeLoginPath.unset);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Telegram: $e')),
      );
    }
  }

  void _onPickPhoneLogin() {
    if (_loginPath != _WelcomeLoginPath.unset) return;
    setState(() => _loginPath = _WelcomeLoginPath.phone);
  }

  Future<void> _onSubmitPhoneNumber() async {
    final raw = _phoneController.text.trim();
    if (raw.isEmpty || _phoneSubmitting) return;
    setState(() => _phoneSubmitting = true);
    try {
      await ref.read(tdlibFacadeProvider).submitAuthenticationPhoneNumber(raw);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Telegram: $e')),
      );
    } finally {
      if (mounted) setState(() => _phoneSubmitting = false);
    }
  }

  Future<void> _onSubmitLoginCode() async {
    final raw = _loginCodeController.text.trim();
    if (raw.isEmpty || _codeSubmitting) return;
    setState(() => _codeSubmitting = true);
    try {
      await ref.read(tdlibFacadeProvider).submitAuthenticationCode(raw);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Telegram: $e')),
      );
    } finally {
      if (mounted) setState(() => _codeSubmitting = false);
    }
  }

  /// Returns to QR vs phone choice. Must wipe local TDLib DB: otherwise the next
  /// [init] reloads [AuthorizationStateWaitOtherDeviceConfirmation] from disk and
  /// only the QR link rotates (same screen).
  Future<void> _recycleTdlibForMethodChoice() async {
    if (!mounted || _tdlibBusy) return;
    final config = ref.read(appConfigProvider);
    final apiId = int.tryParse(config.telegramApiId) ?? 0;
    if (!config.hasTelegramKeys || apiId <= 0) return;

    setState(() {
      _tdlibBusy = true;
      _configError = null;
      _qrData = null;
      _loginPath = _WelcomeLoginPath.unset;
      _loginCodeController.clear();
    });
    try {
      final tdlib = ref.read(tdlibFacadeProvider);
      await tdlib.resetLocalSessionForQrLogin();
      await tdlib.init(
        apiId: apiId,
        apiHash: config.telegramApiHash,
        sessionString: '',
      );
    } catch (e) {
      if (mounted) {
        _welcomeLog('Welcome: recycle TDLib failed: $e');
        setState(() => _configError = 'TDLib: $e');
      }
    } finally {
      if (mounted) setState(() => _tdlibBusy = false);
    }
  }

  void _onBackFromPhoneStep() {
    if (_phoneSubmitting || _tdlibBusy) return;
    setState(() {
      _loginPath = _WelcomeLoginPath.unset;
      _phoneController.clear();
    });
  }

  void _onBackFromCodeStep() {
    if (_codeSubmitting || _tdlibBusy) return;
    setState(() {
      _loginPath = _WelcomeLoginPath.phone;
      _loginCodeController.clear();
    });
  }

  Future<void> _onBackFromQrStep() async {
    if (_tdlibBusy) return;
    await _recycleTdlibForMethodChoice();
  }

  @override
  Widget build(BuildContext context) {
    final link = _qrData;
    final pwdStep = _cloudPasswordStep;
    final sms = _smsChallenge;
    final showQr =
        !kIsWeb && pwdStep == null && sms == null && link != null && link.isNotEmpty;
    final showCodeStep =
        !kIsWeb && pwdStep == null && sms != null;
    final showPhoneStep = !kIsWeb &&
        pwdStep == null &&
        sms == null &&
        !showQr &&
        _configError == null &&
        _authWaitPhoneNumber &&
        _loginPath == _WelcomeLoginPath.phone;
    final showMethodChoice = !kIsWeb &&
        pwdStep == null &&
        sms == null &&
        !showQr &&
        _configError == null &&
        _authWaitPhoneNumber &&
        _loginPath == _WelcomeLoginPath.unset;
    final showAuthProgress = !kIsWeb &&
        _configError == null &&
        pwdStep == null &&
        !showQr &&
        !showCodeStep &&
        !showPhoneStep &&
        !showMethodChoice;

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
                    Image.asset(
                      'assets/icon.png',
                      width: 88,
                      height: 88,
                      filterQuality: FilterQuality.high,
                    ),
                    const SizedBox(height: 16),
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
                            : showAuthProgress
                                ? 'Setting up Telegram sign-in…'
                                : showCodeStep
                                    ? _loginCodeInstruction(sms)
                                    : showPhoneStep
                                        ? 'Enter your mobile number in international format (for example +98912xxxxxxx).'
                                        : showMethodChoice
                                            ? 'Sign in with Telegram. Choose QR code or phone number.'
                                            : 'Sign in with Telegram. Scan the QR code with your phone.',
                        style: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 16,
                          height: 1.4,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    if (!kIsWeb && showMethodChoice) ...[
                      const SizedBox(height: 28),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(0),
                        child: TVButton(
                          autofocus: true,
                          onPressed: _onPickQrLogin,
                          child: const Text('Sign in with QR code'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(1),
                        child: TVButton(
                          onPressed: _onPickPhoneLogin,
                          child: const Text('Sign in with phone number'),
                        ),
                      ),
                    ],
                    if (!kIsWeb && showPhoneStep) ...[
                      const SizedBox(height: 20),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(0),
                        child: TextField(
                          controller: _phoneController,
                          keyboardType: TextInputType.phone,
                          autofocus: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Phone number',
                          ),
                          onSubmitted: (_) =>
                              unawaited(_onSubmitPhoneNumber()),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(1),
                        child: TVButton(
                          onPressed: _phoneSubmitting
                              ? null
                              : () => unawaited(_onSubmitPhoneNumber()),
                          child: _phoneSubmitting
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Send code'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(2),
                        child: TVButton(
                          onPressed: (_phoneSubmitting || _tdlibBusy)
                              ? null
                              : _onBackFromPhoneStep,
                          child: const Text('Back'),
                        ),
                      ),
                    ],
                    if (!kIsWeb && showCodeStep) ...[
                      const SizedBox(height: 20),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(0),
                        child: TextField(
                          controller: _loginCodeController,
                          keyboardType: TextInputType.number,
                          autofocus: true,
                          decoration: const InputDecoration(
                            border: OutlineInputBorder(),
                            labelText: 'Login code',
                          ),
                          onSubmitted: (_) =>
                              unawaited(_onSubmitLoginCode()),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(1),
                        child: TVButton(
                          onPressed: _codeSubmitting
                              ? null
                              : () => unawaited(_onSubmitLoginCode()),
                          child: _codeSubmitting
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Confirm code'),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(2),
                        child: TVButton(
                          onPressed: (_codeSubmitting || _tdlibBusy)
                              ? null
                              : _onBackFromCodeStep,
                          child: const Text('Back'),
                        ),
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
                              _welcomeLog('QrImageView build error: $err');
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
                      const SizedBox(height: 20),
                      FocusTraversalOrder(
                        order: const NumericFocusOrder(0),
                        child: TVButton(
                          onPressed:
                              _tdlibBusy ? null : () => unawaited(_onBackFromQrStep()),
                          child: _tdlibBusy
                              ? const SizedBox(
                                  height: 22,
                                  width: 22,
                                  child:
                                      CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const Text('Back'),
                        ),
                      ),
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
                        (_tdlibBusy || _serverAuthBusy)
                            ? 'Connecting to Telegram…'
                            : 'Starting Telegram…',
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
