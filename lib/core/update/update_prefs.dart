import 'package:shared_preferences/shared_preferences.dart';

const _kSkippedReleaseTag = 'app_update_skipped_release_tag';

Future<String?> readSkippedReleaseTag() async {
  final p = await SharedPreferences.getInstance();
  return p.getString(_kSkippedReleaseTag);
}

Future<void> writeSkippedReleaseTag(String tag) async {
  final p = await SharedPreferences.getInstance();
  await p.setString(_kSkippedReleaseTag, tag);
}

Future<void> clearSkippedReleaseTag() async {
  final p = await SharedPreferences.getInstance();
  await p.remove(_kSkippedReleaseTag);
}

