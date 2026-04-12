import 'dart:io';

import 'package:path/path.dart' as p;

import '../mpv/mpv.dart';

/// URIs that [preferred] may refer to (track.uri and `external:` id form).
List<String> subtitlePreferredSourceUris(SubtitleTrack preferred) {
  final out = <String>[];
  if (preferred.uri != null && preferred.uri!.isNotEmpty) {
    out.add(preferred.uri!);
  }
  if (preferred.id.startsWith('external:')) {
    final embedded = preferred.id.substring('external:'.length);
    if (embedded.isNotEmpty) {
      out.add(embedded);
    }
  }
  return out;
}

bool subtitleSourceUrisEqual(String? a, String? b) {
  if (a == null || b == null || a.isEmpty || b.isEmpty) {
    return false;
  }
  final na = normalizeSubtitleSourceUriForCompare(a);
  final nb = normalizeSubtitleSourceUriForCompare(b);
  if (na == null || nb == null) {
    return false;
  }
  if (Platform.isWindows) {
    return na.toLowerCase() == nb.toLowerCase();
  }
  return na == nb;
}

/// True if [candidateUri] matches any storage URI implied by [preferred].
bool subtitleTrackRefersToCandidateUri(SubtitleTrack preferred, String? candidateUri) {
  for (final pref in subtitlePreferredSourceUris(preferred)) {
    if (subtitleSourceUrisEqual(candidateUri, pref)) {
      return true;
    }
  }
  return false;
}

String? normalizeSubtitleSourceUriForCompare(String uri) {
  final trimmed = uri.trim();
  final parsed = Uri.tryParse(trimmed);
  if (parsed != null && parsed.scheme == 'file') {
    try {
      return p.normalize(parsed.toFilePath(windows: Platform.isWindows));
    } catch (_) {
      return null;
    }
  }
  if (parsed != null && (parsed.scheme == 'http' || parsed.scheme == 'https')) {
    return parsed.toString();
  }
  if (parsed == null || trimmed.isEmpty) {
    return null;
  }
  if (!trimmed.contains('://')) {
    return p.normalize(trimmed);
  }
  return trimmed;
}
