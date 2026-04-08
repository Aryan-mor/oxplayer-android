/// Layout constants for Android TV UI.
///
/// These are used for consistent padding/insets across TV screens.
class AppLayout {
  const AppLayout._();

  /// Standard horizontal inset for TV screen edges (left/right padding).
  static const double tvHorizontalInset = 48.0;

  /// Standard bottom inset for TV screens (accounts for bottom nav/overscan).
  static const double screenBottomInset = 24.0;

  /// Vertical gap between sections on a TV screen.
  static const double tvSectionVerticalGap = 16.0;
}
