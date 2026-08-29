import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import '../../data/db/database_key_store.dart';
import '../backend/supabase_config.dart';
import '../tracking/user_activity_service.dart';

/// [sessionExpired] is distinct from [needsOnboarding]: onboarding metadata
/// (auth method, completed-account keys) stays intact — only the *live*
/// Supabase session was found invalid. A router redirect to auth must never
/// clear onboarding completion for this case (see `AppSession.signOut` for
/// the separate, intentional full-reset path).
enum SessionStatus { unknown, needsOnboarding, authenticated, sessionExpired }

/// MALI-054n: thrown when a new identity cannot be admitted because the previous
/// owner's local data / native capture residue could not be fully cleared. The
/// admission path fails closed rather than exposing one user's data to another.
class LocalDataOwnershipException implements Exception {
  const LocalDataOwnershipException();

  @override
  String toString() =>
      'LocalDataOwnershipException: refused to admit a new identity onto '
      'un-purged data/residue from a previous account.';
}

/// حالة الجلسة (للتحكّم في عرض الـ Onboarding مقابل التطبيق).
///
/// ValueNotifier حتى يُستخدم كـ refreshListenable في go_router دون Riverpod.
/// تُخزَّن الأعلام في flutter_secure_storage (لا بيانات مالية هنا).
class AppSession extends ValueNotifier<SessionStatus> {
  AppSession._() : super(SessionStatus.unknown);

  static final AppSession instance = AppSession._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage();
  static const String _kDone = 'onboarding_done';
  static const String _kMethod = 'auth_method';
  static const String _kEmail = 'auth_email';
  static const String _kWelcomeManifestoSeen = 'welcome_manifesto_seen';
  static const String _kCurrentAccount = 'onboarding_current_account_v1';
  static const String _kCompletedAccounts = 'onboarding_completed_accounts_v1';
  static const String _kLocalDataOwnerUid = 'local_data_owner_uid';
  // MALI-069n §Blocker-1: the ADMISSION GENERATION. A cryptographically-random
  // nonce rotated on every genuine admission and invalidated before sign-out /
  // wipe / ownership change, so a background job bound to a previous session is
  // rejected even when the SAME UID signs in again. Read cross-isolate by
  // OwnershipGuard. Not a secret; carries no financial data.
  static const String _kLocalDataOwnerGeneration = 'local_data_owner_generation';

  /// Deterministic fallback for the H-8 wipe when secure storage cannot
  /// enumerate its entries. The sweep prefers `readAll()` (which also catches
  /// other modules' keys, e.g. backup material) and only falls back to this
  /// list, so a session key can never be missed on a platform where
  /// enumeration is unavailable.
  static const Set<String> sessionStorageKeys = {
    _kDone,
    _kMethod,
    _kEmail,
    _kWelcomeManifestoSeen,
    _kCurrentAccount,
    _kCompletedAccounts,
    _kLocalDataOwnerUid,
    _kLocalDataOwnerGeneration,
  };

  String? authMethod;
  String? email;
  bool _onboardingDone = false;
  bool _welcomeManifestoSeen = false;
  String? _currentAccountKey;
  final Set<String> _completedAccountKeys = <String>{};
  StreamSubscription<supabase.AuthState>? _supabaseAuthSubscription;
  Future<void> Function()? _unlinkCaptureDevice;
  Future<void> Function()? _wipeLocalFinancialData;
  Future<void> Function()? _flushPendingSync;

  /// MALI-054n/070n: purges USER-OWNED native + filesystem capture residue (the
  /// App Group / SharedPreferences message queue, notification routes/log, and
  /// the pending-notification-actions file) that the Drift wipe does NOT cover.
  /// Returns true only when the purge is confirmed. Injected by bootstrap so the
  /// session layer stays decoupled from the capture/native layer.
  Future<bool> Function()? _purgeLocalResidue;

  /// UID whose admission is deferred because the local DB is still owned by a
  /// DIFFERENT account and the wipe hook wasn't registered yet (the first
  /// session reconcile runs before `database_open`). Bootstrap resolves it via
  /// [resolvePendingLocalDataOwnerConflict] right after registering the wipe.
  String? _pendingOwnerConflictUid;

  SessionStatus get status => value;

  void configureCaptureDeviceUnlink(Future<void> Function()? unlink) {
    _unlinkCaptureDevice = unlink;
  }

