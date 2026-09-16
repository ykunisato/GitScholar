import '../../domain/entities/settings.dart';
import 'app_database.dart';

/// Persists [Settings] in the key/value table.
class SettingsStore {
  SettingsStore(this.db);

  final AppDatabase db;
  static const _key = 'settings';

  Future<Settings> load() async {
    final v = await db.getValue(_key);
    return v is Map
        ? Settings.fromJson(Map<String, dynamic>.from(v))
        : const Settings();
  }

  Future<void> save(Settings s) => db.setValue(_key, s.toJson());
}
