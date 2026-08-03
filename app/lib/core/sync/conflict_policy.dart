/// MALI-022 / MALI-057n — the single source of truth for how every synced
/// entity handles multi-device concurrency and conflict resolution.
///
/// Before this, conflict handling was scattered and inconsistent: some entities
/// compared `server_updated_at` and flagged `sync_status='conflict'`, some
/// upserted blindly, and only four planning entities had a way OUT of the
/// conflict state — transactions, accounts, cards, categories and settings could
/// get stuck in `conflict` forever. This table declares, for all twelve
/// entities, the server mechanism (Batch 3A migration 0068) and the client
/// resolution strategy the universal resolver applies.
library;

/// The concurrency mechanism the SERVER enforces for an entity (migration 0068).
enum ConflictMechanism {
  /// In-place mutable row guarded by the server-owned `revision` compare-and-set.
  revisionCas,

  /// Written as idempotent keyed inserts + tombstones. A replay is a no-op, so
  /// two devices can never truly collide — no conflict state exists.
  appendOnlyIdempotent,
}

/// How the CLIENT resolves a detected conflict.
enum ConflictResolution {
  /// Surface the collision and let the user choose keep-mine / keep-theirs.
  /// Used for user-authored financial records, where silently dropping either
  /// side is unacceptable.
  interactive,

  /// Auto-resolve in favour of the server copy — the version another device has
  /// already committed. Used for low-stakes config where a prompt would be
  /// noise. This only ever discards THIS device's un-pushed edit; it never
  /// overwrites (and so never silently loses) the remote edit.
  deterministicPreferRemote,

  /// The entity cannot reach a conflict state (append-only idempotent children).
  none,
}

/// Which durable outbox carries an entity's pending mutations. The two outboxes
/// key their rows differently (ledger by `transaction_id`; planning by
/// `entity_type` + `entity_id`), so the resolver needs to know which to target.
enum OutboxKind { ledger, planning }

/// The concurrency + resolution contract for one entity.
class EntityConflictPolicy {
  const EntityConflictPolicy({
    required this.entityType,
    required this.localTable,
    required this.remoteTable,
    required this.outbox,
    required this.mechanism,
    required this.resolution,
    this.labelSql,
    this.softDelete = true,
  });

  /// Canonical entity key. For planning-managed entities these values MUST match
  /// `PlanningOutboxQueue.*EntityType` (they are the same strings) so the
  /// resolver can address the planning outbox rows.
  final String entityType;

  /// The local (Drift) table holding the row + its sync columns
  /// (`server_id`, `server_updated_at`, `sync_status`).
  final String localTable;

  /// The remote (Supabase) table the row syncs to.
  final String remoteTable;

  /// Which outbox holds this entity's pending mutations.
  final OutboxKind outbox;

  final ConflictMechanism mechanism;
  final ConflictResolution resolution;

  /// SQL expression yielding a human-readable label for the interactive picker.
  /// Null for entities that never surface interactively.
  final String? labelSql;

  /// Whether the local table tombstones deletes with a `deleted_at` column. The
  /// ledger hard-deletes transactions locally (no such column), so its conflict
  /// listing must not filter on it.
  final bool softDelete;

  bool get isInteractive => resolution == ConflictResolution.interactive;
  bool get isDeterministic =>
      resolution == ConflictResolution.deterministicPreferRemote;
  bool get canConflict => resolution != ConflictResolution.none;
}

/// Canonical entity keys (see [EntityConflictPolicy.entityType]).
class ConflictEntities {
  ConflictEntities._();

  static const String transaction = 'transaction';
  static const String account = 'account';
  static const String budget = 'budget';
  static const String subscription = 'subscription';
  static const String goal = 'goal';
  static const String plan = 'plan';
  static const String card = 'card';
  static const String category = 'category';
  static const String settings = 'settings';
  static const String billPayment = 'bill_payment';
  static const String goalContribution = 'goal_contribution';
  static const String planLink = 'plan_transaction_link';
}