  /// يربط تسجيل الخروج بمسح البيانات المالية المحلية (DataWipeService) قبل
  /// إتمامه — يضمن ألا تبقى بيانات المستخدم الحالي متاحة لمن يسجّل دخوله
  /// بعده على نفس الجهاز. انظر `signOut` لسبب الفشل المتحكَّم به بدل الصمت.
  void configureLocalDataWipe(Future<void> Function()? wipe) {
    _wipeLocalFinancialData = wipe;
  }

  /// دفعة أخيرة للـ outbox قبل مسح تسجيل الخروج — التغييرات الأخيرة (مثلاً
  /// تغيير الدولة قبل الخروج بثوانٍ) كانت تُمسح من الطابور قبل رفعها فتضيع
  /// نهائياً. best-effort: فشلها (أوفلاين) لا يمنع تسجيل الخروج.
  void configureSignOutFlush(Future<void> Function()? flush) {
    _flushPendingSync = flush;
  }

  /// Registers the native/filesystem residue purge (MALI-054n/070n). See
  /// [_purgeLocalResidue]. Wired by bootstrap to the capture bridge + pending
  /// actions file.
  void configureLocalResiduePurge(Future<bool> Function()? purge) {
    _purgeLocalResidue = purge;
  }

  /// Runs the injected residue purge. Returns false (cannot confirm) when the
  /// hook is not yet registered or the purge throws/reports failure — callers
  /// at identity-admission boundaries MUST treat false as "residue may remain"
  /// and fail closed.
  Future<bool> _runResiduePurge() async {
    final purge = _purgeLocalResidue;
    if (purge == null) return false;
    try {
      return await purge();
    } catch (_) {
      return false;
    }
  }

  /// آخر هوية Supabase مُؤكَّدة أنها "تملك" البيانات المالية المحلية الحالية
  /// — طبقة حماية إضافية (دفاع في العمق) تستخدمها خدمات الترحيل (backfill)
  /// لرفض رفع صفوف محلية قد تخصّ مستخدماً سابقاً لم يُمسح بياناته فعلياً
  /// (مثلاً بسبب إغلاق التطبيق أثناء مسح جزئي). `null` تعني "لا تعارض معروف"
  /// وليست إذناً غير مشروط — الترحيل يسمح بها فقط لتوافق التركيبات القديمة.
  Future<String?> readLocalDataOwnerUid() =>
      _storage.read(key: _kLocalDataOwnerUid);

  /// يسجّل مالك البيانات المحلية فقط إذا لم تكن مُطالَبة فعلاً من هوية أخرى
  /// — أول هوية "تطالب" بالبيانات المحلية بعد مسحها هي التي تُسجَّل. تعارض
  /// قائم (uid مختلف مخزَّن مسبقاً) لا يُستبدَل صامتاً؛ يجب أن يمسحه تسجيل
  /// الخروج أولاً.
  Future<void> _claimLocalDataOwnerIfUnclaimed(String uid) async {
    final existing = await _storage.read(key: _kLocalDataOwnerUid);
    if (existing == null || existing == uid) {
      try {
        await _storage.write(key: _kLocalDataOwnerUid, value: uid);
      } on PlatformException catch (e) {
        if (e.code == '-25299') {
          // Keychain item already exists, and overriding failed. Delete and retry.
          await _storage.delete(key: _kLocalDataOwnerUid);
          await _storage.write(key: _kLocalDataOwnerUid, value: uid);
        } else {
          rethrow;
        }
      }
      // MALI-069n §Blocker-1: mint a fresh admission generation ONLY when none
      // exists (a genuine (re-)admission — sign-out/wipe/ownership-change cleared
      // it). An idempotent reconcile of the SAME live session keeps its generation,
      // so its own in-flight background jobs stay valid; a real re-login always
      // sees the generation absent and rotates, rejecting the previous session's
      // jobs — even for the same UID.
      await _mintOwnerGenerationIfAbsent();
    }
  }

  /// Writes a fresh cryptographically-random admission generation iff none is
  /// currently stored.
  Future<void> _mintOwnerGenerationIfAbsent() async {
    final existing = await _storage.read(key: _kLocalDataOwnerGeneration);
    if (existing != null) return;
    await _storage.write(
        key: _kLocalDataOwnerGeneration, value: _newOwnerGeneration());
  }

  /// Invalidates the admission generation so any in-flight background job bound to
  /// it is rejected. Called BEFORE a sign-out purge / wipe / ownership change.
  Future<void> _invalidateOwnerGeneration() async {
    await _storage.delete(key: _kLocalDataOwnerGeneration);
  }

