import 'package:money_companion/core/session/consent_capability.dart';
import 'package:money_companion/data/db/app_database.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/planning_sync/services/planning_outbox_queue.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/session/f2_fixture.dart';

/// "Fresh matching nonexpired SDK session" for [uid], read from [client] (the
/// existing MockClient-backed fake GoTrue client; nothing here touches a network).
bool Function() sdkSessionFresh(SupabaseClient client, String uid) => () {
      final session = client.auth.currentSession;
      return session != null && !session.isExpired && session.user.id == uid;
    };

/// A genuine explicit sign-in that STOPS at the committed identity publication:
/// the session is in onboarding (needsOnboarding), not authenticated. Returns
/// the consent capability that publication issued, or null if it issued none.
///
/// The identity evidence is the ACTUAL SDK client (the existing MockClient-backed
/// fake GoTrue client) injected through the session's typed seam; [noSdk] injects
/// none. [sessionCurrent] is the caller's own freshness predicate (production
/// passes the auth service's real one) and, on its own, never mints anything.
Future<ConsentCapability?> freshSignIn(
  F2Fixture f,
  String uid, {
  SupabaseClient? client,
  String method = 'google',
  bool Function()? sessionCurrent,
  bool noSdk = false,
}) async {
  final sdk = client ?? await F2Fixture.liveClient(uid);
  f.session.configureConsentSdkClient(() => noSdk ? null : sdk);
  await f.session.setIdentity(
    method: method,
    email: '$uid@example.com',
    userId: uid,
    sessionCurrent: sessionCurrent ?? sdkSessionFresh(sdk, uid),
  );
  return f.session.captureConsentCapability();
}

/// A real planning outbox queue over [db] that can run a hook right after the
/// settings row was enqueued (inside the consent transaction).
class HookedOutbox extends PlanningOutboxQueue {
  HookedOutbox(AppDatabase db, String uid, {this.afterEnqueue})
      : super(
          db: db,
          isSyncEnabled: (_) => true,
          getAuthUserId: () async => uid,
          getOwnerUid: () async => uid,
        );

  void Function()? afterEnqueue;
  int enqueues = 0;

  @override
  Future<bool> enqueueSettings(
    PlanningSyncOperation op,
    UserSettingsEntity settings, {
    bool consentChanged = false,
    UserSettingsEntity? previous,
  }) async {
    final result = await super.enqueueSettings(op, settings,
        consentChanged: consentChanged, previous: previous);
    enqueues++;
    afterEnqueue?.call();
    return result;
  }
}

/// Rows of the settings outbox (the atomic local outbox the typed write uses).
Future<int> settingsOutboxRows(AppDatabase db) async => (await db
        .customSelect("SELECT COUNT(*) AS n FROM planning_sync_outbox "
            "WHERE entity_type = 'settings';")
        .getSingle())
    .read<int>('n');
