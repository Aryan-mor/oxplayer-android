import 'package:drift/drift.dart';

import 'database_connection_io.dart'
    if (dart.library.html) 'database_connection_web.dart';

/// Opens the app SQLite database. On IO platforms this uses a background
/// isolate with native SQLite; on web this is a stub (this app is not
/// supported on web — see [openAppDatabaseConnection] implementation there).
LazyDatabase openAppDatabaseConnection() => openAppDatabaseConnectionImpl();