  static String _newOwnerGeneration() {
    final rng = Random.secure();
    final bytes = List<int>.generate(16, (_) => rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Ensures the shared local DB belongs to [uid] BEFORE the session is
  /// admitted (MALI-002). A stored owner with a different UID means the
  /// previous user's session ended without the sign-out wipe (expiry,
  /// revocation, crash) — their financial data must never become visible to
  /// the new identity. If the wipe hook is registered, wipe + re-claim here;
  /// if not (first reconcile runs before `database_open`), defer: record the
  /// conflict and return false so the caller withholds admission until
  /// [resolvePendingLocalDataOwnerConflict] runs.
  Future<bool> _ensureLocalDataOwnedBy(String uid) async {
    final existing = await _storage.read(key: _kLocalDataOwnerUid);
    if (existing == null || existing == uid) {
      _pendingOwnerConflictUid = null;
      if (existing == null) {
        // Claiming a currently-unowned DB. Best-effort residue purge as defense
        // in depth (e.g. a prior reset whose purge failed): a genuinely fresh
        // install has nothing to purge, so this is a no-op and never blocks
        // first-run admission (the hook may not be registered this early).
        await _runResiduePurge();
      }
      await _claimLocalDataOwnerIfUnclaimed(uid);
      return true;
    }
    final wipe = _wipeLocalFinancialData;
    if (wipe == null) {
      _pendingOwnerConflictUid = uid;
      return false;
    }
    // MALI-069n §Blocker-1: invalidate the admission generation BEFORE the
    // ownership-change wipe, so a background job from the previous owner is
    // rejected before any destructive step and the incoming owner mints a fresh
    // generation on claim below.
    await _invalidateOwnerGeneration();
    await wipe();
    // MALI-054n: a DIFFERENT identity must NOT be admitted until the previous
    // owner's native/filesystem capture residue is confirmed purged. Fail closed
    // — keep the (old) owner marker and defer; bootstrap/retry re-runs this once
    // the purge hook is available or the transient purge failure clears.
    final residuePurged = await _runResiduePurge();
    if (!residuePurged) {
      _pendingOwnerConflictUid = uid;
      return false;
    }
    await _storage.delete(key: _kLocalDataOwnerUid);
    _pendingOwnerConflictUid = null;
    await _claimLocalDataOwnerIfUnclaimed(uid);
    return true;
  }

  /// Completes an owner conflict deferred by [_ensureLocalDataOwnedBy] once
  /// the wipe hook exists (bootstrap calls this right after registering it,
  /// with the DB open). Wipes the previous account's rows, claims ownership
  /// for the pending UID, then re-runs the session reconcile so the gated
  /// identity is finally admitted against a clean DB.
  Future<void> resolvePendingLocalDataOwnerConflict(
    supabase.SupabaseClient client,
  ) async {
    if (_pendingOwnerConflictUid == null) return;
    if (_wipeLocalFinancialData == null) return;
    final uid = _pendingOwnerConflictUid!;
    final owned = await _ensureLocalDataOwnedBy(uid);
    if (!owned) return;
    await _reconcileSupabaseSession(client.auth.currentSession);
  }

  bool get isGuest => authMethod == 'guest';
  bool get hasCompletedOnboarding => _onboardingDone;
  bool get hasSeenWelcomeManifesto => _welcomeManifestoSeen;

  Future<void> load() async {
    final done = await _storage.read(key: _kDone);
    final legacyOnboardingDone = done == '1';
    final welcomeSeen = await _storage.read(key: _kWelcomeManifestoSeen);
    _welcomeManifestoSeen = welcomeSeen == '1' || legacyOnboardingDone;
    if (legacyOnboardingDone && welcomeSeen != '1') {
      await _storage.write(key: _kWelcomeManifestoSeen, value: '1');
    }
    authMethod = await _storage.read(key: _kMethod);
    email = await _storage.read(key: _kEmail);
    _completedAccountKeys
      ..clear()
      ..addAll(await _readCompletedAccountKeys());
    _currentAccountKey = await _storage.read(key: _kCurrentAccount);

    // Existing installs only had one device-wide onboarding flag. Associate it
    // with the currently stored identity once, then use account-scoped state.
    if (legacyOnboardingDone && authMethod != null) {
      _currentAccountKey ??= _identityKey(authMethod!, email);
      if (_currentAccountKey != null) {
        _completedAccountKeys.add(_currentAccountKey!);
        await _persistCompletedAccountKeys();
        await _storage.write(
          key: _kCurrentAccount,
          value: _currentAccountKey,
        );
      }
    }
    _onboardingDone = _currentAccountKey != null &&
        _completedAccountKeys.contains(_currentAccountKey);
    value = _onboardingDone && authMethod != null
        ? SessionStatus.authenticated
        : SessionStatus.needsOnboarding;
  }

  /// يعلّم شاشة الترحيب السينمائية كمرئية حتى لا تظهر إلا مرة واحدة.
  Future<void> markWelcomeManifestoSeen() async {
    if (_welcomeManifestoSeen) return;
    await _storage.write(key: _kWelcomeManifestoSeen, value: '1');
    _welcomeManifestoSeen = true;
    notifyListeners();
  }

  /// يخزّن هوية الدخول دون إنهاء الـ onboarding (تبقى خطوة الطريقة بعدها).
  Future<void> setIdentity({
    required String method,
    String? email,
    String? userId,
  }) async {
    // Owner gate (MALI-002): interactive sign-in happens long after bootstrap,
    // so a conflicting previous owner is wiped inline here before the new
    // identity is stored — user B must start from a clean local DB, never
    // on top of user A's rows.
    if (userId != null && userId.isNotEmpty) {
      final owned = await _ensureLocalDataOwnedBy(userId);
      if (!owned && _wipeLocalFinancialData != null) {
        // The wipe hook IS registered (not the early-bootstrap defer case), so a
        // not-owned result here means the previous owner's data/residue could
        // not be fully cleared. Fail closed (MALI-054n): do NOT admit this
        // identity onto it. The interactive sign-in caller catches this and
        // surfaces an error. (When the hook is absent — first reconcile before
        // database_open — admission is deferred, not blocked, as before.)
        throw const LocalDataOwnershipException();
      }
    }
    await _storage.write(key: _kMethod, value: method);
    if (email != null && email.trim().isNotEmpty) {
      await _storage.write(key: _kEmail, value: email);
    } else if (method == 'guest') {
      await _storage.delete(key: _kEmail);
    }
    authMethod = method;
    this.email = email;
    final accountKey = _accountKey(
      method: method,
      email: email,
      userId: userId,
    );
    final fallbackKey = _identityKey(method, email);
    final completed = _completedAccountKeys.contains(accountKey) ||
        (fallbackKey != null && _completedAccountKeys.contains(fallbackKey));
    _currentAccountKey = accountKey;
    await _storage.write(key: _kCurrentAccount, value: accountKey);
    if (completed && !_completedAccountKeys.contains(accountKey)) {
      _completedAccountKeys.add(accountKey);
      await _persistCompletedAccountKeys();
    }
    _onboardingDone = completed;
    if (_onboardingDone) {
      value = SessionStatus.authenticated;
      unawaited(UserActivityService.onSignIn());
    } else {
      value = SessionStatus.needsOnboarding;
    }
    // The identity can change while the coarse status stays
    // needsOnboarding (sign out, then sign in with a new account). Financial
    // providers still need a signal to discard the previous account's cache.
    notifyListeners();
  }

  /// ينهي الـ onboarding بالكامل → ينتقل للتطبيق.
  Future<void> finishOnboarding() async {
    authMethod ??= await _storage.read(key: _kMethod);
    _currentAccountKey ??= _identityKey(authMethod, email);
    if (_currentAccountKey != null) {
      _completedAccountKeys.add(_currentAccountKey!);
      await _persistCompletedAccountKeys();
      await _storage.write(key: _kCurrentAccount, value: _currentAccountKey);
    }
    await _storage.write(key: _kDone, value: '1');
    _onboardingDone = true;
    value = authMethod == null
        ? SessionStatus.needsOnboarding
        : SessionStatus.authenticated;
    await syncRemoteOnboardingCompletion();
    unawaited(UserActivityService.onSignIn());
  }

  /// Reconciles the account-scoped server marker after an interactive sign-in.
  /// Auth events can arrive before [setIdentity] stores the chosen method, so
  /// the auth screen calls this once more after setting the local identity.
  Future<bool> reconcileAccountOnboarding(
    supabase.SupabaseClient client,
  ) async {
    await _reconcileSupabaseSession(client.auth.currentSession);
    return _onboardingDone;
  }

  /// Idempotently records a locally completed setup on the authenticated
  /// profile. Failure never revokes local completion; cold start/resume retries
  /// it, preserving offline-first access while making the next device correct.
  Future<bool> syncRemoteOnboardingCompletion() async {
    if (!_onboardingDone || isGuest || !SupabaseConfig.isConfigured) {
      return false;
    }
    try {
      final client = supabase.Supabase.instance.client;
      if (client.auth.currentSession == null) return false;
      await client.rpc('mark_onboarding_completed');
      return true;
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[AppSession] onboarding completion sync deferred: '
          '${error.runtimeType}',
        );
      }
      return false;
    }
  }

