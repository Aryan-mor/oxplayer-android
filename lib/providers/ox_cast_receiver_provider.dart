import 'dart:async' show Completer, StreamSubscription, Timer, unawaited;
import 'dart:convert' show jsonDecode, utf8;

import 'package:flutter/material.dart';
import 'package:web_socket_channel/io.dart';

import '../infrastructure/data_repository.dart';
import 'auth_notifier.dart';
import '../services/settings_service.dart';
import '../utils/media_navigation_helper.dart';
import '../utils/navigation_keys.dart';
import '../utils/platform_detector.dart';

/// Android TV: persisted "receive cast" mode — background WebSocket (and HTTP fallback)
/// while the app runs; survives process restarts via [SettingsService].
///
/// Starts only when [AuthNotifier.isLoggedIn] so API calls have a Bearer token.
class OxCastReceiverProvider extends ChangeNotifier {
  OxCastReceiverProvider({required AuthNotifier authNotifier}) : _auth = authNotifier {
    final sync = SettingsService.instanceOrNull;
    if (sync != null) {
      _listeningEnabled = sync.getTvCastReceiverListening();
    }
    _auth.addListener(_onAuthChanged);
    unawaited(_loadSettingsAndScheduleStart());
  }

  final AuthNotifier _auth;
  SettingsService? _settings;
  bool _listeningEnabled = false;
  int _sessionToken = 0;
  bool _loopRunning = false;
  bool? _lastLoggedIn;

  IOWebSocketChannel? _activeChannel;
  StreamSubscription<dynamic>? _activeSub;

  bool get isListeningEnabled => _listeningEnabled;

  Future<void> _loadSettingsAndScheduleStart() async {
    _settings = await SettingsService.getInstance();
    _listeningEnabled = _settings!.getTvCastReceiverListening();
    notifyListeners();
    _onAuthChanged();
  }

  void _onAuthChanged() {
    if (!_auth.ready) return;

    final loggedIn = _auth.isLoggedIn;
    if (_lastLoggedIn == loggedIn) {
      if (loggedIn && _listeningEnabled && PlatformDetector.isTV() && !_loopRunning) {
        unawaited(_restartCastListener());
      }
      return;
    }
    _lastLoggedIn = loggedIn;

    if (!loggedIn) {
      _sessionToken++;
      unawaited(_tearDownActiveConnection());
      return;
    }

    if (_listeningEnabled && PlatformDetector.isTV()) {
      unawaited(_restartCastListener());
    }
  }

  Future<void> setListeningEnabled(bool enabled) async {
    final settings = _settings ?? await SettingsService.getInstance();
    _settings = settings;
    await settings.setTvCastReceiverListening(enabled);
    _listeningEnabled = enabled;
    notifyListeners();

    if (!enabled) {
      _sessionToken++;
      await _tearDownActiveConnection();
      try {
        final repo = await DataRepository.create();
        await repo.cancelOxCastOffer();
      } catch (_) {}
      return;
    }

    if (PlatformDetector.isTV() && _auth.isLoggedIn) {
      unawaited(_restartCastListener());
    }
  }

  /// Called when the app returns to foreground — reconnect if listening was enabled.
  void onAppResumed() {
    if (!_listeningEnabled || !PlatformDetector.isTV() || !_auth.isLoggedIn) return;
    unawaited(_restartCastListener());
  }

  Future<void> _restartCastListener() async {
    if (!_listeningEnabled || !PlatformDetector.isTV() || !_auth.isLoggedIn) return;

    _sessionToken++;
    final token = _sessionToken;
    await _tearDownActiveConnection();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!_listeningEnabled || token != _sessionToken || !_auth.isLoggedIn) return;

    unawaited(_runListenLoop(token));
  }

  Future<void> _runListenLoop(int token) async {
    if (_loopRunning) return;
    _loopRunning = true;
    try {
      while (_listeningEnabled && token == _sessionToken && _auth.isLoggedIn) {
        await _webSocketCycle(token);
        if (!_listeningEnabled || token != _sessionToken || !_auth.isLoggedIn) break;
        await _pollCycle(token);
      }
    } finally {
      _loopRunning = false;
    }
  }

  Future<void> _webSocketCycle(int token) async {
    IOWebSocketChannel? channel;
    StreamSubscription<dynamic>? sub;
    final done = Completer<void>();
    try {
      final repo = await DataRepository.create();
      final uri = repo.buildOxCastWebSocketUri();
      final tokenStr = repo.requireApiAccessTokenForOxApi();
      channel = IOWebSocketChannel.connect(
        uri,
        headers: <String, dynamic>{'Authorization': 'Bearer $tokenStr'},
      );
      await channel.ready;
      _activeChannel = channel;
      sub = channel.stream.listen(
        (dynamic event) {
          if (token != _sessionToken || !_listeningEnabled) {
            if (!done.isCompleted) done.complete();
            return;
          }
          final offer = _parseWsEvent(event);
          if (offer != null) {
            _dispatchOffer(offer);
          }
        },
        onError: (_) {
          if (!done.isCompleted) done.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
      );
      _activeSub = sub;
      await done.future;
    } catch (_) {
      // Fall through to poll cycle
    } finally {
      await _tearDownActiveConnection();
    }
  }

  Future<void> _pollCycle(int token) async {
    while (_listeningEnabled && token == _sessionToken && _auth.isLoggedIn) {
      try {
        final repo = await DataRepository.create();
        final offer = await repo.pollOxCastPending(timeoutSeconds: 55);
        if (token != _sessionToken || !_listeningEnabled || !_auth.isLoggedIn) return;
        if (offer != null) {
          _dispatchOffer(offer);
        }
      } catch (_) {
        if (token != _sessionToken || !_listeningEnabled || !_auth.isLoggedIn) return;
        await Future<void>.delayed(const Duration(seconds: 2));
      }
    }
  }

  OxCastOffer? _parseWsEvent(dynamic event) {
    try {
      final text = event is String ? event : utf8.decode(event as List<int>);
      final decoded = jsonDecode(text);
      if (decoded is! Map) return null;
      final map = Map<String, dynamic>.from(decoded);
      if (map['type'] != 'cast_offer') return null;
      final offerRaw = map['offer'];
      if (offerRaw is! Map) return null;
      return OxCastOffer.tryParseApiOfferMap(Map<String, dynamic>.from(offerRaw));
    } catch (_) {
      return null;
    }
  }

  void _dispatchOffer(OxCastOffer offer) {
    var started = false;
    void tryOnce() {
      if (started) return;
      final ctx = rootNavigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        started = true;
        unawaited(startOxCastPlayback(ctx, mediaGlobalId: offer.mediaGlobalId, fileId: offer.fileId));
      }
    }

    tryOnce();
    WidgetsBinding.instance.addPostFrameCallback((_) => tryOnce());
    Timer(const Duration(milliseconds: 500), tryOnce);
  }

  Future<void> _tearDownActiveConnection() async {
    await _activeSub?.cancel();
    _activeSub = null;
    try {
      await _activeChannel?.sink.close();
    } catch (_) {}
    _activeChannel = null;
  }

  @override
  void dispose() {
    _auth.removeListener(_onAuthChanged);
    _sessionToken++;
    unawaited(_tearDownActiveConnection());
    super.dispose();
  }
}
