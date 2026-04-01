// ignore_for_file: implementation_imports — TDLib does not export [convertToObject] / FFI plugin ctor.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:tdlib/td_api.dart' as td;
import 'package:tdlib/tdlib.dart';
// TDLib: [convertToObject] is not exported from public barrels.
import 'package:tdlib/src/tdapi/tdapi.dart' show convertToObject;
import 'package:tdlib/src/tdclient/platform_interfaces/td_native_plugin_real.dart'
    as td_native;

import '../core/config/app_config.dart';
import '../core/debug/app_debug_log.dart';
import 'tdlib_facade.dart';
import 'tdlib_json_sanitize.dart';

void _tdlog(String m) =>
    AppDebugLog.instance.log(m, category: AppDebugLogCategory.tdlib);

const _kGetMeExtra = 'telecima_session';
const _kDownloadConnectionsCount = 16;
const _kMaxGetMeRetries = 2;

bool _extraMatchesGetMe(dynamic extra) =>
    extra == _kGetMeExtra || extra?.toString() == _kGetMeExtra;

/// TDLib JSON client wired through `package:tdlib` (FFI).
///
/// Requires `libtdjson.so` under `android/app/src/main/jniLibs/<abi>/`.
class TelegramTdlibFacade implements TdlibFacade {
  TelegramTdlibFacade({
    this.onUserAuthorized,
    this.onRequiresInteractiveLogin,
  });

  /// Called after [AuthorizationStateReady] with [getMe] response; persist Isar + prefs here.
  final Future<void> Function(td.User user)? onUserAuthorized;

  /// TDLib entered QR / phone flow while the app still had a saved session — clear it and return to welcome.
  final Future<void> Function()? onRequiresInteractiveLogin;

  int? _clientId;
  bool _receiveLoopRunning = false;
  Isolate? _receiveIsolate;
  ReceivePort? _receiveMainPort;
  StreamSubscription<dynamic>? _receiveSub;
  bool _paramsSent = false;
  bool _transportTuningApplied = false;
  int? _pendingApiId;
  String? _pendingApiHash;
  String? _dbDir;
  String? _filesDir;

  @override
  bool get isInitialized => _clientId != null;
  /// Set when [AuthorizationStateReady] runs; cleared after [getMe] [User] is handled.
  bool _awaitingGetMeAfterReady = false;
  int _getMeRetryCount = 0;
  final _updates = StreamController<Map<String, dynamic>>.broadcast();
  final _qrPayload = StreamController<String?>.broadcast();
  final _cloudPassword = StreamController<TdlibCloudPasswordChallenge?>.broadcast();
  final _authUserId = StreamController<int>.broadcast();
  final _functionErrors = StreamController<String?>.broadcast();
  final _pendingRequests = <String, Completer<td.TdObject>>{};
  var _authCompleter = Completer<void>();
  /// Serializes [getMe] finalization so [UpdateUser] + [User] do not run [onUserAuthorized] twice.
  Future<void> _finalizeChain = Future.value();

  /// Ensures only one [init] runs at a time (avoids two clients locking `td.binlog`).
  Future<void> _initExclusive = Future.value();

  @override
  Future<void> ensureAuthorized() => _authCompleter.future;