  /// (توافق) دخول كامل في خطوة واحدة.
  Future<void> completeOnboarding(
      {required String method, String? email, String? userId}) async {
    await setIdentity(method: method, email: email, userId: userId);
    await finishOnboarding();
  }

  /// Signs the current identity out. Wipes local financial data FIRST — a
  /// wipe failure aborts sign-out entirely (rethrows, no identity/session
  /// state is touched) rather than leaving the device signed out while the
  /// previous user's data is still readable by whoever signs in next. Safe
  /// to call repeatedly: an already-signed-out state and an already-wiped DB
  /// are both no-ops for every step below.
  /// Runs the registered best-effort outbox flush with a bounded timeout.
  /// Public (MALI-053n) so the sign-out UI can flush and then RE-CHECK the
  /// unsynced inventory before deciding — a timeout/failure here is NEVER
  /// treated as a successful sync (the inventory re-check is the source of
  /// truth). Offline/slow network must not block the flow.
  Future<void> flushPendingForSignOut() async {
    final flush = _flushPendingSync;
    if (flush == null) return;
    try {
      await flush().timeout(const Duration(seconds: 6));
    } catch (_) {
      // Offline/slow network — surfaced by the inventory re-check, not here.
    }
  }

  Future<void> signOut() async {
    // MALI-069n §Blocker-1: invalidate the admission generation FIRST, before any
    // purge/wipe begins, so an in-flight background job bound to this session is
    // rejected at its next validation boundary and can neither commit nor
    // acknowledge under the outgoing (or a subsequent) admission.
    await _invalidateOwnerGeneration();
    // Best-effort final push BEFORE the wipe: the wipe deletes the sync
    // outboxes, so any change made in the last seconds (e.g. a country
    // change right before signing out) would otherwise be destroyed
    // un-uploaded. Offline sign-out still proceeds.
    await flushPendingForSignOut();
    final wipe = _wipeLocalFinancialData;
    if (wipe != null) {
      await wipe();
    }
    // MALI-054n/070n: purge native + filesystem capture residue BEFORE releasing
    // ownership. If the purge cannot be confirmed, KEEP the owner uid so the DB
    // stays marked as owned by THIS identity — the next DIFFERENT user then hits
    // the conflict path (_ensureLocalDataOwnedBy), which re-purges and fails
    // closed rather than admitting them onto un-purged residue. (Same user
    // re-login is unaffected: their own residue is not a cross-user leak.)
    final residuePurged = await _runResiduePurge();
    if (residuePurged) {
      await _storage.delete(key: _kLocalDataOwnerUid);
    }
    UserActivityService.onSignOut();
    final unlink = _unlinkCaptureDevice;
    if (unlink != null) {
      unawaited(
        unlink().timeout(const Duration(seconds: 4)).catchError((_) {
          // Sign-out is authoritative locally. A failed best-effort unlink is
          // safe because per-row claimed_user_id still prevents cross-user sync.
        }),
      );
    }
    await _storage.delete(key: _kMethod);
    await _storage.delete(key: _kEmail);
    await _storage.delete(key: _kCurrentAccount);
    authMethod = null;
    email = null;
    _currentAccountKey = null;
    _onboardingDone = false;
    value = SessionStatus.needsOnboarding;
  }

