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
import '../security/secure_storage_options.dart';
import '../sync/sync_wakeup.dart' show AuthSessionValid;
import 'account_scope.dart';
import 'remove_data_flow.dart';

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

/// Outcome of reconciling the local-data owner marker with an identity.
enum LocalDataOwnership {
  /// The marker was READ BACK equal to the identity. Safe to admit.
  owned,

  /// The wipe hook is not registered yet (the first reconcile runs before
  /// `database_open`). Nothing was attempted; bootstrap resolves it through
  /// [AppSession.resolvePendingLocalDataOwnerConflict].
  deferred,

  /// Ownership could not be conclusively established. Local data is
  /// PRESERVED and the identity must not be admitted.
  unresolved,
}

/// حالة الجلسة (للتحكّم في عرض الـ Onboarding مقابل التطبيق).
///
/// ValueNotifier حتى يُستخدم كـ refreshListenable في go_router دون Riverpod.
/// تُخزَّن الأعلام في flutter_secure_storage (لا بيانات مالية هنا).
class AppSession extends ValueNotifier<SessionStatus> {
  AppSession._() : super(SessionStatus.unknown);

  static final AppSession instance = AppSession._();

  static const FlutterSecureStorage _storage = SecureStorageOptions.storage;
  static const String _kDone = 'onboarding_done';
  static const String _kMethod = 'auth_method';
  static const String _kEmail = 'auth_email';
  static const String _kWelcomeManifestoSeen = 'welcome_manifesto_seen';

