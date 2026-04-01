import 'package:tdlib/td_api.dart' as td;

/// TDLib needs QR / phone login again; [ensureAuthorized] will not complete until [AuthorizationStateReady].
class TdlibInteractiveLoginRequired implements Exception {
  const TdlibInteractiveLoginRequired();

  @override
  String toString() =>
      'Telegram session is not ready (scan QR on the welcome screen).';
}

/// Shown when TDLib enters `authorizationStateWaitPassword` (Telegram two-step / cloud password).
class TdlibCloudPasswordChallenge {
  const TdlibCloudPasswordChallenge({required this.hint});

  /// May be empty if the user did not set a hint.
  final String hint;
}

/// TDLib is in `authorizationStateWaitCode` after the login code was sent to the phone.
class TdlibSmsCodeChallenge {
  const TdlibSmsCodeChallenge({
    required this.phoneNumber,
    required this.resendTimeoutSeconds,
  });

  final String phoneNumber;
  final int resendTimeoutSeconds;
}

/// Contract for the Telegram layer. Implement with **TDLib** (JSON interface via FFI),
/// e.g. [`libtdjson`](https://pub.dev/packages/libtdjson), instead of GramJS.
///
/// Responsibilities:
/// - Session management (QR / phone / string session parity with `tv-app-old`)
/// - Sync: fetch dialogs/messages for the configured index tag
/// - File access: feed byte ranges into [TelegramChunkReader] for playback
abstract class TdlibFacade {
  bool get isInitialized;

  Future<void> init({
    required int apiId,
    required String apiHash,
    required String sessionString,
  });

  /// Completes when [AuthorizationStateReady] + [getMe] is done.
  Future<void> ensureAuthorized();

  /// Emits TDLib `Update` objects (decoded JSON maps) for the app to route.
  Stream<Map<String, dynamic>> updates();

  /// Send an arbitrary TDLib request and await its specific response.
  Future<td.TdObject> send(td.TdFunction request);

  /// `tg://...` link for QR login while [AuthorizationStateWaitOtherDeviceConfirmation] is active; `null` when cleared.
  Stream<String?> get qrLoginPayload;

  /// After QR scan, accounts with two-step verification need a password; non-null means show password UI.
  Stream<TdlibCloudPasswordChallenge?> get cloudPasswordChallenge;

  /// Non-null while TDLib waits for the SMS / Telegram app login code ([AuthorizationStateWaitCode]).
  Stream<TdlibSmsCodeChallenge?> get smsCodeChallenge;

  /// `true` while TDLib is in [AuthorizationStateWaitPhoneNumber] (choose QR vs phone, or enter phone).
  Stream<bool> get authorizationWaitPhoneNumber;

  /// Telegram user id once [AuthorizationStateReady] is confirmed (after internal [getMe]).
  Stream<int> get authenticatedUserId;

  /// Non-fatal TDLib [TdError] messages (e.g. wrong 2FA password); for SnackBars.
  Stream<String?> get functionErrors;

  /// Optional: start QR login flow (TDLib `requestQrCodeAuthentication`, etc.).
  Future<void> startQrLogin();

  /// Call when [cloudPasswordChallenge] is active ([checkAuthenticationPassword]).
  Future<void> submitCloudPassword(String password);

  /// Phone login: [setAuthenticationPhoneNumber] while in [AuthorizationStateWaitPhoneNumber].
  Future<void> submitAuthenticationPhoneNumber(String phoneNumber);

  /// Phone login: [checkAuthenticationCode] while in [AuthorizationStateWaitCode].
  Future<void> submitAuthenticationCode(String code);

  /// Close native client and delete local TDLib DB dirs so the next [init] shows QR login.
  Future<void> resetLocalSessionForQrLogin();

  /// Release native client (call on logout / app dispose).
  Future<void> dispose();
}
