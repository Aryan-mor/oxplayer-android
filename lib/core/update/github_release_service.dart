import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';

import 'app_update_config.dart';
import 'update_platform.dart';

const _apkByAbi = <String, String>{
  'arm64-v8a': 'app-arm64-v8a-release.apk',
  'armeabi-v7a': 'app-armeabi-v7a-release.apk',
  'x86_64': 'app-x86_64-release.apk',
};

class GithubReleaseInfo {
  const GithubReleaseInfo({
    required this.tagName,
    required this.downloadUrl,
    required this.fallbackReleasesUrl,
  });

  final String tagName;
  final String? downloadUrl;
  final String fallbackReleasesUrl;
}

class GithubReleaseService {
  GithubReleaseService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static String get _latestApi =>
      'https://api.github.com/repos/$kUpdateGithubOwner/$kUpdateGithubRepo/releases/latest';

  static String get releasesPage =>
      'https://github.com/$kUpdateGithubOwner/$kUpdateGithubRepo/releases/latest';

  Future<List<String>> _preferredAbis() async {
    if (!runsAndroidUpdateCheck) return const [];
    final plugin = DeviceInfoPlugin();
    final info = await plugin.androidInfo;
    return info.supportedAbis;
  }

  String? _pickAssetUrl(List<dynamic> assets, List<String> abis) {
    for (final abi in abis) {
      final fileName = _apkByAbi[abi];
      if (fileName == null) continue;
      for (final a in assets) {
        if (a is! Map) continue;
        if (a['name'] == fileName) {
          final u = a['browser_download_url'];
          if (u is String && u.isNotEmpty) return u;
        }
      }
    }
    for (final a in assets) {
      if (a is! Map) continue;
      final name = a['name'];
      if (name is String && name.endsWith('.apk')) {
        final u = a['browser_download_url'];
        if (u is String && u.isNotEmpty) return u;
      }
    }
    return null;
  }

  Future<GithubReleaseInfo?> fetchLatest() async {
    final abis = await _preferredAbis();
    final Response<dynamic> res;
    try {
      res = await _dio.get<dynamic>(
        _latestApi,
        options: Options(
          headers: const {
            'Accept': 'application/vnd.github+json',
          },
          validateStatus: (s) => s != null && s < 500,
        ),
      );
    } catch (_) {
      return null;
    }
    if (res.statusCode != 200 || res.data is! Map) return null;
    final map = res.data as Map<String, dynamic>;
    final tag = map['tag_name'];
    if (tag is! String || tag.isEmpty) return null;
    final assets = map['assets'];
    final list = assets is List<dynamic> ? assets : const <dynamic>[];
    final url = _pickAssetUrl(list, abis);
    return GithubReleaseInfo(
      tagName: tag,
      downloadUrl: url,
      fallbackReleasesUrl: releasesPage,
    );
  }
}

