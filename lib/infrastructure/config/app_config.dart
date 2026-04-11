import 'package:flutter_dotenv/flutter_dotenv.dart';

class AppConfig {
  const AppConfig({
    required this.telegramApiId,
    required this.telegramApiHash,
    required this.botUsername,
    required this.apiBaseUrl,
    required this.telegramWebAppShortName,
    required this.telegramWebAppUrl,
    required this.subdlApiKey,
  });

  final String telegramApiId;
  final String telegramApiHash;
  final String botUsername;
  final String apiBaseUrl;
  final String telegramWebAppShortName;
  final String telegramWebAppUrl;
  final String subdlApiKey;

  static Future<AppConfig> load() async {
    await _ensureLoaded();

    String value(String key) => _value(key);
    String valueOrLegacy(String key, String legacyKey) {
      final primary = value(key);
      if (primary.isNotEmpty) return primary;
      return value(legacyKey);
    }

    return AppConfig(
      telegramApiId: value('TELEGRAM_API_ID'),
      telegramApiHash: value('TELEGRAM_API_HASH'),
      botUsername: value('BOT_USERNAME').replaceFirst('@', ''),
      apiBaseUrl: valueOrLegacy('OXPLAYER_API_BASE_URL', 'TV_APP_API_BASE_URL'),
      telegramWebAppShortName: valueOrLegacy(
        'OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME',
        'TV_APP_WEBAPP_SHORT_NAME',
      ),
      telegramWebAppUrl: valueOrLegacy(
        'OXPLAYER_TELEGRAM_WEBAPP_URL',
        'TV_APP_WEBAPP_URL',
      ),
      subdlApiKey: value('SUBDL_API_KEY'),
    );
  }

  bool get hasTelegramKeys => telegramApiId.isNotEmpty && telegramApiHash.isNotEmpty;

  bool get hasApiConfig =>
      apiBaseUrl.isNotEmpty &&
      (telegramWebAppShortName.isNotEmpty || telegramWebAppUrl.isNotEmpty);

  static Future<void> _ensureLoaded() async {
    if (dotenv.isInitialized) return;

    for (final fileName in const <String>[
      'assets/env/default.env',
      'assets/env/default.env.example',
    ]) {
      try {
        await dotenv.load(fileName: fileName);
        return;
      } catch (_) {
        // Prefer a local override, but keep a tracked example for safe fallbacks.
      }
    }

    throw StateError(
      'Missing env asset. Create assets/env/default.env from assets/env/default.env.example or pass values via --dart-define/--dart-define-from-file.',
    );
  }

  static const Map<String, String> _dartDefineEnvByKey = <String, String>{
    'TELEGRAM_API_ID': String.fromEnvironment('TELEGRAM_API_ID'),
    'TELEGRAM_API_HASH': String.fromEnvironment('TELEGRAM_API_HASH'),
    'BOT_USERNAME': String.fromEnvironment('BOT_USERNAME'),
    'OXPLAYER_API_BASE_URL': String.fromEnvironment('OXPLAYER_API_BASE_URL'),
    'TV_APP_API_BASE_URL': String.fromEnvironment('TV_APP_API_BASE_URL'),
    'OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME': String.fromEnvironment('OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME'),
    'TV_APP_WEBAPP_SHORT_NAME': String.fromEnvironment('TV_APP_WEBAPP_SHORT_NAME'),
    'OXPLAYER_TELEGRAM_WEBAPP_URL': String.fromEnvironment('OXPLAYER_TELEGRAM_WEBAPP_URL'),
    'TV_APP_WEBAPP_URL': String.fromEnvironment('TV_APP_WEBAPP_URL'),
    'SUBDL_API_KEY': String.fromEnvironment('SUBDL_API_KEY'),
  };

  static String _value(String key) {
    final fromDefine = _dartDefineEnvByKey[key]?.trim() ?? '';
    if (fromDefine.isNotEmpty) {
      return fromDefine;
    }
    return dotenv.env[key]?.trim() ?? '';
  }
}