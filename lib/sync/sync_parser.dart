class SyncParser {
  static int? estimateBitrate(int? sizeBytes, int? durationSec) {
    if (sizeBytes == null || durationSec == null || durationSec <= 0) return null;
    return ((sizeBytes * 8) / durationSec).round();
  }

  static String deriveQualityLabel({String? fileName, int? sizeBytes, String? explicitRes}) {
    if (explicitRes != null && explicitRes.isNotEmpty) {
      if (explicitRes.toLowerCase().contains('4k')) return '4K';
      return explicitRes;
    }
    final lower = (fileName ?? '').toLowerCase();
    if (lower.contains('2160') || lower.contains('4k')) return '4K';
    if (lower.contains('1080')) return '1080p';
    if (lower.contains('720')) return '720p';
    if ((sizeBytes ?? 0) > 6 * 1024 * 1024 * 1024) return '4K';
    if ((sizeBytes ?? 0) > 2 * 1024 * 1024 * 1024) return '1080p';
    return 'SD';
  }

  static ({bool streamSupported, bool isPremiumNeeded}) streamSupportHeuristic(int? sizeBytes, int? bitrate) {
    final premiumBySize = (sizeBytes ?? 0) > 2 * 1024 * 1024 * 1024;
    final heavyBitrate = (bitrate ?? 0) > 16000000;
    return (
      streamSupported: !premiumBySize && !heavyBitrate,
      isPremiumNeeded: premiumBySize,
    );
  }

  static String slugify(String input) {
    final cleaned = input.toLowerCase().replaceAll(RegExp(r'[^\p{L}\p{N}\s-]', unicode: true), ' ').trim();
    final collapsed = cleaned.replaceAll(RegExp(r'\s+'), '-');
    if (collapsed.length <= 64) return collapsed;
    return collapsed.substring(0, 64);
  }

  static String buildFallbackGlobalId(int chatId, int messageId, String title) {
    final stem = slugify(title.isEmpty ? 'untitled' : title);
    return 'tg_${chatId}_${messageId}_$stem';
  }

  static String? extractUuidTag(String rawText, String tagPrefix) {
    final loose = RegExp(
      '#${RegExp.escape(tagPrefix)}_[\\s]*([\\s\\S]*?)(?=\\s#[A-Za-z0-9_]|\$)',
      multiLine: true,
    ).firstMatch(rawText);
    if (loose == null) return null;
    final candidate = loose.group(1)?.trim().replaceAll('_', '-') ?? '';
    final uuid = RegExp(
      r'[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}',
      caseSensitive: false,
    ).firstMatch(candidate);
    return uuid?.group(0)?.toLowerCase();
  }

  static String? extractTag(String rawText, String tagPrefix) {
    final match = RegExp('#${RegExp.escape(tagPrefix)}_([\\s\\S]*?)(?=\\s#[A-Za-z0-9_]|\$)').firstMatch(rawText);
    return match?.group(1)?.replaceAll('_', ' ').trim();
  }

  static String? extractYear(String text) {
    final match = RegExp(r'#Y(\d{4})').firstMatch(text);
    return match?.group(1);
  }

  static List<String> extractAllTags(String text) {
     return text.split(RegExp(r'\s+')).where((t) => t.startsWith('#')).toList();
  }

  /// Parses `#season_N`, `#S_N` (case-insensitive) → season number.
  /// Returns `null` if no season tag found.
  static int? extractSeasonNumber(String text) {
    final match = RegExp(
      r'#(?:season|S)_(\d+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }

  /// Parses `#ep_N`, `#episode_N`, `#E_N` (case-insensitive) → episode number.
  /// Returns `null` if no episode tag found.
  static int? extractEpisodeNumber(String text) {
    final match = RegExp(
      r'#(?:episode|ep|E)_(\d+)',
      caseSensitive: false,
    ).firstMatch(text);
    if (match == null) return null;
    return int.tryParse(match.group(1) ?? '');
  }
}