  @override
  Future<td.TdObject> send(td.TdFunction request) {
    final id = _clientId;
    if (id == null) return Future.error(StateError('TDLib: not initialized'));
    final extra = '${DateTime.now().microsecondsSinceEpoch}_${request.runtimeType}';
    final completer = Completer<td.TdObject>();
    _pendingRequests[extra] = completer;
    _tdlog('TDLib[client=$id]: → send ${request.runtimeType} (extra=$extra)');
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
  Stream<int> get authenticatedUserId => _authUserId.stream;

  @override
  Stream<String?> get functionErrors => _functionErrors.stream;

  /// Call once at startup after [TdPlugin.initialize] (see [initTdlibPlugin]).
  ///
  /// On Android, [MainActivity] calls `System.loadLibrary("tdjson")` so the
  /// correct `jniLibs/<abi>/libtdjson.so` (including **x86** TV emulators) is
  /// resolved before [DynamicLibrary.open] runs.
  static Future<void> initTdlibPlugin() async {
    if (kIsWeb) return;
    TdNativePlugin.registerWith();
    if (Platform.isAndroid) {
      await TdPlugin.initialize('libtdjson.so');
    } else if (Platform.isLinux || Platform.isWindows) {
      await TdPlugin.initialize('libtdjson.so');
    } else {
      await TdPlugin.initialize();
    }
  }

  @override
  Future<void> init({
    required int apiId,
    required String apiHash,
    required String sessionString,
  }) async {
    if (apiId <= 0 || apiHash.isEmpty) {
      throw StateError('TDLib: set TELEGRAM_API_ID and TELEGRAM_API_HASH in assets/env/default.env');
    }
    final previous = _initExclusive;
    final done = Completer<void>();
    _initExclusive = done.future;
    await previous.catchError((Object _, StackTrace __) {});
    try {
      await _performInit(
        apiId: apiId,
        apiHash: apiHash,
        sessionString: sessionString,
      );
    } finally {
      if (!done.isCompleted) {
        done.complete();
      }
    }
  }

  Future<void> _performInit({
    required int apiId,
    required String apiHash,
    required String sessionString,
  }) async {
    if (_clientId != null) {
      await _shutdownClient();
    }

    _clientId = tdJsonClientCreate();
    if (_clientId == null || _clientId == 0) {
      throw StateError('TDLib: tdJsonClientCreate failed (is libtdjson.so in jniLibs?)');
    }

    if (sessionString.isNotEmpty && kDebugMode) {
      debugPrint('TDLib: ignoring GramJS session string; using TDLib database files.');
    }

    final support = await getApplicationSupportDirectory();
    _dbDir = '${support.path}/tdlib';
    _filesDir = '${support.path}/tdlib_files';

    final dbDirObj = Directory(_dbDir!);
    final dbExists = await dbDirObj.exists();
    _tdlog('TDLib: Init paths - DB: $_dbDir (exists: $dbExists), Files: $_filesDir');

    if (dbExists) {
      try {
        final list = dbDirObj
            .listSync()
            .map((e) => e.path.split(Platform.pathSeparator).last)
            .toList();
        _tdlog('TDLib: DB dir contents: ${list.join(', ')}');
      } catch (e) {
        _tdlog('TDLib: Failed to list DB dir: $e');
      }
    }

    await dbDirObj.create(recursive: true);
    await Directory(_filesDir!).create(recursive: true);

    _pendingApiId = apiId;
    _pendingApiHash = apiHash;
    _paramsSent = false;
    _awaitingGetMeAfterReady = false;
    if (_authCompleter.isCompleted) {
      _authCompleter = Completer<void>();
    }
    _finalizeChain = Future.value();

    _tdlog('TDLib: init() client created, starting receive isolate');
    unawaited(_startReceiveLoop());
  }

  @override
  Future<void> startQrLogin() async {
    if (_clientId == null) {
      throw StateError('TDLib: call init() first');
    }
    tdJsonClientSend(
      _clientId!,
      const td.RequestQrCodeAuthentication(otherUserIds: []),
    );
  }

  @override
  Future<void> submitCloudPassword(String password) async {
    if (_clientId == null) {
      throw StateError('TDLib: call init() first');
    }
    tdJsonClientSend(
      _clientId!,
      td.CheckAuthenticationPassword(password: password),
    );
  }

  @override
  Future<void> resetLocalSessionForQrLogin() async {
    if (kIsWeb) return;
    await _shutdownClient();
    try {
      final support = await getApplicationSupportDirectory();
      for (final name in ['tdlib', 'tdlib_files']) {
        final d = Directory('${support.path}/$name');
        if (await d.exists()) {
          await d.delete(recursive: true);
        }
      }
      _tdlog('TDLib: cleared local tdlib + tdlib_files (expect QR flow)');
    } catch (e) {
      _tdlog('TDLib: resetLocalSessionForQrLogin: $e');
    }
  }

  /// TDLib's [tdJsonClientReceive] blocks the calling thread for up to [timeout].
  /// Running it on the UI isolate freezes Flutter; TDLib expects receive on a
  /// dedicated thread anyway.
  Future<void> _startReceiveLoop() async {
    if (_receiveLoopRunning || _clientId == null) return;
    _receiveLoopRunning = true;
    final id = _clientId!;

    final port = ReceivePort();
    _receiveMainPort = port;

    try {
      _receiveIsolate = await Isolate.spawn(
        tdlibReceiveIsolateMain,
        <Object?>[id, port.sendPort, _nativeLibPathForReceiveIsolate()],
        debugName: 'tdlib_receive',
        errorsAreFatal: false,
      );
    } catch (e, st) {
      debugPrint('TDLib: failed to spawn receive isolate: $e\n$st');
      _tdlog('TDLib: spawn receive isolate FAILED: $e');
      _receiveLoopRunning = false;
      port.close();
      _receiveMainPort = null;
      return;
    }

    if (!_receiveLoopRunning || _clientId != id) {
      _receiveIsolate?.kill();
      _receiveIsolate = null;
      port.close();
      _receiveMainPort = null;
      return;
    }

    _receiveSub = port.listen((message) {
      if (!_receiveLoopRunning || _clientId != id) return;
      if (message is Map && message['_tdReceiveIsolateError'] != null) {
        final err = message['_tdReceiveIsolateError'];
        debugPrint('TDLib receive isolate: $err');
        _tdlog('TDLib receive isolate error: $err');
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
            _tdlog('TDLib: ← FAILED (extra=$extraStr) code=${obj.code}: ${obj.message}');
            completer?.completeError(obj);
          } else {
            _tdlog('TDLib: ← SUCCESS (extra=$extraStr) type=${obj.runtimeType}');
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
      } catch (e, st) {
        debugPrint('TDLib receive dispatch error: $e\n$st');
        final preview = message.length > 500 ? '${message.substring(0, 500)}…' : message;
        _tdlog('TDLib parse/dispatch error: $e');
        _tdlog('TDLib json preview: $preview');
        // Parsing failed after [sanitizeTdlibJson]: complete the matching RPC so [send] does not hang.
        try {
          final decoded = jsonDecode(sanitizeTdlibJson(message));
          if (decoded is Map<String, dynamic>) {
            final extraStr = decoded['@extra']?.toString();
            if (extraStr != null) {
              final completer = _pendingRequests.remove(extraStr);
              if (completer != null && !completer.isCompleted) {
                completer.completeError(
                  StateError('TDLib JSON parse/dispatch failed: $e'),
                );
              }
            }
          }
        } catch (_) {}
      }
    });
  }

  void _handleTdError(td.TdError err) {
    if (_isIgnorableTdError(err)) {
      _tdlog('TDLib: ignored non-fatal error ${err.code}: ${err.message}');
      return;
    }

    debugPrint('TDLib error ${err.code}: ${err.message}');
    _tdlog('TDLib ERROR ${err.code}: ${err.message}');
    if (_awaitingGetMeAfterReady) {
      _awaitingGetMeAfterReady = false;
      if (_isInteractiveAuthError(err)) {
        _tdlog(
          'TDLib: getMe failed after READY (${err.code}), forcing interactive re-login',
        );
        _failEnsureAuthorizedIfPending('GetMeError:${err.code}');
        unawaited(_invokeRequiresInteractiveLogin());
      } else {
        if (_getMeRetryCount < _kMaxGetMeRetries) {
          _getMeRetryCount += 1;
          _tdlog(
            'TDLib: getMe failed after READY (${err.code}: ${err.message}); '
            'retrying $_getMeRetryCount/$_kMaxGetMeRetries',
          );
          Future<void>.delayed(const Duration(milliseconds: 350), _requestGetMe);
        } else {
          if (!_authCompleter.isCompleted) {
            _authCompleter.completeError(err);
          }
        }
      }
    }
    if (!_functionErrors.isClosed) {
      _functionErrors.add(err.message);
    }
  }

  bool _isIgnorableTdError(td.TdError err) {
    if (err.code == 406) return true;
    if (err.code == 400 &&
        err.message.toLowerCase().contains("option can't be set")) {
      // Some TDLib builds reject transport tuning options in early auth states.
      // This is non-fatal and should not be surfaced as a user-visible error.
      return true;
    }
    return false;
  }

  bool _isInteractiveAuthError(td.TdError err) {
    if (err.code == 401) return true;
    final msg = err.message.toLowerCase();
    return msg.contains('unauthorized') ||
        msg.contains('not authorized') ||
        msg.contains('authentication');
  }

  void _handleSessionUser(td.TdObject obj) {
    late final td.User user;
    dynamic extra;
    if (obj is td.UpdateUser) {
      user = obj.user;
      extra = obj.extra;
    } else if (obj is td.User) {
      user = obj;
      extra = obj.extra;
    } else {
      return;
    }

    final byExtra = _extraMatchesGetMe(extra);
    final byFallback = _awaitingGetMeAfterReady && user.id != 0;
    if (!byExtra && !byFallback) return;
    if (byFallback && !byExtra) {
      debugPrint(
        'TDLib: getMe accepted without @extra echo (id=${user.id}, '
        'via ${obj.runtimeType})',
      );
    }
    _awaitingGetMeAfterReady = false;

    // Persist session before [authenticatedUserId] / navigation: otherwise [GoRouter]
    // redirect sees isLoggedIn=false and keeps the user on /welcome after QR scan.
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
          _tdlog(
            'TDLib[client=$_clientId]: Invoking onUserAuthorized for user ${user.id}...',
          );
          await onAuth(user);
          _tdlog('TDLib[client=$_clientId]: onUserAuthorized finished.');
        }
        if (!_authUserId.isClosed) {
          _authUserId.add(user.id);
        }
        if (!_authCompleter.isCompleted) {
          _authCompleter.complete();
        }
      } catch (e, st) {
        debugPrint('TDLib onUserAuthorized failed: $e\n$st');
        _tdlog('TDLib onUserAuthorized failed: $e');
        if (!_functionErrors.isClosed) {
          _functionErrors.add('Could not save session: $e');
        }
        if (!_authCompleter.isCompleted) {
          _authCompleter.completeError(e);
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
      if (_paramsSent || _clientId == null) return;
      final apiId = _pendingApiId;
      final apiHash = _pendingApiHash;
      final db = _dbDir;
      final files = _filesDir;
      if (apiId == null || apiHash == null || db == null || files == null) return;
      _paramsSent = true;
      debugPrint('TDLib: authorizationStateWaitTdlibParameters → setTdlibParameters');
      _tdlog('TDLib: WaitTdlibParameters → setTdlibParameters');
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
          deviceModel: 'Android TV',
          systemVersion: Platform.operatingSystemVersion,
          applicationVersion: '1.0.0',
          enableStorageOptimizer: true,
          ignoreFileNames: false,
        ),
      );
      // Transport tuning for better throughput on large media downloads.
      // Previous behavior: relied entirely on TDLib defaults.
      _applyTransportTuning();
      // Do not schedule [requestQrCodeAuthentication] here: with a warm DB, READY
      // may arrive after the timer and TDLib returns 400 "unexpected".
      // QR is requested from [AuthorizationStateWaitPhoneNumber] and Welcome.
    } else if (state is td.AuthorizationStateWaitPhoneNumber) {
      _tdlog('TDLib[client=$_clientId]: State = WaitPhoneNumber');
      _failEnsureAuthorizedIfPending('WaitPhoneNumber');
      unawaited(_invokeRequiresInteractiveLogin());
      tdJsonClientSend(
        _clientId!,
        const td.RequestQrCodeAuthentication(otherUserIds: []),
      );
    } else if (state is td.AuthorizationStateWaitOtherDeviceConfirmation) {
      _tdlog(
        'TDLib[client=$_clientId]: State = WaitOtherDeviceConfirmation (QR Link: ${state.link.substring(0, 10)}...)',
      );
      _failEnsureAuthorizedIfPending('WaitOtherDeviceConfirmation');
      unawaited(_invokeRequiresInteractiveLogin());
      if (!_cloudPassword.isClosed) {
        _cloudPassword.add(null);
      }
      if (!_qrPayload.isClosed) {
        _qrPayload.add(state.link);
      }
    } else if (state is td.AuthorizationStateReady) {
      // After [completeError] on interactive states, replace completer so [getMe] can finish auth again.
      if (_authCompleter.isCompleted) {
        _authCompleter = Completer<void>();
      }
      if (!_cloudPassword.isClosed) {
        _cloudPassword.add(null);
      }
      if (!_qrPayload.isClosed) {
        _qrPayload.add(null);
      }
      _tdlog('TDLib[client=$_clientId]: State = READY');
      _getMeRetryCount = 0;
      _requestGetMe();
    } else if (state is td.AuthorizationStateWaitPassword) {
      debugPrint('TDLib: 2FA password required (authorizationStateWaitPassword)');
      _tdlog('TDLib: WaitPassword (2FA)');
      if (!_qrPayload.isClosed) {
        _qrPayload.add(null);
      }
      if (!_cloudPassword.isClosed) {
        _cloudPassword.add(TdlibCloudPasswordChallenge(hint: state.passwordHint));
      }
    } else {
      debugPrint('TDLib auth state: ${state.runtimeType}');
      _tdlog('TDLib[client=$_clientId]: UNHANDLED auth state ${state.runtimeType}');
    }
  }

  void _requestGetMe() {
    final id = _clientId;
    if (id == null) return;
    _awaitingGetMeAfterReady = true;
    tdJsonClientSend(id, const td.GetMe(), _kGetMeExtra);
  }

  void _failEnsureAuthorizedIfPending(String reason) {
    if (_authCompleter.isCompleted) return;
    _tdlog('TDLib: ensureAuthorized failed ($reason) → interactive login required');
    _authCompleter.completeError(const TdlibInteractiveLoginRequired());
  }

  Future<void> _invokeRequiresInteractiveLogin() async {
    final fn = onRequiresInteractiveLogin;
    if (fn == null) return;
    try {
      await fn();
    } catch (e, st) {
      debugPrint('TDLib onRequiresInteractiveLogin: $e\n$st');
      _tdlog('TDLib: onRequiresInteractiveLogin error: $e');
    }
  }

  void _applyTransportTuning() {
    final id = _clientId;
    if (id == null || _transportTuningApplied) return;
    _transportTuningApplied = true;

    _tdlog(
      'TDLib[client=$id]: Tuning before/after: '
      'download_connections_count: default -> $_kDownloadConnectionsCount',
    );
    tdJsonClientSend(
      id,
      const td.SetOption(
        name: 'download_connections_count',
        value: td.OptionValueInteger(value: _kDownloadConnectionsCount),
      ),
    );

    // We are a TV app and should avoid mobile-data specific throttling logic.
    _tdlog(
      'TDLib[client=$id]: Tuning before/after: network_type: default -> wifi',
    );
    tdJsonClientSend(
      id,
      const td.SetOption(
        name: 'network_type',
        value: td.OptionValueString(value: 'wifi'),
      ),
    );
    tdJsonClientSend(
      id,
      const td.SetNetworkType(type: td.NetworkTypeWiFi()),
    );
  }

  Future<void> _shutdownClient() async {
    _receiveLoopRunning = false;
    await _receiveSub?.cancel();
    _receiveSub = null;
    _receiveIsolate?.kill(priority: Isolate.immediate);
    _receiveIsolate = null;
    _receiveMainPort?.close();
    _receiveMainPort = null;
    // Receive isolate must stop calling [tdJsonClientReceive] before [Close]/[destroy].
    await Future<void>.delayed(const Duration(milliseconds: 220));

    _paramsSent = false;
    _transportTuningApplied = false;
    _awaitingGetMeAfterReady = false;
    _getMeRetryCount = 0;
    _pendingApiId = null;
    _pendingApiHash = null;
    _dbDir = null;
    _filesDir = null;
    final id = _clientId;
    _clientId = null;
    if (id != null) {
      try {
        tdJsonClientSend(id, const td.Close());
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 120));
      try {
        tdJsonClientDestroy(id);
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  @override
  Future<void> dispose() async {
    await _shutdownClient();
    await _updates.close();
    await _qrPayload.close();
    await _cloudPassword.close();
    await _authUserId.close();
    await _functionErrors.close();
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

/// Riverpod / tests: construct from [AppConfig].
TelegramTdlibFacade createTdlibFromConfig(AppConfig config) {
  return TelegramTdlibFacade();
}

/// Passed to [tdlibReceiveIsolateMain]: `libtdjson.so` on Android/desktop, or
/// `null` to use [ffi.DynamicLibrary.process] (e.g. iOS/macOS).
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

  td_native.TdNativePlugin.registerWith();
  if (libPath != null) {
    TdPlugin.instance = td_native.TdNativePlugin(ffi.DynamicLibrary.open(libPath));
  } else {
    TdPlugin.instance = td_native.TdNativePlugin(ffi.DynamicLibrary.process());
  }

  while (true) {
    try {
      final jsonStr = TdPlugin.instance.tdJsonClientReceive(clientId, 1.0);
      if (jsonStr != null) {
        sendPort.send(jsonStr);
      }
    } catch (e, st) {
      sendPort.send(<String, Object?>{
        '_tdReceiveIsolateError': e.toString(),
        '_st': st.toString(),
      });
    }
  }
}