  Future<void> bindSupabaseAuth(supabase.SupabaseClient client) async {
    _supabaseAuthSubscription ??=
        client.auth.onAuthStateChange.listen(_handleSupabaseAuthChange);
    await _reconcileSupabaseSession(client.auth.currentSession);
  }

  /// Re-checks the live Supabase session against the current in-memory
  /// client state. Call on app resume (a refresh token can be revoked or
  /// expire while backgrounded, with no auth-state event delivered until the
  /// app is foregrounded again and something touches the client).
  Future<void> revalidateSupabaseSessionOnResume(
    supabase.SupabaseClient client,
  ) async {
    // No isConfigured gate here: the caller (AppShell) already checks it
    // before ever obtaining a client to pass in — a redundant check on the
    // already-injected client only makes this harder to exercise in tests
    // (SupabaseConfig reads compile-time dart-defines, empty under a plain
    // `flutter test` run) for no behavioral benefit.
    await _reconcileSupabaseSession(client.auth.currentSession);
  }

  /// Called by a Supabase-primary repository consumer (see
  /// `RepoException`/`AuthRepoException`) when a call fails specifically
  /// because there is no valid authenticated session. Downgrades status to
  /// [SessionStatus.sessionExpired] so the router redirects to sign-in.
  ///
  /// Idempotent and safe to call from multiple concurrent failures: setting
  /// [value] to its current value is a no-op in [ValueNotifier] (no repeated
  /// `notifyListeners()`), so N simultaneous `auth_required` failures produce
  /// exactly one status transition and one router redirect, never a storm.
  Future<void> handleAuthRequiredFailure() async {
    if (isGuest || authMethod == null) return;
    if (value == SessionStatus.sessionExpired) return;
    markSessionInvalid();
  }

