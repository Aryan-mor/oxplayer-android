import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

LazyDatabase openAppDatabaseConnectionImpl() {
  return LazyDatabase(() async {
    final dbFolder = (Platform.isAndroid || Platform.isIOS)
        ? await getApplicationDocumentsDirectory()
        : await getApplicationSupportDirectory();

    final file = File(p.join(dbFolder.path, 'plezy_downloads.db'));

    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }

    if (!Platform.isAndroid && !Platform.isIOS && !await file.exists()) {
      final oldFolder = await getApplicationDocumentsDirectory();
      final oldFile = File(p.join(oldFolder.path, 'plezy_downloads.db'));
      if (await oldFile.exists()) {
        await oldFile.rename(file.path);
      }
    }

    return NativeDatabase.createInBackground(file, setup: (db) {
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA synchronous=NORMAL');
    });
  });
}
