/// Exception thrown when cast operations fail.
///
/// This exception wraps errors that occur during TV casting operations,
/// providing a descriptive message and optionally preserving the original error.
class CastException implements Exception {
  /// A descriptive message explaining what went wrong.
  final String message;

  /// The original error that caused this exception, if any.
  final Object? originalError;

  /// Creates a new [CastException] with the given [message].
  ///
  /// Optionally includes the [originalError] that caused this exception.
  CastException(this.message, [this.originalError]);

  @override
  String toString() => 'CastException: $message';
}
