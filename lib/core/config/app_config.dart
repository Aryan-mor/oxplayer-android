import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Runtime configuration loaded from `assets/env/default.env` (see [bootstrap]).
class AppConfig {
  const AppConfig({
    required this.telegramApiId,
    required this.telegramApiHash,
    required this.indexTag,
    required this.botUsername,
    required this.captionerBotUsername,
    required this.providerBotUsername,
    required this.requiredChannelUsername,
    required this.apiBaseUrl,
    required this.telegramWebAppShortName,
    required this.telegramWebAppUrl,
    required this.subdlApiKey,
    required this.debugProductionEnabled,
  });

  final String telegramApiId;
  final String telegramApiHash;
  final String indexTag;
  /// Main bot (WebApp / initData, indexing, and mandatory /start when gate is on).
  final String botUsername;
  /// Shown when user must re-send media for indexing; defaults to [botUsername] if unset.
  final String captionerBotUsername;
  final String providerBotUsername;
  final String requiredChannelUsername;
  final String apiBaseUrl;
  final String telegramWebAppShortName;
  final String telegramWebAppUrl;
  /// SubDL API key for in-app subtitle search (internal player). Empty = disabled.
  final String subdlApiKey;
  /// Enables debug panel/logs in production for eligible users.
  final bool debugProductionEnabled;

  static AppConfig fromEnv() {
    String v(String key) => dotenv.env[key]?.trim() ?? '';
    bool vb(String key, {required bool defaultValue}) {
      final value = v(key).toLowerCase();
      if (value.isEmpty) return defaultValue;
      return value == '1' || value == 'true' || value == 'yes' || value == 'on';
    }
    String vOrLegacy(String key, String legacyKey) {
      final primary = v(key);
      if (primary.isNotEmpty) return primary;
      return v(legacyKey);
    }

    final botUser = v('BOT_USERNAME').replaceFirst('@', '');
    final captionerUser = v('CAPTIONER_BOT_USERNAME').replaceFirst('@', '');
    return AppConfig(
      telegramApiId: v('TELEGRAM_API_ID'),
      telegramApiHash: v('TELEGRAM_API_HASH'),
      // When INDEX_TAG is missing (or dotenv stripped `#…` — quote INDEX_TAG in default.env).
      indexTag: v('INDEX_TAG').isEmpty ? '#seeOnTV' : v('INDEX_TAG'),
      botUsername: botUser,
      captionerBotUsername: captionerUser.isEmpty ? botUser : captionerUser,
      providerBotUsername: v('PROVIDER_BOT_USERNAME').replaceFirst('@', ''),
      requiredChannelUsername: v('REQUIRED_CHANNEL_USERNAME').replaceFirst('@', ''),
      apiBaseUrl: vOrLegacy('OXPLAYER_API_BASE_URL', 'TV_APP_API_BASE_URL'),
      telegramWebAppShortName: vOrLegacy(
        'OXPLAYER_TELEGRAM_WEBAPP_SHORT_NAME',
        'TV_APP_WEBAPP_SHORT_NAME',
      ),
      telegramWebAppUrl: vOrLegacy(
        'OXPLAYER_TELEGRAM_WEBAPP_URL',
        'TV_APP_WEBAPP_URL',
      ),
      subdlApiKey: v('SUBDL_API_KEY'),
      debugProductionEnabled: vb(
        'OXPLAYER_DEBUG_PRODUCTION',
        defaultValue: true,
      ),
    );
  }

  bool get hasTelegramKeys =>
      telegramApiId.isNotEmpty && telegramApiHash.isNotEmpty;
  bool get hasApiConfig =>
      apiBaseUrl.isNotEmpty &&
      (telegramWebAppShortName.isNotEmpty || telegramWebAppUrl.isNotEmpty);
}

