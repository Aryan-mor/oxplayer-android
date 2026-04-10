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
    if (!dotenv.isInitialized) {
      await dotenv.load(fileName: 'assets/env/default.env');
    }

    String value(String key) => dotenv.env[key]?.trim() ?? '';
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
}