import '../../core/utils/id_generator.dart';
import '../entities/goal_entity.dart';
import '../repositories/goal_repository.dart';

/// Applies any due fixed recurring auto-saves: for each active goal with an
/// auto-save amount + period, adds the contribution(s) that have come due since
/// it last ran. Runs at app launch (catch-up) — the app can't move real money,
/// so this tracks the saving toward the goal.
class RunGoalAutoSavesUseCase {
  RunGoalAutoSavesUseCase(this._repo);

  final GoalRepository _repo;

  /// Cap to avoid a huge backfill if a goal was untouched for a long time.
  static const _maxCatchUp = 24;

  Future<void> call() async {
    final goals = await _repo.getAll();
    final now = DateTime.now();
    for (final goal in goals) {
      if (goal.status != 'active' || !goal.hasAutoSave) continue;
      final amount = goal.autoSaveAmount!;
      final period = goal.autoSavePeriod!;
      var last = goal.autoSaveLastRun ?? goal.createdAt;
      var next = _advance(last, period);
      var added = 0;
      while (!next.isAfter(now) && added < _maxCatchUp) {
        await _repo.addContribution(
          GoalContributionEntity(
            id: IdGenerator.next(),
            goalId: goal.id,
            amount: amount,
            createdAt: next,
            note: 'ادخار تلقائي',
          ),
        );
        last = next;
        next = _advance(last, period);
        added++;
      }
      if (added > 0) {
        // Re-read so we keep the contribution-updated savedAmount, then persist
        // the new last-run marker.
        final fresh = await _repo.getById(goal.id) ?? goal;
        await _repo.save(fresh.copyWith(autoSaveLastRun: last));
      }
    }
  }

  static DateTime _advance(DateTime from, String period) {
    if (period == 'weekly') return from.add(const Duration(days: 7));
    return DateTime(from.year, from.month + 1, from.day, from.hour, from.minute);
  }
}
