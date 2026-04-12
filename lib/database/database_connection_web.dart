import 'package:drift/drift.dart';

LazyDatabase openAppDatabaseConnectionImpl() {
  return LazyDatabase(() async {
    throw UnsupportedError(
      'OXPlayer does not support Flutter web. Use Android, iOS, or desktop.',
    );
  });
}
