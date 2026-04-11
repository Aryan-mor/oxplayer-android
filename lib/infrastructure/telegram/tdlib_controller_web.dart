import 'tdlib_facade.dart';
import 'package:tdlib/td_api.dart' as td;

class TelegramTdlibFacade implements TdlibFacade {
  @override
  bool get isInitialized => false;

  static Future<void> initTdlibPlugin() async {}

  @override
  Future<void> init({
    required int apiId,
    required String apiHash,
    required String sessionString,
  }) async {
    throw UnsupportedError('Telegram sign-in is not available on web builds.');
  }

  @override
  Future<void> ensureAuthorized() async {
    throw UnsupportedError('Telegram sign-in is not available on web builds.');
  }

  @override
  Stream<Map<String, dynamic>> updates() => const Stream.empty();

  @override
  Stream<String?> get qrLoginPayload => const Stream.empty();

  @override
  Stream<TdlibCloudPasswordChallenge?> get cloudPasswordChallenge => const Stream.empty();

  @override
  Stream<TdlibSmsCodeChallenge?> get smsCodeChallenge => const Stream.empty();

  @override
  Stream<bool> get authorizationWaitPhoneNumber => const Stream.empty();

  @override
  Stream<int> get authenticatedUserId => const Stream.empty();

  @override
  Stream<String?> get functionErrors => const Stream.empty();

  @override
  Future<td.TdObject> send(td.TdFunction request) {
    throw UnsupportedError('Telegram sign-in is not available on web builds.');
  }

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