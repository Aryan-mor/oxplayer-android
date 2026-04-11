// ignore_for_file: implementation_imports

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tdlib/td_api.dart' as td;
import 'package:tdlib/tdlib.dart';
import 'package:tdlib/src/tdapi/tdapi.dart' show convertToObject;
import 'package:tdlib/src/tdclient/platform_interfaces/td_native_plugin_real.dart' as td_native;

import '../../services/auth_debug_service.dart';
import 'tdlib_facade.dart';
import 'tdlib_json_sanitize.dart';

void _tdlog(String message) {
  debugPrint(message);
}

const _kDownloadConnectionsCount = 16;
const _kMaxGetMeRetries = 2;

class TelegramTdlibFacade implements TdlibFacade {
  static TelegramTdlibFacade? _nativeClientOwner;
  static Future<void> _globalInitSerial = Future.value();

  TelegramTdlibFacade({
    this.onUserAuthorized,
    this.onRequiresInteractiveLogin,
  });

  final Future<void> Function(td.User user)? onUserAuthorized;
  final Future<void> Function()? onRequiresInteractiveLogin;

  int? _clientId;
  bool _receiveLoopRunning = false;
  Completer<void>? _closeHandshakeCompleter;
  Isolate? _receiveIsolate;
  ReceivePort? _receiveMainPort;
  ReceivePort? _receiveExitPort;
  StreamSubscription<dynamic>? _receiveSub;
  StreamSubscription<dynamic>? _receiveExitSub;
  SendPort? _receiveControlPort;
  Completer<void>? _receiveExitCompleter;
  bool _paramsSent = false;
  bool _transportTuningApplied = false;
  int? _pendingApiId;
  String? _pendingApiHash;
  String? _dbDir;
  String? _filesDir;

  @override
  bool get isInitialized => _clientId != null;

  bool _awaitingGetMeAfterReady = false;
  int _getMeRetryCount = 0;
  final _updates = StreamController<Map<String, dynamic>>.broadcast();
  final _qrPayload = StreamController<String?>.broadcast();
  final _cloudPassword = StreamController<TdlibCloudPasswordChallenge?>.broadcast();
  final _smsCodeChallenge = StreamController<TdlibSmsCodeChallenge?>.broadcast();
  final _authWaitPhoneNumber = StreamController<bool>.broadcast();
  final _authUserId = StreamController<int>.broadcast();
  final _functionErrors = StreamController<String?>.broadcast();
  final _pendingRequests = <String, Completer<td.TdObject>>{};
  var _authCompleter = Completer<void>();
  Future<void> _finalizeChain = Future.value();

  @override
  Future<void> ensureAuthorized() => _authCompleter.future;

  @override
  Future<td.TdObject> send(td.TdFunction request) {
    final id = _clientId;
    if (id == null) {
      return Future.error(StateError('TDLib is not initialized.'));
    }
    final extra = '${DateTime.now().microsecondsSinceEpoch}_${request.runtimeType}';
    final completer = Completer<td.TdObject>();
    _pendingRequests[extra] = completer;
    tdJsonClientSend(id, request, extra);
    return completer.future;
  }

  @override
  Stream<Map<String, dynamic>> updates() => _updates.stream;

  @override
  Stream<String?> get qrLoginPayload => _qrPayload.stream;

  @override
  Stream<TdlibCloudPasswordChallenge?> get cloudPasswordChallenge => _cloudPassword.stream;

  @override
  Stream<TdlibSmsCodeChallenge?> get smsCodeChallenge => _smsCodeChallenge.stream;

  @override
  Stream<bool> get authorizationWaitPhoneNumber => _authWaitPhoneNumber.stream;

  @override
  Stream<int> get authenticatedUserId => _authUserId.stream;

  @override
  Stream<String?> get functionErrors => _functionErrors.stream;

  static Future<void> initTdlibPlugin() async {
    if (kIsWeb) return;
    TdNativePlugin.registerWith();
    if (Platform.isAndroid || Platform.isLinux || Platform.isWindows) {
      await TdPlugin.initialize('libtdjson.so');
      return;
    }
    await TdPlugin.initialize();
  }