/// The authoritative policy table. Covers all twelve synced entities.
///
///   ── revision CAS + interactive (user-authored financial data) ──
///   transaction, account, budget, subscription, goal, plan
///   ── revision CAS + deterministic prefer-remote (low-stakes config) ──
///   card, category, settings
///   ── append-only idempotent, no conflict possible ──
///   bill_payment, goal_contribution, plan_transaction_link
const Map<String, EntityConflictPolicy> kConflictPolicies = {
  ConflictEntities.transaction: EntityConflictPolicy(
    entityType: ConflictEntities.transaction,
    localTable: 'transactions',
    remoteTable: 'user_transactions',
    outbox: OutboxKind.ledger,
    mechanism: ConflictMechanism.revisionCas,
    resolution: ConflictResolution.interactive,
    labelSql: 'COALESCE(raw_merchant, CAST(amount AS TEXT))',
    softDelete: false, // transactions are hard-deleted locally
  ),
  ConflictEntities.account: EntityConflictPolicy(
    entityType: ConflictEntities.account,
    localTable: 'accounts',
    remoteTable: 'user_accounts',
    outbox: OutboxKind.planning,
    mechanism: ConflictMechanism.revisionCas,
    resolution: ConflictResolution.interactive,
    labelSql: 'name',
  ),
  ConflictEntities.budget: EntityConflictPolicy(
    entityType: ConflictEntities.budget,
    localTable: 'budgets',
    remoteTable: 'user_budgets',
    outbox: OutboxKind.planning,
    mechanism: ConflictMechanism.revisionCas,
    resolution: ConflictResolution.interactive,
    labelSql: "'ميزانية ' || CAST(amount AS TEXT)",
  ),
  ConflictEntities.subscription: EntityConflictPolicy(
    entityType: ConflictEntities.subscription,
    localTable: 'subscriptions',
    remoteTable: 'user_subscriptions',
    outbox: OutboxKind.planning,
    mechanism: ConflictMechanism.revisionCas,
    resolution: ConflictResolution.interactive,
    labelSql: 'name',
  ),
  ConflictEntities.goal: EntityConflictPolicy(
    entityType: ConflictEntities.goal,
    localTable: 'goals',
    remoteTable: 'user_goals',
    outbox: OutboxKind.planning,
    mechanism: ConflictMechanism.revisionCas,
    resolution: ConflictResolution.interactive,
    labelSql: 'name',
  ),
  ConflictEntities.plan: EntityConflictPolicy(
    entityType: ConflictEntities.plan,
    localTable: 'plans',
    remoteTable: 'user_plans',
    outbox: OutboxKind.planning,
    mechanism: ConflictMechanism.revisionCas,
    resolution: ConflictResolution.interactive,
    labelSql: 'name',
  ),
  ConflictEntities.card: EntityConflictPolicy(
    entityType: ConflictEntities.card,
    localTable: 'cards',
    remoteTable: 'user_cards',
    outbox: OutboxKind.planning,
    mechanism: ConflictMechanism.revisionCas,
    resolution: ConflictResolution.deterministicPreferRemote,
  ),
  ConflictEntities.category: EntityConflictPolicy(
    entityType: ConflictEntities.category,
    localTable: 'categories',
    remoteTable: 'user_categories',
    outbox: OutboxKind.planning,
    mechanism: ConflictMechanism.revisionCas,
    resolution: ConflictResolution.deterministicPreferRemote,
  ),
  ConflictEntities.settings: EntityConflictPolicy(
    entityType: ConflictEntities.settings,
    localTable: 'user_settings',
    remoteTable: 'user_settings',
    outbox: OutboxKind.planning,
    mechanism: ConflictMechanism.revisionCas,
    resolution: ConflictResolution.deterministicPreferRemote,
  ),
  ConflictEntities.billPayment: EntityConflictPolicy(
    entityType: ConflictEntities.billPayment,
    localTable: 'bill_payments',
    remoteTable: 'user_bill_payments',
    outbox: OutboxKind.planning,
    mechanism: ConflictMechanism.appendOnlyIdempotent,
    resolution: ConflictResolution.none,
  ),
  ConflictEntities.goalContribution: EntityConflictPolicy(
    entityType: ConflictEntities.goalContribution,
    localTable: 'goal_contributions',
    remoteTable: 'user_goal_contributions',
    outbox: OutboxKind.planning,
    mechanism: ConflictMechanism.appendOnlyIdempotent,
    resolution: ConflictResolution.none,
  ),
  ConflictEntities.planLink: EntityConflictPolicy(
    entityType: ConflictEntities.planLink,
    localTable: 'plan_transaction_links',
    remoteTable: 'user_plan_transaction_links',
    outbox: OutboxKind.planning,
    mechanism: ConflictMechanism.appendOnlyIdempotent,
    resolution: ConflictResolution.none,
  ),
};

/// Policy lookup by canonical entity key. Throws for an unknown entity so a
/// miswired caller fails loudly rather than silently skipping resolution.
EntityConflictPolicy conflictPolicyFor(String entityType) {
  final policy = kConflictPolicies[entityType];
  if (policy == null) {
    throw ArgumentError('No conflict policy for entity "$entityType"');
  }
  return policy;
}

/// The entities whose conflicts are surfaced for the user to resolve.
Iterable<EntityConflictPolicy> get interactiveConflictPolicies =>
    kConflictPolicies.values.where((p) => p.isInteractive);

/// The entities whose conflicts are auto-resolved in favour of the server copy.
Iterable<EntityConflictPolicy> get deterministicConflictPolicies =>
    kConflictPolicies.values.where((p) => p.isDeterministic);
