import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';

const _apkByAbi = <String, String>{
  'arm64-v8a': 'app-arm64-v8a-release.apk',
  'armeabi-v7a': 'app-armeabi-v7a-release.apk',
  'x86_64': 'app-x86_64-release.apk',
};

class GithubReleaseInfo {
  const GithubReleaseInfo({
    required this.tagName,
    required this.downloadUrl,
    required this.releaseUrl,
    required this.releaseName,
    required this.releaseNotes,
    required this.publishedAt,
  });

  final String tagName;
  final String? downloadUrl;
  final String releaseUrl;
  final String releaseName;
  final String releaseNotes;
  final String? publishedAt;
}

class GithubReleaseService {
  GithubReleaseService({required this.owner, required this.repo, Dio? dio})
    : _dio = dio ?? Dio();

  final String owner;
  final String repo;
  final Dio _dio;

  String get latestApi => 'https://api.github.com/repos/$owner/$repo/releases/latest';

  Future<List<String>> _preferredAbis() async {
    final info = await DeviceInfoPlugin().androidInfo;
    return info.supportedAbis;
  }

  String? _pickAssetUrl(List<dynamic> assets, List<String> preferredAbis) {
    for (final abi in preferredAbis) {
      final expectedFile = _apkByAbi[abi];
      if (expectedFile == null) continue;

      for (final asset in assets) {
        if (asset is! Map) continue;
        if (asset['name'] == expectedFile) {
          final url = asset['browser_download_url'];
          if (url is String && url.isNotEmpty) return url;
        }
      }
    }

    for (final asset in assets) {
      if (asset is! Map) continue;
      final name = asset['name'];
      if (name is String && name.endsWith('.apk')) {
        final url = asset['browser_download_url'];
        if (url is String && url.isNotEmpty) return url;
      }
    }

    return null;
  }

  Future<GithubReleaseInfo?> fetchLatest({required bool includePreferredApk}) async {
    final preferredAbis = includePreferredApk ? await _preferredAbis() : const <String>[];

    final Response<dynamic> response;
    try {
      response = await _dio.get<dynamic>(
        latestApi,
        options: Options(
          headers: const {'Accept': 'application/vnd.github+json'},
          validateStatus: (status) => status != null && status < 500,
        ),
      );
    } catch (_) {
      return null;
    }

    if (response.statusCode != 200 || response.data is! Map) return null;
    final map = response.data as Map<String, dynamic>;
    final tag = map['tag_name'];
    if (tag is! String || tag.isEmpty) return null;

    final releaseUrl = map['html_url'];
    if (releaseUrl is! String || releaseUrl.isEmpty) return null;

    final assets = map['assets'];
    final assetList = assets is List<dynamic> ? assets : const <dynamic>[];

    return GithubReleaseInfo(
      tagName: tag,
      downloadUrl: includePreferredApk ? _pickAssetUrl(assetList, preferredAbis) : null,
      releaseUrl: releaseUrl,
      releaseName: map['name'] as String? ?? 'Version $tag',
      releaseNotes: map['body'] as String? ?? '',
      publishedAt: map['published_at'] as String?,
    );
  }
}