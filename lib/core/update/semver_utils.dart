/// Parsed semantic version `X.Y.Z` (non-negative integers).
class SemVer {
  const SemVer(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  /// Compares [a] vs [b]: negative if a < b, 0 if equal, positive if a > b.
  static int compare(SemVer a, SemVer b) {
    var c = a.major.compareTo(b.major);
    if (c != 0) return c;
    c = a.minor.compareTo(b.minor);
    if (c != 0) return c;
    return a.patch.compareTo(b.patch);
  }
}

/// Strips a leading `v` / `V`. Returns null if not three dot-separated ints.
SemVer? tryParseSemVer(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final t = (s.startsWith('v') || s.startsWith('V')) ? s.substring(1) : s;
  final parts = t.split('.');
  if (parts.length != 3) return null;
  final maj = int.tryParse(parts[0]);
  final min = int.tryParse(parts[1]);
  final pat = int.tryParse(parts[2]);
  if (maj == null || min == null || pat == null) return null;
  if (maj < 0 || min < 0 || pat < 0) return null;
  return SemVer(maj, min, pat);
}

/// Normalizes Android / pub-style labels before [tryParseSemVer].
///
/// - `1.0.22+45` → `1.0.22` (Flutter build number after `+`)
/// - `1.0.22-debug` / `1.0.22-profile` → `1.0.22` (Android `versionNameSuffix`)
SemVer? tryParsePackageVersionName(String version) {
  var name = version.trim();
  final plus = name.indexOf('+');
  if (plus >= 0) name = name.substring(0, plus).trim();
  final dash = name.indexOf('-');
  if (dash >= 0) name = name.substring(0, dash).trim();
  return tryParseSemVer(name);
}

/// True if [remote] is strictly newer than [local].
bool isRemoteNewer(SemVer local, SemVer remote) => SemVer.compare(local, remote) < 0;

/// Mandatory update: major/minor bump, or patch bump when [patchOptional] is false.
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

