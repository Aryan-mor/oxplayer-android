import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Runtime configuration loaded from `assets/env/default.env` (see [bootstrap]).
class AppConfig {
  const AppConfig({
    required this.tmdbApiKey,
    required this.telegramApiId,
    required this.telegramApiHash,
    required this.indexTag,
    required this.botUsername,
    required this.tvAppApiBaseUrl,
    required this.tvAppWebAppShortName,
    required this.tvAppWebAppUrl,
  });

  final String tmdbApiKey;
  final String telegramApiId;
  final String telegramApiHash;
  final String indexTag;
  final String botUsername;
  final String tvAppApiBaseUrl;
  final String tvAppWebAppShortName;
  final String tvAppWebAppUrl;

  static AppConfig fromEnv() {
    String v(String key) => dotenv.env[key]?.trim() ?? '';
    return AppConfig(
      tmdbApiKey: v('TMDB_API_KEY'),
      telegramApiId: v('TELEGRAM_API_ID'),
      telegramApiHash: v('TELEGRAM_API_HASH'),
      // When INDEX_TAG is missing (or dotenv stripped `#…` — quote INDEX_TAG in default.env).
      indexTag: v('INDEX_TAG').isEmpty ? '#seeOnTV' : v('INDEX_TAG'),
      botUsername: v('BOT_USERNAME').replaceFirst('@', ''),
      tvAppApiBaseUrl: v('TV_APP_API_BASE_URL'),
      tvAppWebAppShortName: v('TV_APP_WEBAPP_SHORT_NAME'),
      tvAppWebAppUrl: v('TV_APP_WEBAPP_URL'),
    );
  }

  bool get hasTmdb => tmdbApiKey.isNotEmpty;
  bool get hasTelegramKeys =>
      telegramApiId.isNotEmpty && telegramApiHash.isNotEmpty;
  bool get hasApiConfig =>
      tvAppApiBaseUrl.isNotEmpty &&
      (tvAppWebAppShortName.isNotEmpty || tvAppWebAppUrl.isNotEmpty);
}
