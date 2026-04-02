/// GitHub Releases source for in-app update checks.
const String kUpdateGithubOwner = 'Aryan-mor';
const String kUpdateGithubRepo = 'tele-cima-android';

/// When true, a newer release that only increases the **patch** (Z in X.Y.Z) while
/// keeping the same major/minor shows Download / Skip / Close. When false, any
/// newer X.Y.Z (including patch-only) is treated as mandatory — only Download.
///
/// CI in this repo tags `v1.0.<run>` (patch-only). Set to `false` if every release
/// must block the app until the user installs (per “Y or Z change is required”).
const bool kPatchOnlyUpdatesAreOptional = true;
