import 'dart:io';

import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';

import 'app.dart';
import 'infrastructure/local/app_database.dart';
import 'infrastructure/local/blob_store.dart';
import 'infrastructure/local/secure_store.dart';
import 'presentation/core/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await pdfrxFlutterInitialize();
  final support = await getApplicationSupportDirectory();
  final db = AppDatabase(
    driftDatabase(
      name: 'gitscholar',
      native: const DriftNativeOptions(
        databaseDirectory: getApplicationSupportDirectory,
      ),
    ),
  );
  final blobs = FileBlobStore(
    root: Directory(p.join(support.path, 'blobs')),
    db: db,
  );
  final secure = PlatformSecureStore();
  final token = await secure.read(SecureStore.githubToken);
  runApp(
    ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        blobStoreProvider.overrideWithValue(blobs),
        secureStoreProvider.overrideWithValue(secure),
        githubTokenProvider.overrideWith(() => GitHubTokenController(token)),
      ],
      child: const GitScholarApp(),
    ),
  );
}
