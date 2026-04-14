class SemVer {
  const SemVer(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static int compare(SemVer a, SemVer b) {
    var result = a.major.compareTo(b.major);
    if (result != 0) return result;
    result = a.minor.compareTo(b.minor);
    if (result != 0) return result;
    return a.patch.compareTo(b.patch);
  }
}

/// Strips a leading `v` / `V` and Flutter/Gradle `+build` metadata so `1.31.3+67`
/// and `v1.31.3` compare equal for update prompts.
String normalizeComparableVersionCore(String raw) {
  var s = raw.trim();
  if (s.isEmpty) return s;
  if (s.startsWith('v') || s.startsWith('V')) {
    s = s.substring(1).trim();
  }
  final plusIndex = s.indexOf('+');
  if (plusIndex >= 0) {
    s = s.substring(0, plusIndex).trim();
  }
  return s;
}

SemVer? tryParseSemVer(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;

  var normalized =
      (trimmed.startsWith('v') || trimmed.startsWith('V'))
      ? trimmed.substring(1)
      : trimmed;
  final plusIndex = normalized.indexOf('+');
  if (plusIndex >= 0) {
    normalized = normalized.substring(0, plusIndex).trim();
  }
  final parts = normalized.split('.');
  if (parts.length != 3) return null;

  final major = int.tryParse(parts[0]);
  final minor = int.tryParse(parts[1]);
  final patch = int.tryParse(parts[2]);
  if (major == null || minor == null || patch == null) return null;
  if (major < 0 || minor < 0 || patch < 0) return null;

  return SemVer(major, minor, patch);
}

SemVer? tryParsePackageVersionName(String version) {
  var normalized = version.trim();
  final plusIndex = normalized.indexOf('+');
  if (plusIndex >= 0) {
    normalized = normalized.substring(0, plusIndex).trim();
  }
  final dashIndex = normalized.indexOf('-');
  if (dashIndex >= 0) {
    normalized = normalized.substring(0, dashIndex).trim();
  }
  return tryParseSemVer(normalized);
}

bool isRemoteNewer(SemVer local, SemVer remote) =>
    SemVer.compare(local, remote) < 0;

bool isMandatorySemverBump({
  required SemVer local,
  required SemVer remote,
  required bool patchOptional,
}) {
  if (!isRemoteNewer(local, remote)) return false;
  if (remote.major != local.major) return true;
  if (remote.minor != local.minor) return true;
  if (patchOptional) return false;
  return remote.patch > local.patch;
}