import 'dart:async';
import 'package:tdlib/td_api.dart' as td;

import '../core/config/app_config.dart';
import 'tdlib_facade.dart';

/// Web stub for TDLib since package:tdlib uses dart:ffi which breaks flutter build web.
class TelegramTdlibFacade implements TdlibFacade {
  TelegramTdlibFacade({
    this.onUserAuthorized,
    this.onRequiresInteractiveLogin,
  });

  final Future<void> Function(td.User user)? onUserAuthorized;
  final Future<void> Function()? onRequiresInteractiveLogin;

  static Future<void> initTdlibPlugin() async {}

  @override
  bool get isInitialized => false;

  @override
  Future<void> ensureAuthorized() => Future.value();

  @override
  Future<td.TdObject> send(td.TdFunction request) =>
      Future.error(StateError('TDLib not available on Web'));

  @override
  Stream<Map<String, dynamic>> updates() => const Stream.empty();

  @override
  Stream<String?> get qrLoginPayload => const Stream.empty();

  @override
  Stream<TdlibCloudPasswordChallenge?> get cloudPasswordChallenge =>
      const Stream.empty();

  @override
  Stream<TdlibSmsCodeChallenge?> get smsCodeChallenge => const Stream.empty();

  @override
  Stream<bool> get authorizationWaitPhoneNumber => const Stream.empty();

  @override
  Stream<int> get authenticatedUserId => const Stream.empty();

  @override
  Stream<String?> get functionErrors => const Stream.empty();

  @override
  Future<void> init({
    required int apiId,
    required String apiHash,
    required String sessionString,
  }) async {}

  @override
  Future<void> startQrLogin() async {}

  @override
  Future<void> submitCloudPassword(String password) async {}

  @override
  Future<void> submitAuthenticationPhoneNumber(String phoneNumber) async {}

  @override
  Future<void> submitAuthenticationCode(String code) async {}

  @override
  Future<void> resetLocalSessionForQrLogin() async {}

  @override
  Future<void> dispose() async {}
}

TelegramTdlibFacade createTdlibFromConfig(AppConfig config) {
  return TelegramTdlibFacade();
}