  @override
  Future<void> init({
    required int apiId,
    required String apiHash,
    required String sessionString,
  }) async {
    if (apiId <= 0 || apiHash.isEmpty) {
      throw StateError('Set TELEGRAM_API_ID and TELEGRAM_API_HASH in assets/env/default.env');
    }
    final previousGlobal = _globalInitSerial;
    final doneGlobal = Completer<void>();
    _globalInitSerial = doneGlobal.future;
    try {
      await previousGlobal.catchError((Object error, StackTrace stackTrace) {});
      await _performInit(apiId: apiId, apiHash: apiHash, sessionString: sessionString);
    } finally {
      if (!doneGlobal.isCompleted) {
        doneGlobal.complete();
      }
    }
  }

  static Future<void> _forceReclaimNativeClient(TelegramTdlibFacade caller) async {
    final sibling = _nativeClientOwner;
    if (sibling == null || identical(sibling, caller)) return;

    final staleId = sibling._clientId;
    sibling._receiveLoopRunning = false;
    try {
      await sibling._receiveSub?.cancel();
    } catch (_) {}
    sibling._receiveSub = null;
    sibling._receiveIsolate?.kill(priority: Isolate.immediate);
    sibling._receiveIsolate = null;
    sibling._receiveMainPort?.close();
    sibling._receiveMainPort = null;
    await Future<void>.delayed(const Duration(milliseconds: 300));

    if (staleId != null) {
      sibling._clientId = null;
      try {
        tdJsonClientSend(staleId, const td.Close());
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 400));
      try {
        tdJsonClientDestroy(staleId);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    _nativeClientOwner = null;
  }

  Future<void> _performInit({
    required int apiId,
    required String apiHash,
    required String sessionString,
  }) async {
    if (_clientId != null) {
      await _shutdownClient();
    }

    await _forceReclaimNativeClient(this);

    _clientId = tdJsonClientCreate();
    if (_clientId == null || _clientId == 0) {
      throw StateError('TDLib client creation failed.');
    }
    _nativeClientOwner = this;

    if (sessionString.isNotEmpty && kDebugMode) {
      debugPrint('TDLib: session string is ignored; local TDLib files are used instead.');
    }

    final support = await getApplicationSupportDirectory();
    _dbDir = '${support.path}/tdlib';
    _filesDir = '${support.path}/tdlib_files';

    await Directory(_dbDir!).create(recursive: true);
    await Directory(_filesDir!).create(recursive: true);

    _pendingApiId = apiId;
    _pendingApiHash = apiHash;
    _paramsSent = false;
    _awaitingGetMeAfterReady = false;
    if (_authCompleter.isCompleted) {
      _authCompleter = Completer<void>();
    }
    _finalizeChain = Future.value();

    unawaited(_startReceiveLoop());
  }

  @override
  Future<void> startQrLogin() async {
    if (_clientId == null) {
      throw StateError('Call init() before requesting QR login.');
    }
    tdJsonClientSend(_clientId!, const td.RequestQrCodeAuthentication(otherUserIds: []));
  }

  @override
  Future<void> submitCloudPassword(String password) async {
    if (_clientId == null) {
      throw StateError('Call init() before submitting password.');
    }
    tdJsonClientSend(_clientId!, td.CheckAuthenticationPassword(password: password));
  }

  @override
  Future<void> submitAuthenticationPhoneNumber(String phoneNumber) async {
    if (_clientId == null) {
      throw StateError('Call init() before submitting phone number.');
    }
    final normalized = phoneNumber.trim();
    if (normalized.isEmpty) return;
    tdJsonClientSend(_clientId!, td.SetAuthenticationPhoneNumber(phoneNumber: normalized));
  }

  @override
  Future<void> submitAuthenticationCode(String code) async {
    if (_clientId == null) {
      throw StateError('Call init() before submitting code.');
    }
    final normalized = code.trim();
    if (normalized.isEmpty) return;
    tdJsonClientSend(_clientId!, td.CheckAuthenticationCode(code: normalized));
  }

  @override
  Future<void> resetLocalSessionForQrLogin() async {
    if (kIsWeb) return;
    await _shutdownClient();
    try {
      final support = await getApplicationSupportDirectory();
      for (final name in ['tdlib', 'tdlib_files']) {
        final directory = Directory('${support.path}/$name');
        if (await directory.exists()) {
          await directory.delete(recursive: true);
        }
      }
    } catch (error) {
      _tdlog('TDLib resetLocalSessionForQrLogin: $error');
    }
  }

  Future<void> _startReceiveLoop() async {
    if (_receiveLoopRunning || _clientId == null) return;
    _receiveLoopRunning = true;
    final id = _clientId!;

    final port = ReceivePort();
    final exitPort = ReceivePort();
    _receiveMainPort = port;
    _receiveExitPort = exitPort;
    _receiveExitCompleter = Completer<void>();
    _receiveExitSub = exitPort.listen((_) {
      final completer = _receiveExitCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    });

    try {
      _receiveIsolate = await Isolate.spawn(
        tdlibReceiveIsolateMain,
        <Object?>[id, port.sendPort, _nativeLibPathForReceiveIsolate()],
        debugName: 'tdlib_receive',
        errorsAreFatal: false,
      );
    } catch (error, stackTrace) {
      debugPrint('TDLib receive isolate spawn failed: $error\n$stackTrace');
      _receiveLoopRunning = false;
      port.close();
      await _receiveExitSub?.cancel();
      _receiveExitSub = null;
      exitPort.close();
      _receiveExitPort = null;
      _receiveExitCompleter = null;
      _receiveMainPort = null;
      return;
    }

    _receiveIsolate?.addOnExitListener(exitPort.sendPort);

    if (!_receiveLoopRunning || _clientId != id) {
      await _stopReceiveIsolate(forceKill: true);
      _receiveIsolate = null;
      port.close();
      _receiveMainPort = null;
      return;
    }

    _receiveSub = port.listen((message) {
      if (!_receiveLoopRunning || _clientId != id) return;
      if (message is SendPort) {
        _receiveControlPort = message;
        return;
      }
      if (message is Map && message['_tdReceiveIsolateError'] != null) {
        _tdlog('TDLib receive isolate error: ${message['_tdReceiveIsolateError']}');
        return;
      }
      if (message is! String) return;
      try {
        final obj = convertToObject(sanitizeTdlibJson(message));
        if (obj == null) return;

        final extraStr = obj.extra?.toString();
        if (extraStr != null && _pendingRequests.containsKey(extraStr)) {
          final completer = _pendingRequests.remove(extraStr);
          if (obj is td.TdError) {
            completer?.completeError(obj);
          } else {
            completer?.complete(obj);
          }
          return;
        }

        final jsonMap = _tdObjectToJson(obj);
        if (jsonMap != null) {
          _updates.add(jsonMap);
        }

        if (obj is td.TdError) {
          _handleTdError(obj);
        } else {
          _handleAuthorization(obj);
          _handleSessionUser(obj);
        }
      } catch (error, stackTrace) {
        debugPrint('TDLib receive dispatch error: $error\n$stackTrace');
        try {
          final decoded = jsonDecode(sanitizeTdlibJson(message));
          if (decoded is Map<String, dynamic>) {
            final extraStr = decoded['@extra']?.toString();
            if (extraStr != null) {
              final completer = _pendingRequests.remove(extraStr);
              if (completer != null && !completer.isCompleted) {
                completer.completeError(StateError('TDLib JSON parse failed: $error'));
              }
            }
          }
        } catch (_) {}
      }
    });
  }

  void _handleTdError(td.TdError err) {
    if (_isIgnorableTdError(err)) {
      return;
    }

    if (_awaitingGetMeAfterReady) {
      _awaitingGetMeAfterReady = false;
      if (_isInteractiveAuthError(err)) {
        _failEnsureAuthorizedIfPending('GetMeError:${err.code}');
        unawaited(_invokeRequiresInteractiveLogin());
      } else {
        if (_getMeRetryCount < _kMaxGetMeRetries) {
          _getMeRetryCount += 1;
          Future<void>.delayed(const Duration(milliseconds: 350), _requestGetMe);
        } else if (!_authCompleter.isCompleted) {
          _authCompleter.completeError(err);
        }
      }
    }

    if (!_functionErrors.isClosed) {
      _functionErrors.add(err.message);
    }
  }

  bool _isIgnorableTdError(td.TdError err) {
    if (err.code == 406) return true;
    if (err.code == 400 && err.message.toLowerCase().contains("option can't be set")) {
      return true;
    }
    return false;
  }

  bool _isInteractiveAuthError(td.TdError err) {
    if (err.code == 401) return true;
    final message = err.message.toLowerCase();
    return message.contains('unauthorized') ||
        message.contains('not authorized') ||
        message.contains('authentication');
  }

  void _handleSessionUser(td.TdObject obj) {
    late final td.User user;
    if (obj is td.UpdateUser) {
      user = obj.user;
    } else if (obj is td.User) {
      user = obj;
    } else {
      return;
    }

    final byFallback = _awaitingGetMeAfterReady && user.id != 0;
    if (!byFallback) return;
    _awaitingGetMeAfterReady = false;
    authDebugSuccess('TDLib returned authenticated user details.');
    unawaited(_finalizeAuthenticatedSession(user));
  }

  Future<void> _finalizeAuthenticatedSession(td.User user) async {
    await _finalizeChain;
    final done = Completer<void>();
    _finalizeChain = done.future;
    try {
      if (_authCompleter.isCompleted) {
        return;
      }
      final onAuth = onUserAuthorized;
      try {
        if (onAuth != null) {
          await onAuth(user);
        }
        if (!_authUserId.isClosed) {
          _authUserId.add(user.id);
        }
        if (!_authCompleter.isCompleted) {
          _authCompleter.complete();
        }
      } catch (error) {
        if (!_functionErrors.isClosed) {
          _functionErrors.add('Could not save Telegram session: $error');
        }
        if (!_authCompleter.isCompleted) {
          _authCompleter.completeError(error);
        }
      }
    } finally {
      done.complete();
    }
  }

  void _handleAuthorization(td.TdObject obj) {
    if (obj is! td.UpdateAuthorizationState) return;
    final state = obj.authorizationState;

    if (state is td.AuthorizationStateWaitTdlibParameters) {
      authDebugDedup('tdlib_auth_state', AuthDebugLevel.info, 'TDLib auth state: WaitTdlibParameters.');
      if (_paramsSent || _clientId == null) return;
      final apiId = _pendingApiId;
      final apiHash = _pendingApiHash;
      final db = _dbDir;
      final files = _filesDir;
      if (apiId == null || apiHash == null || db == null || files == null) return;
      _paramsSent = true;
      tdJsonClientSend(
        _clientId!,
        td.SetTdlibParameters(
          useTestDc: false,
          databaseDirectory: db,
          filesDirectory: files,
          databaseEncryptionKey: '',
          useFileDatabase: true,
          useChatInfoDatabase: true,
          useMessageDatabase: true,
          useSecretChats: true,
          apiId: apiId,
          apiHash: apiHash,
          systemLanguageCode: 'en',
          deviceModel: 'OXPlayer',
          systemVersion: Platform.operatingSystemVersion,
          applicationVersion: '1.0.0',
          enableStorageOptimizer: true,
          ignoreFileNames: false,
        ),
      );
      _applyTransportTuning();
    } else if (state is td.AuthorizationStateWaitPhoneNumber) {
      authDebugDedup('tdlib_auth_state', AuthDebugLevel.info, 'TDLib auth state: WaitPhoneNumber.');
      _failEnsureAuthorizedIfPending('WaitPhoneNumber');
      unawaited(_invokeRequiresInteractiveLogin());
      if (!_authWaitPhoneNumber.isClosed) {
        _authWaitPhoneNumber.add(true);
      }
      if (!_smsCodeChallenge.isClosed) {
        _smsCodeChallenge.add(null);
      }
    } else if (state is td.AuthorizationStateWaitCode) {
      authDebugDedup('tdlib_auth_state', AuthDebugLevel.info, 'TDLib auth state: WaitCode.');
      _failEnsureAuthorizedIfPending('WaitCode');
      unawaited(_invokeRequiresInteractiveLogin());
      if (!_authWaitPhoneNumber.isClosed) {
        _authWaitPhoneNumber.add(false);
      }
      if (!_qrPayload.isClosed) {
        _qrPayload.add(null);
      }
      if (!_cloudPassword.isClosed) {
        _cloudPassword.add(null);
      }
      if (!_smsCodeChallenge.isClosed) {
        final info = state.codeInfo;
        _smsCodeChallenge.add(
          TdlibSmsCodeChallenge(
            phoneNumber: info.phoneNumber,
            resendTimeoutSeconds: info.timeout,
          ),
        );
      }
    } else if (state is td.AuthorizationStateWaitOtherDeviceConfirmation) {
      authDebugDedup('tdlib_auth_state', AuthDebugLevel.info, 'TDLib auth state: WaitOtherDeviceConfirmation (QR ready).');
      _failEnsureAuthorizedIfPending('WaitOtherDeviceConfirmation');
      unawaited(_invokeRequiresInteractiveLogin());
      if (!_authWaitPhoneNumber.isClosed) {
        _authWaitPhoneNumber.add(false);
      }
      if (!_smsCodeChallenge.isClosed) {
        _smsCodeChallenge.add(null);
      }
      if (!_cloudPassword.isClosed) {
        _cloudPassword.add(null);
      }
      if (!_qrPayload.isClosed) {
        _qrPayload.add(state.link);
      }
    } else if (state is td.AuthorizationStateReady) {
      authDebugDedup('tdlib_auth_state', AuthDebugLevel.success, 'TDLib auth state: Ready. Requesting GetMe...');
      if (_authCompleter.isCompleted) {
        _authCompleter = Completer<void>();
      }
      if (!_cloudPassword.isClosed) {
        _cloudPassword.add(null);
      }
      if (!_smsCodeChallenge.isClosed) {
        _smsCodeChallenge.add(null);
      }
      if (!_authWaitPhoneNumber.isClosed) {
        _authWaitPhoneNumber.add(false);
      }
      if (!_qrPayload.isClosed) {
        _qrPayload.add(null);
      }
      _getMeRetryCount = 0;
      _requestGetMe();
    } else if (state is td.AuthorizationStateWaitPassword) {
      authDebugDedup('tdlib_auth_state', AuthDebugLevel.info, 'TDLib auth state: WaitPassword.');
      if (!_authWaitPhoneNumber.isClosed) {
        _authWaitPhoneNumber.add(false);
      }
      if (!_smsCodeChallenge.isClosed) {
        _smsCodeChallenge.add(null);
      }
      if (!_qrPayload.isClosed) {
        _qrPayload.add(null);
      }
      if (!_cloudPassword.isClosed) {
        _cloudPassword.add(TdlibCloudPasswordChallenge(hint: state.passwordHint));
      }
    } else if (state is td.AuthorizationStateClosed) {
      authDebugDedup('tdlib_auth_state', AuthDebugLevel.error, 'TDLib auth state: Closed.');
      final completer = _closeHandshakeCompleter;
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
  }

  void _requestGetMe() {
    _awaitingGetMeAfterReady = true;
    authDebugDedup('tdlib_get_me', AuthDebugLevel.info, 'TDLib requesting GetMe for authenticated user details.');
    unawaited(() async {
      try {
        final result = await send(const td.GetMe());
        if (result is! td.User) {
          _awaitingGetMeAfterReady = false;
          if (!_functionErrors.isClosed) {
            _functionErrors.add('TDLib GetMe returned ${result.runtimeType} instead of User.');
          }
          authDebugError('TDLib GetMe returned ${result.runtimeType} instead of User.');
          return;
        }
        if (!_awaitingGetMeAfterReady) {
          return;
        }
        _awaitingGetMeAfterReady = false;
        authDebugSuccess('TDLib returned authenticated user details.');
        await _finalizeAuthenticatedSession(result);
      } catch (error) {
        if (_isInteractiveAuthErrorObject(error)) {
          _awaitingGetMeAfterReady = false;
          _failEnsureAuthorizedIfPending('GetMeInteractiveError');
          unawaited(_invokeRequiresInteractiveLogin());
          authDebugError('TDLib GetMe requires interactive authentication again: $error');
          return;
        }
        if (_getMeRetryCount < _kMaxGetMeRetries) {
          _getMeRetryCount += 1;
          authDebugError('TDLib GetMe failed, retrying ($_getMeRetryCount/$_kMaxGetMeRetries): $error');
          Future<void>.delayed(const Duration(milliseconds: 350), _requestGetMe);
          return;
        }
        _awaitingGetMeAfterReady = false;
        if (!_functionErrors.isClosed) {
          _functionErrors.add('TDLib GetMe failed: $error');
        }
        authDebugError('TDLib GetMe failed after retries: $error');
        if (!_authCompleter.isCompleted) {
          _authCompleter.completeError(error);
        }
      }
    }());
  }

  bool _isInteractiveAuthErrorObject(Object error) {
    if (error is! td.TdError) return false;
    return _isInteractiveAuthError(error);
  }

  void _failEnsureAuthorizedIfPending(String reason) {
    if (_authCompleter.isCompleted) return;
    _tdlog('TDLib interactive login required: $reason');
    _authCompleter.completeError(const TdlibInteractiveLoginRequired());
  }

  Future<void> _invokeRequiresInteractiveLogin() async {
    final callback = onRequiresInteractiveLogin;
    if (callback == null) return;
    try {
      await callback();
    } catch (error, stackTrace) {
      debugPrint('TDLib onRequiresInteractiveLogin error: $error\n$stackTrace');
    }
  }

  void _applyTransportTuning() {
    final id = _clientId;
    if (id == null || _transportTuningApplied) return;
    _transportTuningApplied = true;

    tdJsonClientSend(
      id,
      const td.SetOption(
        name: 'download_connections_count',
        value: td.OptionValueInteger(value: _kDownloadConnectionsCount),
      ),
    );
    tdJsonClientSend(
      id,
      const td.SetOption(
        name: 'network_type',
        value: td.OptionValueString(value: 'wifi'),
      ),
    );
    tdJsonClientSend(id, const td.SetNetworkType(type: td.NetworkTypeWiFi()));
  }

  Future<void> _shutdownClient() async {
    final id = _clientId;
    if (id == null) {
      _receiveLoopRunning = false;
      await _receiveSub?.cancel();
      _receiveSub = null;
      await _stopReceiveIsolate(forceKill: true);
      _receiveMainPort?.close();
      _receiveMainPort = null;
      return;
    }

    final canHandshake = _receiveIsolate != null && _receiveSub != null;
    if (canHandshake) {
      _closeHandshakeCompleter = Completer<void>();
      try {
        tdJsonClientSend(id, const td.Close());
      } catch (_) {
        if (!(_closeHandshakeCompleter?.isCompleted ?? true)) {
          _closeHandshakeCompleter?.complete();
        }
      }
      try {
        await _closeHandshakeCompleter!.future.timeout(const Duration(seconds: 3));
      } catch (_) {}
      _closeHandshakeCompleter = null;
    } else {
      try {
        tdJsonClientSend(id, const td.Close());
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }

    _receiveLoopRunning = false;
    await _receiveSub?.cancel();
    _receiveSub = null;
  await _stopReceiveIsolate();
    _receiveMainPort?.close();
    _receiveMainPort = null;
    await Future<void>.delayed(const Duration(milliseconds: 350));

    _paramsSent = false;
    _transportTuningApplied = false;
    _awaitingGetMeAfterReady = false;
    _getMeRetryCount = 0;
    _pendingApiId = null;
    _pendingApiHash = null;
    _dbDir = null;
    _filesDir = null;
    _clientId = null;
    if (identical(_nativeClientOwner, this)) {
      _nativeClientOwner = null;
    }
    try {
      tdJsonClientDestroy(id);
    } catch (error) {
      _tdlog('TDLib destroy error: $error');
    }
    await Future<void>.delayed(const Duration(milliseconds: 120));
  }

  Future<void> _stopReceiveIsolate({bool forceKill = false}) async {
    final isolate = _receiveIsolate;
    final controlPort = _receiveControlPort;
    final exitFuture = _receiveExitCompleter?.future;

    if (isolate == null) {
      await _receiveExitSub?.cancel();
      _receiveExitSub = null;
      _receiveExitPort?.close();
      _receiveExitPort = null;
      _receiveExitCompleter = null;
      _receiveControlPort = null;
      return;
    }

    if (!forceKill && controlPort != null) {
      try {
        controlPort.send('stop');
      } catch (_) {}
    }

    try {
      if (exitFuture != null) {
        await exitFuture.timeout(const Duration(seconds: 2));
      } else if (forceKill) {
        isolate.kill(priority: Isolate.immediate);
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    } catch (_) {
      isolate.kill(priority: Isolate.immediate);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }

    await _receiveExitSub?.cancel();
    _receiveExitSub = null;
    _receiveExitPort?.close();
    _receiveExitPort = null;
    _receiveExitCompleter = null;
    _receiveControlPort = null;
    _receiveIsolate = null;
  }

  @override
  Future<void> dispose() async {
    try {
      await _shutdownClient();
      await _updates.close();
      await _qrPayload.close();
      await _cloudPassword.close();
      await _smsCodeChallenge.close();
      await _authWaitPhoneNumber.close();
      await _authUserId.close();
      await _functionErrors.close();
    } catch (error, stackTrace) {
      debugPrint('TDLib dispose error: $error\n$stackTrace');
    }
  }
}

Map<String, dynamic>? _tdObjectToJson(td.TdObject obj) {
  try {
    final encoded = jsonEncode(obj.toJson());
    return jsonDecode(encoded) as Map<String, dynamic>;
  } catch (_) {
    return null;
  }
}

String? _nativeLibPathForReceiveIsolate() {
  if (kIsWeb) return null;
  if (Platform.isAndroid || Platform.isLinux || Platform.isWindows) {
    return 'libtdjson.so';
  }
  return null;
}

@pragma('vm:entry-point')
void tdlibReceiveIsolateMain(List<Object?> message) {
  final clientId = message[0]! as int;
  final sendPort = message[1]! as SendPort;
  final libPath = message.length > 2 ? message[2] as String? : null;
  final controlPort = ReceivePort();
  var shouldStop = false;

  td_native.TdNativePlugin.registerWith();
  if (libPath != null) {
    TdPlugin.instance = td_native.TdNativePlugin(ffi.DynamicLibrary.open(libPath));
  } else {
    TdPlugin.instance = td_native.TdNativePlugin(ffi.DynamicLibrary.process());
  }

  sendPort.send(controlPort.sendPort);
  controlPort.listen((message) {
    if (message == 'stop') {
      shouldStop = true;
      controlPort.close();
    }
  });

  while (!shouldStop) {
    try {
      final jsonStr = TdPlugin.instance.tdJsonClientReceive(clientId, 1.0);
      if (jsonStr != null) {
        sendPort.send(jsonStr);
      }
    } catch (error, stackTrace) {
      sendPort.send(<String, Object?>{
        '_tdReceiveIsolateError': error.toString(),
        '_st': stackTrace.toString(),
      });
    }
  }
}