  /// Downgrades an authenticated (or unknown) status to [sessionExpired]
  /// without touching onboarding completion, the stored identity, or any
  /// unrelated local preference — only the *live* session judgment changes.
  void markSessionInvalid() {
    if (isGuest || authMethod == null) return;
    if (value == SessionStatus.sessionExpired) return;
    value = SessionStatus.sessionExpired;
    if (kDebugMode) {
      debugPrint('[AppSession] session invalid/expired → sessionExpired');
    }
  }

  Future<void> _handleSupabaseAuthChange(supabase.AuthState state) async {
    switch (state.event) {
      case supabase.AuthChangeEvent.signedOut:
      case supabase.AuthChangeEvent.userDeleted:
        if (!isGuest && authMethod != null) {
          try {
            await signOut();
          } catch (_) {
            // This is a server-driven sign-out with no interactive context
            // to surface a retry prompt in. The explicit, user-initiated
            // sign-out path is where a wipe failure must block and report —
            // see AppSession.signOut's doc comment.
          }
        }
        return;
      case supabase.AuthChangeEvent.initialSession:
      case supabase.AuthChangeEvent.signedIn:
      case supabase.AuthChangeEvent.tokenRefreshed:
      case supabase.AuthChangeEvent.userUpdated:
        await _reconcileSupabaseSession(state.session);
        return;
      case supabase.AuthChangeEvent.passwordRecovery:
      case supabase.AuthChangeEvent.mfaChallengeVerified:
        return;
    }
  }

  Future<void> _reconcileSupabaseSession(supabase.Session? session) async {
    if (isGuest || authMethod == null) return;
    if (session == null) {
      // A null session here is only ambiguous mid-onboarding (identity set,
      // setup not finished yet) — that's already correctly `needsOnboarding`
      // and must be left alone. Once onboarding was actually completed once
      // before, a null session is unambiguous: the previously-valid Supabase
      // session is gone (refresh-token failure, revocation, expiry). Local
      // onboarding/account metadata is NOT sufficient by itself to grant
      // access — downgrade to sessionExpired so the router sends the user
      // back to sign-in, without erasing onboarding completion.
      if (_onboardingDone) markSessionInvalid();
      return;
    }
    // Owner gate (MALI-002): never admit a UID while the local DB still holds
    // a different account's data. When the wipe hook isn't registered yet
    // (first reconcile runs before database_open), leave the coarse status
    // untouched — the boot loader is showing — and let bootstrap resolve the
    // conflict via resolvePendingLocalDataOwnerConflict, which re-enters here.
    final owned = await _ensureLocalDataOwnedBy(session.user.id);
    if (!owned) return;
    final remoteEmail = session.user.email;
    final previousEmail = email;
    final accountKey = _accountKey(
      method: authMethod!,
      email: remoteEmail ?? previousEmail,
      userId: session.user.id,
    );
    final fallbackKey = _identityKey(authMethod, previousEmail);
    final sameIdentity = remoteEmail != null &&
        previousEmail != null &&
        remoteEmail.trim().toLowerCase() == previousEmail.trim().toLowerCase();
    var completed = _completedAccountKeys.contains(accountKey) ||
        (sameIdentity &&
            fallbackKey != null &&
            _completedAccountKeys.contains(fallbackKey));
    if (!completed) {
      completed = await _readRemoteOnboardingCompletion(
        session.user.id,
      );
    }
    _currentAccountKey = accountKey;
    await _storage.write(key: _kCurrentAccount, value: accountKey);
    if (completed && !_completedAccountKeys.contains(accountKey)) {
      _completedAccountKeys.add(accountKey);
      await _persistCompletedAccountKeys();
    }
    _onboardingDone = completed;
    value =
        completed ? SessionStatus.authenticated : SessionStatus.needsOnboarding;
    if (remoteEmail != null && remoteEmail.trim().isNotEmpty) {
      email = remoteEmail;
      await _storage.write(key: _kEmail, value: remoteEmail);
    }
    notifyListeners();
  }

