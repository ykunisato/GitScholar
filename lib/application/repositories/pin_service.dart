import '../../domain/entities/entities.dart';
import '../../infrastructure/local/app_database.dart';

/// Pinning repositories to the top of the list (FR-16).
class PinService {
  PinService(this.db, {DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final AppDatabase db;
  final DateTime Function() _clock;

  /// Maximum number of pinned repositories.
  static const maxPinned = 10;

  /// Pins or unpins [repo]. Returns false when the limit is reached.
  Future<bool> toggle(RepositoryRef repo) async {
    if (repo.isPinned) {
      await db.setPinnedAt(repo.fullName, null);
      return true;
    }
    if (await db.pinnedCount() >= maxPinned) return false;
    await db.setPinnedAt(repo.fullName, _clock());
    return true;
  }

  Future<bool> isFull() async => await db.pinnedCount() >= maxPinned;

  /// Pinned repositories, oldest pin first.
  static List<RepositoryRef> pinnedOf(List<RepositoryRef> all) => [
    for (final r in all)
      if (r.isPinned) r,
  ]..sort((a, b) => a.pinnedAt!.compareTo(b.pinnedAt!));
}