  /// Coach marks already shown, as a comma-separated id list. One key rather
  /// than one per mark, so [sessionStorageKeys] — which the sign-out wipe walks
  /// explicitly — cannot fall out of date as marks are added.
  static const String _kCoachMarksSeen = 'coach_marks_seen';
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
    _kCoachMarksSeen,
    _kCurrentAccount,
    _kCompletedAccounts,
    _kLocalDataOwnerUid,
    _kLocalDataOwnerGeneration,
  };

  String? authMethod;
  String? email;
  bool _onboardingDone = false;
  bool _welcomeManifestoSeen = false;
  Set<String> _coachMarksSeen = <String>{};
  String? _currentAccountKey;
  final Set<String> _completedAccountKeys = <String>{};
  StreamSubscription<supabase.AuthState>? _supabaseAuthSubscription;
  Future<void> Function()? _unlinkCaptureDevice;
  Future<void> Function()? _flushPendingSync;

  /// WP-3b: the account-scope layer. Null before bootstrap has opened a database
  /// (the first reconcile runs before `database_open`): the owner marker is then
  /// the whole admission and bootstrap opens the replica the marker names.
  AccountScopeControl? _accountScope;

  /// WP-3b: the §4.4 Remove-data flow. Null until bootstrap registers it.
  RemoveDataFlow? _removeData;

  /// MALI-054n/070n, reshaped by WP-3b: releases the native capture OWNER and
  /// clears device-wide non-queue residue (pending notification actions, OS
  /// reminders) at an account transition. It does NOT purge waiting queue items:
  /// a non-active owner's items wait (§4.2); only the Remove-data barrier purges.
  /// Returns true only when confirmed. Injected by bootstrap so the session layer
  /// stays decoupled from the capture/native layer.
  Future<bool> Function()? _captureOwnerClear;

  /// Same, for a PLAIN sign-out (the owner hint is kept). Falls back to
  /// [_captureOwnerClear] when not registered.
  Future<bool> Function()? _captureOwnerClearAtSignOut;

  /// Publishes the admitted uid as the native capture owner (WP-6 gates it on
  /// the consent link). Best effort; never blocks admission.
  Future<void> Function(String uid)? _publishCaptureOwner;

  /// UID whose admission is deferred because another account's native residue
  /// has to be purged first and the purge hook wasn't registered yet (the first
  /// session reconcile runs before bootstrap registers it). Bootstrap resolves it
  /// via [resolvePendingLocalDataOwnerConflict] right after registering the purge.
  String? _pendingOwnerConflictUid;

  /// Owner-marker value an OLDER build left while its wipe-and-reclaim
  /// transition was in flight. Never a valid uid, so every reader of the marker
  /// treats it as "not this user" and fails closed. This build no longer writes
  /// it (there is no wipe-and-reclaim: each uid has its own replica); a leftover
  /// is just a conflict, resolved by purging residue and claiming for the uid.
  static const String _kOwnerTransitionPrefix = 'owner-transition-pending:';

  /// Serialises every ownership reconcile. Bootstrap, the auth stream
  /// (initialSession / signedIn / tokenRefreshed), AppShell resume
  /// revalidation and interactive sign-in can all reach
  /// [_ensureLocalDataOwnedBy] in the same instant; running them one at a time
  /// means a transition happens once and the rest observe its verified result.
  Future<void> _ownershipTail = Future<void>.value();

  /// A uid whose ownership could not be resolved in THIS process. Automatic
  /// paths (auth events, resume, bootstrap re-entry) short-circuit to
  /// [LocalDataOwnership.unresolved] instead of re-attempting on every event;
  /// an interactive sign-in ([setIdentity]) clears it for one fresh attempt.
  String? _unresolvedOwnerUid;

  /// Bumped by every server-driven auth loss. A reconcile that started before one
  /// must not overwrite its `sessionExpired` once its (now slower: it opens a
  /// replica) admission finishes.
  int _authLossSeq = 0;

  SessionStatus get status => value;

  void configureCaptureDeviceUnlink(Future<void> Function()? unlink) {
    _unlinkCaptureDevice = unlink;
  }

  /// WP-3b: wires the per-uid replica layer. Sign-out then LOCKS the active
  /// replica instead of wiping it, and an admitted uid unlocks and opens its own.
  void configureAccountScope(AccountScopeControl? scope) {
    _accountScope = scope;
  }

  /// WP-3b: wires the §4.4 Remove-data flow (see [removeDataFromDevice]).
  void configureRemoveData(RemoveDataFlow? flow) {
    _removeData = flow;
  }

  /// دفعة أخيرة للـ outbox قبل مسح تسجيل الخروج — التغييرات الأخيرة (مثلاً
  /// تغيير الدولة قبل الخروج بثوانٍ) كانت تُمسح من الطابور قبل رفعها فتضيع
  /// نهائياً. best-effort: فشلها (أوفلاين) لا يمنع تسجيل الخروج.
  void configureSignOutFlush(Future<void> Function()? flush) {
    _flushPendingSync = flush;
  }

  /// Registers the native/filesystem residue purge (MALI-054n/070n). See
  /// [_captureOwnerClear]. Wired by bootstrap to the capture bridge + pending
  /// actions file.
  void configureCaptureOwnerClear(Future<bool> Function()? atTransition,
      {Future<bool> Function()? atSignOut}) {
    _captureOwnerClear = atTransition;
    _captureOwnerClearAtSignOut = atSignOut;
  }

  void configureCaptureOwnerPublish(Future<void> Function(String uid)? publish) {
    _publishCaptureOwner = publish;
  }

  /// Runs the injected residue purge. Returns false (cannot confirm) when the
  /// hook is not yet registered or the purge throws/reports failure — callers
  /// at identity-admission boundaries MUST treat false as "residue may remain"
  /// and fail closed.
  Future<bool> _runOwnerClear({bool signOut = false}) async {
    final purge = signOut
        ? (_captureOwnerClearAtSignOut ?? _captureOwnerClear)
        : _captureOwnerClear;
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

  /// Writes [value] to the owner marker and reads it back. True ONLY when the
  /// read-back equals [value].
  ///
  /// Always writes — never gated on the prior read. On iOS the plugin's
  /// `delete` filters on kSecAttrAccessible while `read` does not, so an owner
  /// marker written by an older build survives `delete` silently and keeps
  /// reading back as the previous uid (proven on a real keychain). Its `write`
  /// path does repair such an item. The read-back is the only evidence that
  /// counts; a claim that is not verified must never be reported as success.
  Future<bool> _writeOwnerMarkerVerified(String value) async {
    try {
      await _storage.write(key: _kLocalDataOwnerUid, value: value);
    } on PlatformException catch (e) {
      if (e.code != '-25299') return false;
      // Keychain item already exists and overriding failed: delete and retry.
      try {
        await _storage.delete(key: _kLocalDataOwnerUid);
        await _storage.write(key: _kLocalDataOwnerUid, value: value);
      } catch (_) {
        return false;
      }
    } catch (_) {
      return false;
    }
    try {
      return await _storage.read(key: _kLocalDataOwnerUid) == value;
    } catch (_) {
      return false;
    }
  }

  /// Records [uid] as unresolved for this process and reports it.
  LocalDataOwnership _markOwnershipUnresolved(String uid) {
    _unresolvedOwnerUid = uid;
    return LocalDataOwnership.unresolved;
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

  /// Serialised entry point for every ownership reconcile. See
  /// [_ownershipTail] and [_resolveLocalDataOwnership].
  Future<LocalDataOwnership> _ensureLocalDataOwnedBy(String uid) {
    final run = _ownershipTail.then((_) => _resolveLocalDataOwnership(uid));
    _ownershipTail = run.then<void>((_) {}, onError: (Object _) {});
    return run;
  }

  /// Admits [uid] BEFORE the session is shown (MALI-002): the owner marker names
  /// [uid] (read back), and its own replica is the open database.
  ///
  /// WP-3b: there is no wipe. Each uid has its own encrypted replica, so a marker
  /// that names ANOTHER uid (the previous owner's session ended without a
  /// sign-out: expiry, revocation, crash) is not a conflict over rows. The
  /// previous owner's replica is simply locked and left untouched, and [uid]
  /// gets or creates its own. What still has to be cleared is device-wide native
  /// residue that is not stamped with an owner, and that is purged BEFORE the
  /// claim and fails closed (MALI-054n): an unconfirmed purge never admits.
  ///
  /// INVARIANT: if ownership is unresolved, preserve local data and deny
  /// access. Admission ([owned]) only after the new owner has been READ BACK from
  /// the marker. A database nobody provably owns is never adopted by whoever
  /// signs in next (B4): such a file is quarantined by the replica layer.
  ///
  /// If the purge hook is not registered (first reconcile runs before bootstrap
  /// registers it), nothing is attempted for a changed owner: the conflict is
  /// recorded and [LocalDataOwnership.deferred] returned until
  /// [resolvePendingLocalDataOwnerConflict] runs.
  Future<LocalDataOwnership> _resolveLocalDataOwnership(String uid) async {
    // A removal a crash interrupted finishes BEFORE anyone is admitted: its sweep
    // would otherwise delete this uid's fresh captures (created after the barrier).
    final removal = _removeData;
    if (removal != null && !await removal.resumePending()) {
      return _markOwnershipUnresolved(uid);
    }

    final String? existing;
    try {
      existing = await _storage.read(key: _kLocalDataOwnerUid);
    } catch (_) {
      return _markOwnershipUnresolved(uid);
    }

    if (existing == uid) {
      // The read itself proves the marker is consistent. No write needed.
      _pendingOwnerConflictUid = null;
      _unresolvedOwnerUid = null;
      // MALI-069n §Blocker-1: mint a fresh admission generation ONLY when none
      // exists (a genuine (re-)admission — sign-out/ownership-change cleared
      // it). An idempotent reconcile of the SAME live session keeps its
      // generation, so its own in-flight background jobs stay valid; a real
      // re-login always sees the generation absent and rotates, rejecting the
      // previous session's jobs — even for the same UID.
      await _mintOwnerGenerationIfAbsent();
      return _admitReplica(uid);
    }

    if (existing == null) {
      _pendingOwnerConflictUid = null;
      // Claiming a device nobody currently owns. Best-effort residue purge as
      // defense in depth (e.g. a prior reset whose purge failed): a genuinely
      // fresh install has nothing to purge, so this is a no-op and never blocks
      // first-run admission (the hook may not be registered this early).
      await _runOwnerClear();
      if (!await _writeOwnerMarkerVerified(uid)) {
        return _markOwnershipUnresolved(uid);
      }
      await _mintOwnerGenerationIfAbsent();
      _unresolvedOwnerUid = null;
      return _admitReplica(uid);
    }

    // ANOTHER uid (or a leftover transition sentinel from an older build).
    if (_unresolvedOwnerUid == uid) {
      // Already failed in this process; do not retry on every auth event.
      return LocalDataOwnership.unresolved;
    }
    if (_captureOwnerClear == null) {
      _pendingOwnerConflictUid = uid;
      return LocalDataOwnership.deferred;
    }
    // MALI-069n §Blocker-1: invalidate the admission generation BEFORE anything
    // changes, so a background job from the previous owner is rejected and the
    // incoming owner mints a fresh generation on claim below.
    await _invalidateOwnerGeneration();

    // Purge first. The purge calls a native method channel that, under the
    // UIScene lifecycle, does not exist during `didFinishLaunchingWithOptions`
    // (Dart bootstrap runs inside that window), so it can fail transiently. A
    // failure is a safe stop: the marker still names the previous owner, nothing
    // was changed, and the next attempt redoes it.
    final residuePurged = await _runOwnerClear();
    if (!residuePurged) {
      _pendingOwnerConflictUid = uid;
      return _markOwnershipUnresolved(uid);
    }

    if (!await _writeOwnerMarkerVerified(uid)) {
      _pendingOwnerConflictUid = uid;
      return _markOwnershipUnresolved(uid);
    }
    await _mintOwnerGenerationIfAbsent();
    _pendingOwnerConflictUid = null;
    _unresolvedOwnerUid = null;
    return _admitReplica(uid);
  }

  /// Unlocks and opens [uid]'s replica (locking the previously active uid's),
  /// once the scope layer exists. Before bootstrap has opened a database the
  /// marker is the whole admission and bootstrap opens the replica it names. A
  /// replica that cannot be opened is a safe stop (fail closed), never an
  /// adoption of someone else's file.
  Future<LocalDataOwnership> _admitReplica(String uid) async {
    final scope = _accountScope;
    if (scope == null) return LocalDataOwnership.owned;
    try {
      await scope.activate(uid);
    } catch (_) {
      return _markOwnershipUnresolved(uid);
    }
    try {
      await _publishCaptureOwner?.call(uid);
    } catch (_) {
      // Capture simply stays unbound until the next admission publishes it.
    }
    return LocalDataOwnership.owned;
  }

  /// Completes an owner conflict deferred by [_ensureLocalDataOwnedBy] once
  /// the purge hook exists (bootstrap calls this right after registering it,
  /// with the DB open). Purges the previous account's native residue, claims
  /// ownership for the pending UID and switches to its replica, then re-runs the
  /// session reconcile so the gated identity is finally admitted.
  Future<void> resolvePendingLocalDataOwnerConflict(
    supabase.SupabaseClient client,
  ) async {
    if (_pendingOwnerConflictUid == null) return;
    if (_captureOwnerClear == null) return;
    final uid = _pendingOwnerConflictUid!;
    final ownership = await _ensureLocalDataOwnedBy(uid);
    if (ownership == LocalDataOwnership.unresolved) {
      markSessionInvalid();
      return;
    }
    if (ownership != LocalDataOwnership.owned) return;
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
    final coachMarks = await _storage.read(key: _kCoachMarksSeen);
    _coachMarksSeen = (coachMarks ?? '')
        .split(',')
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
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

  /// Whether a given coach mark has already been shown on this device for the
  /// current account. Unknown ids read as unseen, so adding a mark shows it.
  bool hasSeenCoachMark(String id) => _coachMarksSeen.contains(id);

  /// Records a coach mark as shown. Idempotent.
  Future<void> markCoachMarkSeen(String id) async {
    if (_coachMarksSeen.contains(id)) return;
    _coachMarksSeen = {..._coachMarksSeen, id};
    await _storage.write(
      key: _kCoachMarksSeen,
      value: _coachMarksSeen.join(','),
    );
    notifyListeners();
  }

  /// Clears every coach mark so the guided tour can be replayed on demand —
  /// the Help screen offers this, because a user who has dismissed guidance
  /// once should not be locked out of it forever.
  Future<void> resetCoachMarks() async {
    if (_coachMarksSeen.isEmpty) return;
    _coachMarksSeen = <String>{};
    await _storage.delete(key: _kCoachMarksSeen);
    notifyListeners();
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
    // so the new uid's own replica is unlocked and opened inline here before the
    // new identity is stored — user B works in B's replica, never on top of user
    // A's rows, and A's replica is locked and untouched.
    if (userId != null && userId.isNotEmpty) {
      // Interactive sign-in is explicit user intent: allow one fresh attempt
      // even if an earlier automatic reconcile latched this uid unresolved.
      if (_unresolvedOwnerUid == userId) _unresolvedOwnerUid = null;
      final ownership = await _ensureLocalDataOwnedBy(userId);
      if (ownership == LocalDataOwnership.unresolved) {
        // Ownership could not be established (previous owner's residue not
        // cleared, the owner marker could not be verified, or the replica could
        // not be opened). Fail closed (MALI-054n): do NOT admit this identity.
        // Local data is preserved. The interactive sign-in caller catches this
        // and surfaces an error. (`deferred` — purge hook absent before
        // bootstrap registers it — continues as before: admission is deferred,
        // not blocked.)
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

  /// Signs the current identity out (WP-3b: LOCKS the replica, never wipes it).
  ///
  /// The uid's encrypted replica, its outboxes, cursors and consent stay on the
  /// device. Locking marks it `locked` and closes it, so it opens again only after
  /// the SAME uid authenticates successfully (SYNC-Q3: no offline reopen). A lock
  /// failure aborts the sign-out (rethrows, no identity state touched) rather than
  /// leaving the account's database open behind a signed-out UI. Safe to call
  /// repeatedly: an already-locked replica and an already-signed-out state are
  /// no-ops for every step below. "Remove data from this device" is a separate,
  /// explicit action ([removeDataFromDevice]).
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
    // close/purge begins, so an in-flight background job bound to this session is
    // rejected at its next validation boundary and can neither commit nor
    // acknowledge under the outgoing (or a subsequent) admission.
    await _invalidateOwnerGeneration();
    // Best-effort final push BEFORE the replica is closed: a change made in the
    // last seconds should reach the cloud now rather than wait for the next
    // sign-in. Offline sign-out still proceeds; nothing is discarded either way.
    await flushPendingForSignOut();
    // Lock + close the active replica and publish the signed-out scope.
    await _accountScope?.lock();
    await _finishSignedOut();
  }

  /// Everything after the replica is locked/removed: native residue purge, owner
  /// release, capture unlink and identity cleanup. Shared by [signOut] and
  /// [removeDataFromDevice].
  Future<void> _finishSignedOut() async {
    // MALI-054n/070n: release the native capture owner BEFORE releasing ownership. If the purge cannot be confirmed, KEEP the owner uid: the next
    // DIFFERENT user then hits the changed-owner path (_ensureLocalDataOwnedBy),
    // which re-purges and fails closed rather than admitting them onto un-purged
    // residue. (Same user re-login is unaffected: their own residue is not a
    // cross-user leak.)
    final residuePurged = await _runOwnerClear(signOut: true);
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
    _unresolvedOwnerUid = null;
    value = SessionStatus.needsOnboarding;
  }

  /// "Remove data from this device" for the signed-in uid (manifest §4.4):
  /// deletes that uid's replica, key and native residue, then signs out. Throws
  /// [RemoveDataIncompleteException] when a step could not be confirmed; the
  /// barrier is then kept and resumes at the next launch or admission, and the
  /// caller must not report completion.
  Future<void> removeDataFromDevice() async {
    final uid = await _storage.read(key: _kLocalDataOwnerUid);
    await _invalidateOwnerGeneration();
    if (uid != null && uid.isNotEmpty && !uid.startsWith(_kOwnerTransitionPrefix)) {
      final flow = _removeData;
      try {
        if (flow == null) throw const RemoveDataIncompleteException();
        await flow.remove(uid);
      } on RemoveDataIncompleteException {
        // The barrier is kept and resumes at the next launch/admission. Until
        // then the device must not sit signed in on a half-removed account:
        // lock whatever is still open and sign out locally, then report it.
        await _accountScope?.lock();
        await _finishSignedOut();
        rethrow;
      }
    }
    await _finishSignedOut();
  }

  /// Step 1 of the removal: the owner record is cleared (the native owner record
  /// is cleared by the barrier's `begin`).
  Future<void> clearLocalDataOwnerMarker() =>
      _storage.delete(key: _kLocalDataOwnerUid);

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
        _authLossSeq++;
        // A server-driven auth loss is not an explicit request to destroy the
        // local-first database. It can be emitted during cold-start token
        // recovery, resume, revocation, or account deletion. With the old call
        // to signOut() here, every such emission wiped every user-scoped Drift
        // table, including settings and the persisted notification journey
        // state. Keep the encrypted local data owned by this UID and withhold
        // access until the user re-authenticates. Explicit UI logout still
        // calls signOut() directly, which LOCKS the replica (never wipes it).
        markSessionInvalid();
        return;
      case supabase.AuthChangeEvent.initialSession:
      case supabase.AuthChangeEvent.signedIn:
      case supabase.AuthChangeEvent.tokenRefreshed:
      case supabase.AuthChangeEvent.userUpdated:
        await _reconcileSupabaseSession(state.session);
        // A-5: an admitted authenticated session re-arms auth-parked sync rows.
        if (value == SessionStatus.authenticated) AuthSessionValid.notify();
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
    final lossSeq = _authLossSeq;
    final ownership = await _ensureLocalDataOwnedBy(session.user.id);
    if (lossSeq != _authLossSeq) return; // the session was lost meanwhile
    if (ownership == LocalDataOwnership.deferred) return;
    if (ownership == LocalDataOwnership.unresolved) {
      // Fail closed: local data is preserved but must not be shown to an
      // identity whose ownership could not be verified. Route to sign-in.
      markSessionInvalid();
      return;
    }
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
    if (lossSeq != _authLossSeq) return;
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

  /// B15 — the ONE full-reset sequence (Settings "erase all data", Privacy
  /// account deletion). WP-3b: the database step is the §4.4 Remove-data flow
  /// ([removeDataFromDevice]: the admission generation is invalidated FIRST, then
  /// the uid's replica, key and native residue are deleted); then [wipeAndReset];
  /// and finally the remote auth sign-out ([signOutRemote], best effort — the
  /// local removal already protects the device if the network call fails). A
  /// removal that cannot be confirmed throws before anything else runs.
  Future<void> resetAllLocalData({
    Future<void> Function()? signOutRemote,
  }) async {
    await removeDataFromDevice();
    await wipeAndReset();
    if (signOutRemote != null) {
      try {
        await signOutRemote();
      } catch (_) {
        // Local reset above is authoritative.
      }
    }
  }

  /// حذف الحساب وكل البيانات المحلية (Privacy → حذف كل بياناتي).
  Future<void> wipeAndReset() async {
    // MALI-054n/070n: purge native + filesystem capture residue as part of the
    // full reset (account deletion / reset-all), BEFORE the secure-storage wipe
    // drops the owner marker — otherwise leftover native captures could be
    // imported by the next identity that null-claims the reset device.
    await _runOwnerClear();
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
    _unresolvedOwnerUid = null;
    value = SessionStatus.needsOnboarding;
    // In-memory state is signed-out first, so a reported failure still leaves
    // the app in a safe state — but the failure IS reported: a wipe that left
    // credentials or backup material behind must not look like success.
    if (!wipe.isComplete) {
      throw SecureStorageWipeIncompleteException(wipe.failed.length);
    }
  }
}