  Future<bool> _readRemoteOnboardingCompletion(String userId) async {
    if (!SupabaseConfig.isConfigured) return false;
    try {
      final row = await supabase.Supabase.instance.client
          .from('profiles')
          .select('onboarding_completed_at')
          .eq('id', userId)
          .maybeSingle();
      return row?['onboarding_completed_at'] != null;
    } catch (error) {
      // Offline startup and a not-yet-deployed additive migration both fall
      // back to the account-scoped local marker. Never convert either into a
      // false completion or an auth failure.
      if (kDebugMode) {
        debugPrint(
          '[AppSession] remote onboarding lookup skipped: '
          '${error.runtimeType}',
        );
      }
      return false;
    }
  }

  String _accountKey({
    required String method,
    String? email,
    String? userId,
  }) {
    final cleanUserId = userId?.trim();
    if (cleanUserId != null && cleanUserId.isNotEmpty) {
      return 'uid:$cleanUserId';
    }
    return _identityKey(method, email) ?? 'method:$method';
  }

  String? _identityKey(String? method, String? email) {
    if (method == null) return null;
    final cleanEmail = email?.trim().toLowerCase();
    if (cleanEmail != null && cleanEmail.isNotEmpty) {
      return '$method:$cleanEmail';
    }
    if (method == 'guest') return 'guest';
    return null;
  }

  Future<Set<String>> _readCompletedAccountKeys() async {
    final raw = await _storage.read(key: _kCompletedAccounts);
    if (raw == null || raw.isEmpty) return <String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <String>{};
      return decoded.whereType<String>().toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> _persistCompletedAccountKeys() {
    final values = _completedAccountKeys.toList()..sort();
    return _storage.write(
      key: _kCompletedAccounts,
      value: jsonEncode(values),
    );
  }

  /// حذف الحساب وكل البيانات المحلية (Privacy → حذف كل بياناتي).
  Future<void> wipeAndReset() async {
    // MALI-054n/070n: purge native + filesystem capture residue as part of the
    // full reset (account deletion / reset-all), BEFORE the secure-storage wipe
    // drops the owner marker — otherwise leftover native captures could be
    // imported by the next identity that null-claims the reset device.
    await _runResiduePurge();
    // Audit H-8. The SQLCipher key must survive this wipe: the caller empties
    // the DB tables, but the encrypted FILE stays on disk, so destroying its key
    // would orphan that file and make the database unopenable next launch
    // ("تعذّر فتح بياناتك").
    //
    // This used to be `read(dbKey) → deleteAll() → write(dbKey)`, which left a
    // window where the database existed with no key. A crash or a failing write
    // in that window destroyed the data irreversibly. The key is now NEVER
    // deleted, so that state is unreachable by construction; an interruption
    // can only leave some non-key entries behind, which re-running clears.
    final wipe = await wipeSecureStoragePreservingDatabaseKey(
      readAll: () => _storage.readAll(),
      delete: (key) => _storage.delete(key: key),
      knownKeys: sessionStorageKeys,
    );
    authMethod = null;
    email = null;
    _onboardingDone = false;
    _welcomeManifestoSeen = false;
    _currentAccountKey = null;
    _completedAccountKeys.clear();
    value = SessionStatus.needsOnboarding;
    // In-memory state is signed-out first, so a reported failure still leaves
    // the app in a safe state — but the failure IS reported: a wipe that left
    // credentials or backup material behind must not look like success.
    if (!wipe.isComplete) {
      throw SecureStorageWipeIncompleteException(wipe.failed.length);
    }
  }
}
