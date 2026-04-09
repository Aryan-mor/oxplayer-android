import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../focus/focusable_button.dart';
import '../i18n/strings.g.dart';
import '../infrastructure/data_repository.dart';
import '../providers/auth_notifier.dart';
import '../services/auth_debug_service.dart';
import '../theme/mono_tokens.dart';
import '../utils/platform_detector.dart';

enum _TelegramLoginPath { unset, qr, phone }

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key});

  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  static const String _sessionStatusMessage = 'Signing into OXPlayer Cloud...';
  static const String _telegramWaitingMessage = 'Waiting for Telegram authentication...';

  DataRepository? _dataRepository;
  Future<void>? _authorizationAttempt;
  bool _backendBridgeCompleted = false;

  StreamSubscription<String?>? _qrSub;
  StreamSubscription<TdlibCloudPasswordChallenge?>? _cloudPasswordSub;
  StreamSubscription<TdlibSmsCodeChallenge?>? _smsCodeSub;
  StreamSubscription<bool>? _waitPhoneSub;
  StreamSubscription<String?>? _functionErrorSub;
  StreamSubscription<int>? _authenticatedUserSub;

  bool _isInitializing = true;
  bool _isAuthenticating = false;
  bool _isCloudSigningIn = false;
  bool _passwordSubmitting = false;
  bool _phoneSubmitting = false;
  bool _codeSubmitting = false;

  String? _errorMessage;
  String? _successMessage;
  String? _qrPayload;
  TdlibCloudPasswordChallenge? _cloudPasswordChallenge;
  TdlibSmsCodeChallenge? _smsCodeChallenge;
  bool _authorizationWaitPhoneNumber = false;
  _TelegramLoginPath _loginPath = _TelegramLoginPath.unset;

  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _initializeRepository();
  }

  Future<void> _initializeRepository() async {
    try {
      final repository = await DataRepository.create();
      if (!mounted) {
        await repository.dispose();
        return;
      }

      _dataRepository = repository;
      _listenToRepository(repository);

      setState(() {
        _isInitializing = false;
      });

      AuthDebugService.instance.reset();
      final restored = await repository.tryRestoreExistingTelegramSession();
      if (restored) {
        await _resumeExistingTelegramSession(skipAuthorization: true);
        return;
      }

      if (PlatformDetector.isTV()) {
        await _startQrAuthentication();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isInitializing = false;
        _errorMessage = error.toString();
      });
    }
  }

  void _listenToRepository(DataRepository repository) {
    _qrSub = repository.qrLoginPayload.listen((payload) {
      if (!mounted) return;
      setState(() {
        _qrPayload = payload;
      });
    });

    _cloudPasswordSub = repository.cloudPasswordChallenge.listen((challenge) {
      if (!mounted) return;
      setState(() {
        _cloudPasswordChallenge = challenge;
      });
    });

    _smsCodeSub = repository.smsCodeChallenge.listen((challenge) {
      if (!mounted) return;
      setState(() {
        _smsCodeChallenge = challenge;
      });
    });

    _waitPhoneSub = repository.authorizationWaitPhoneNumber.listen((waiting) {
      if (!mounted) return;
      setState(() {
        _authorizationWaitPhoneNumber = waiting;
      });
    });

    _functionErrorSub = repository.functionErrors.listen((message) {
      if (!mounted || message == null || message.isEmpty) return;
      authDebugError('Telegram error: $message');
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });

    _authenticatedUserSub = repository.authenticatedUserId.listen((_) {
      authDebugSuccess('Telegram user authenticated.', completeStatus: AuthDebugStatusKey.telegramAuthenticated);
      unawaited(_bridgeTelegramSessionToBackend());
    });
  }

  Future<void> _ensureAuthorizationStarted() async {
    final repository = _dataRepository;
    if (repository == null || _authorizationAttempt != null) return;

    setState(() {
      _isAuthenticating = true;
      _isCloudSigningIn = false;
      _errorMessage = null;
      _successMessage = null;
    });

    AuthDebugService.instance.reset();
    authDebugInfo('Starting a fresh Telegram sign-in flow...');

    final attempt = repository.beginTelegramAuthorization();
    _authorizationAttempt = attempt;

    attempt.catchError((Object error) {
      if (!mounted) return;
      setState(() {
        _isAuthenticating = false;
        _isCloudSigningIn = false;
        _authorizationAttempt = null;
        _successMessage = null;
        _errorMessage = error.toString();
      });
    });
  }

  Future<void> _bridgeTelegramSessionToBackend() async {
    final repository = _dataRepository;
    if (repository == null || _isCloudSigningIn || _backendBridgeCompleted) return;

    final authNotifier = context.read<AuthNotifier>();
    if (authNotifier.apiAccessToken != null && authNotifier.apiAccessToken!.isNotEmpty) {
      _backendBridgeCompleted = true;
      return;
    }

    setState(() {
      _isCloudSigningIn = true;
      _isAuthenticating = true;
      _errorMessage = null;
    });
    authDebugInfo('Starting OXPlayer backend auth bridge...');

    try {
      final result = await repository.authenticateWithTelegram();
      if (!mounted) return;

      await authNotifier.persistTelegramBackendSession(result);
      authDebugSuccess('Backend session persisted and app auth state updated.');
      _backendBridgeCompleted = true;

      if (!mounted) return;
      setState(() {
        _isAuthenticating = false;
        _isCloudSigningIn = false;
        _authorizationAttempt = null;
        _successMessage = 'Signed in with Telegram.';
        _errorMessage = null;
      });
    } catch (error) {
      authDebugError('Backend auth bridge failed: $error');
      if (!mounted) return;
      setState(() {
        _isAuthenticating = false;
        _isCloudSigningIn = false;
        _authorizationAttempt = null;
        _successMessage = null;
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _resumeExistingTelegramSession({bool skipAuthorization = false}) async {
    final repository = _dataRepository;
    if (repository == null || _backendBridgeCompleted) return;

    setState(() {
      _isAuthenticating = true;
      _isCloudSigningIn = false;
      _errorMessage = null;
      _successMessage = null;
    });
    authDebugInfo('Resuming previous Telegram session...');

    try {
      if (!skipAuthorization) {
        await repository.beginTelegramAuthorization();
      }
      await _bridgeTelegramSessionToBackend();
    } catch (error) {
      authDebugError('Failed to resume previous Telegram session: $error');
      if (!mounted) return;
      setState(() {
        _isAuthenticating = false;
        _isCloudSigningIn = false;
        _authorizationAttempt = null;
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _startQrAuthentication() async {
    final repository = _dataRepository;
    if (repository == null) return;

    setState(() {
      _loginPath = _TelegramLoginPath.qr;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      await _ensureAuthorizationStarted();
      await repository.startQrLogin();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isAuthenticating = false;
        _isCloudSigningIn = false;
        _authorizationAttempt = null;
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _startPhoneAuthentication() async {
    if (_dataRepository == null) return;

    setState(() {
      _loginPath = _TelegramLoginPath.phone;
      _errorMessage = null;
      _successMessage = null;
    });

    try {
      await _ensureAuthorizationStarted();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _errorMessage = error.toString();
      });
    }
  }

  Future<void> _submitPhoneNumber() async {
    final repository = _dataRepository;
    final phoneNumber = _phoneController.text.trim();
    if (repository == null || phoneNumber.isEmpty || _phoneSubmitting) return;

    setState(() {
      _phoneSubmitting = true;
    });

    try {
      await repository.submitAuthenticationPhoneNumber(phoneNumber);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Telegram: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _phoneSubmitting = false;
        });
      }
    }
  }

  Future<void> _submitCode() async {
    final repository = _dataRepository;
    final code = _codeController.text.trim();
    if (repository == null || code.isEmpty || _codeSubmitting) return;

    setState(() {
      _codeSubmitting = true;
    });

    try {
      await repository.submitAuthenticationCode(code);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Telegram: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _codeSubmitting = false;
        });
      }
    }
  }

  Future<void> _submitPassword() async {
    final repository = _dataRepository;
    final password = _passwordController.text;
    if (repository == null || password.isEmpty || _passwordSubmitting) return;

    setState(() {
      _passwordSubmitting = true;
    });

    try {
      await repository.submitCloudPassword(password);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Telegram: $error')));
    } finally {
      if (mounted) {
        setState(() {
          _passwordSubmitting = false;
        });
      }
    }
  }

  Future<void> _resetTelegramFlow() async {
    final repository = _dataRepository;
    if (repository == null) return;

    _passwordController.clear();
    _phoneController.clear();
    _codeController.clear();

    setState(() {
      _isAuthenticating = false;
      _isCloudSigningIn = false;
      _authorizationAttempt = null;
      _backendBridgeCompleted = false;
      _errorMessage = null;
      _successMessage = null;
      _qrPayload = null;
      _cloudPasswordChallenge = null;
      _smsCodeChallenge = null;
      _authorizationWaitPhoneNumber = false;
      _loginPath = _TelegramLoginPath.unset;
    });

    await repository.resetLocalSessionForQrLogin();
  }

  Widget _buildInitialButtons() {
    final isTV = PlatformDetector.isTV();

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Sign in with Telegram',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 16),
        if (isTV) ...[
          FocusableButton(
            autofocus: true,
            onPressed: _startQrAuthentication,
            child: ElevatedButton.icon(
              onPressed: _startQrAuthentication,
              style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              icon: const Icon(Icons.qr_code_2),
              label: const Text('With QR code'),
            ),
          ),
          const SizedBox(height: 12),
          FocusableButton(
            onPressed: _startPhoneAuthentication,
            child: OutlinedButton.icon(
              onPressed: _startPhoneAuthentication,
              style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              icon: const Icon(Icons.phone_iphone),
              label: const Text('With phone number'),
            ),
          ),
        ] else ...[
          ElevatedButton.icon(
            onPressed: _startQrAuthentication,
            style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            icon: const Icon(Icons.qr_code_2),
            label: const Text('With QR code'),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _startPhoneAuthentication,
            style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
            icon: const Icon(Icons.phone_iphone),
            label: const Text('With phone number'),
          ),
        ],
        if (_successMessage != null) ...[
          const SizedBox(height: 16),
          Text(
            _successMessage!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.primary),
          ),
        ],
        if (_errorMessage != null) ...[
          const SizedBox(height: 16),
          Text(
            _errorMessage!,
            textAlign: TextAlign.center,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
      ],
    );
  }

  Widget _buildQrAuthWidget({required double qrSize}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Scan this QR code with Telegram to sign in',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 24),
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(tokens(context).radiusMd),
            child: QrImageView(
              data: _qrPayload!,
              size: qrSize,
              version: QrVersions.auto,
              backgroundColor: Colors.white,
            ),
          ),
        ),
        const SizedBox(height: 24),
        OutlinedButton(
          onPressed: _resetTelegramFlow,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 24)),
          child: Text(t.common.retry),
        ),
      ],
    );
  }

  Widget _buildPhoneStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Enter your mobile number in international format.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _phoneController,
          keyboardType: TextInputType.phone,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Phone number',
          ),
          onSubmitted: (_) => unawaited(_submitPhoneNumber()),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _phoneSubmitting ? null : _submitPhoneNumber,
          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          child: _phoneSubmitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Send code'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _resetTelegramFlow,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          child: const Text('Back'),
        ),
      ],
    );
  }

  Widget _buildCodeStep() {
    final challenge = _smsCodeChallenge;
    final instruction = challenge == null || challenge.phoneNumber.isEmpty
        ? 'Enter the login code Telegram sent to your phone.'
        : 'Enter the login code Telegram sent to ${challenge.phoneNumber}.';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          instruction,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
        const SizedBox(height: 20),
        TextField(
          controller: _codeController,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Login code',
          ),
          onSubmitted: (_) => unawaited(_submitCode()),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _codeSubmitting ? null : _submitCode,
          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          child: _codeSubmitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Confirm code'),
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          onPressed: _resetTelegramFlow,
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          child: const Text('Back'),
        ),
      ],
    );
  }

  Widget _buildPasswordStep() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'This account uses two-step verification. Enter your Telegram password.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
        if (_cloudPasswordChallenge != null && _cloudPasswordChallenge!.hint.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(
            'Hint: ${_cloudPasswordChallenge!.hint}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.grey),
          ),
        ],
        const SizedBox(height: 20),
        TextField(
          controller: _passwordController,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            labelText: 'Password',
          ),
          onSubmitted: (_) => unawaited(_submitPassword()),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _passwordSubmitting ? null : _submitPassword,
          style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
          child: _passwordSubmitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Continue'),
        ),
      ],
    );
  }

  Widget _buildProgressState() {
    final message = _isCloudSigningIn ? _sessionStatusMessage : _telegramWaitingMessage;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 16),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildLoadingState() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text(
          _sessionStatusMessage,
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      ],
    );
  }

  Widget _buildAuthContent({required double qrSize}) {
    final showQr = _cloudPasswordChallenge == null &&
        _smsCodeChallenge == null &&
        _qrPayload != null &&
        _qrPayload!.isNotEmpty;
    final showCode = _cloudPasswordChallenge == null && _smsCodeChallenge != null;
    final showPhone = _cloudPasswordChallenge == null &&
        _smsCodeChallenge == null &&
        !showQr &&
        _authorizationWaitPhoneNumber &&
        _loginPath == _TelegramLoginPath.phone;
    final showProgress = _isAuthenticating && !showQr && !showCode && !showPhone && _cloudPasswordChallenge == null;

    if (_isInitializing) {
      return _buildLoadingState();
    }
    if (_cloudPasswordChallenge != null) {
      return _buildPasswordStep();
    }
    if (showQr) {
      return _buildQrAuthWidget(qrSize: qrSize);
    }
    if (showCode) {
      return _buildCodeStep();
    }
    if (showPhone) {
      return _buildPhoneStep();
    }
    if (showProgress) {
      return _buildProgressState();
    }
    return _buildInitialButtons();
  }

  @override
  void dispose() {
    unawaited(_qrSub?.cancel());
    unawaited(_cloudPasswordSub?.cancel());
    unawaited(_smsCodeSub?.cancel());
    unawaited(_waitPhoneSub?.cancel());
    unawaited(_functionErrorSub?.cancel());
    unawaited(_authenticatedUserSub?.cancel());
    unawaited(_dataRepository?.dispose());
    _passwordController.dispose();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop = MediaQuery.of(context).size.width > 700;

    return Scaffold(
      body: Center(
        child: Container(
          constraints: BoxConstraints(maxWidth: isDesktop ? 800 : 400),
          padding: const EdgeInsets.all(24),
          child: isDesktop
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Image.asset('assets/plezy.png', width: 120, height: 120),
                          const SizedBox(height: 24),
                          Text(
                            t.app.title,
                            style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 48),
                    Expanded(
                      child: Center(
                        child: SingleChildScrollView(
                          child: _buildAuthContent(qrSize: 300),
                        ),
                      ),
                    ),
                  ],
                )
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Image.asset('assets/plezy.png', width: 120, height: 120),
                      const SizedBox(height: 24),
                      Text(
                        t.app.title,
                        style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 48),
                      _buildAuthContent(qrSize: 200),
                    ],
                  ),
                ),
        ),
      ),
    );
  }
}
