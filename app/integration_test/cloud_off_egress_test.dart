import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:integration_test/integration_test.dart';
import 'package:money_companion/core/di/app_providers.dart';
import 'package:money_companion/core/session/app_session.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/app/app_shell.dart';
import 'package:money_companion/main.dart' as app;
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// CLOUD-OFF EGRESS — the gate that was only ever code-read.
///
/// `QA_SECURITY_MATRIX.md` and the release readiness sheet both recorded
/// cloud-OFF enforcement as UNVERIFIED, because every piece of evidence for it
/// was a source scan: `egress_inventory_test.dart` proves each network file is
/// a listed decision, and the unit tests prove the gates that exist work.
/// Neither can see a request that actually leaves.
///
/// This installs an `HttpOverrides` before `app.main()` runs, so every
/// `HttpClient` the process creates — including the ones inside `package:http`
/// and the Supabase SDK — is ours and records its URIs. Then it drives the app
/// with cloud processing and AI consent OFF and asserts what the transcript
/// contains.
///
/// Not wire-level: a proxy watching the socket would also catch a plugin doing
/// its own native networking. This catches everything that goes through Dart,
/// which is every service `egress_inventory_test.dart` lists.
///
/// AUTH IS ALLOWED, and that is not a loophole. Signing in is what makes a
/// session exist at all, the user asked for it, and it carries no financial or
/// message content. What must not appear is `/rest/v1/` (PostgREST — the
/// ledger) or `/functions/v1/` (the capture and AI endpoints).
const _qaEmail = String.fromEnvironment('QA_EMAIL');
const _qaPassword = String.fromEnvironment('QA_PASSWORD');
const _qaUserId = String.fromEnvironment('QA_USER_ID');

/// Every URI the process requested, in order.
final _transcript = <String>[];

class _RecordingHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    return _RecordingHttpClient(client);
  }
}

/// Records and delegates. It does NOT block: a test that prevents the request
/// proves only that the test blocked it. The app must choose not to make it.
///
/// Every member is forwarded explicitly rather than through `noSuchMethod`.
/// `package:http`'s `IOClient` sets `connectionTimeout`, `userAgent`,
/// `autoUncompress` and `badCertificateCallback` on the client it is handed,
/// and a `noSuchMethod` wrapper that only maps the verbs would throw on the
/// first of those — breaking the app under test and proving nothing.
class _RecordingHttpClient implements HttpClient {
  _RecordingHttpClient(this._inner);
  final HttpClient _inner;

  void _record(String method, Uri url) {
    _transcript.add('$method ${url.scheme}://${url.host}${url.path}');
  }

  @override
  Future<HttpClientRequest> open(
      String method, String host, int port, String path) {
    _record(method, Uri(scheme: 'https', host: host, port: port, path: path));
    return _inner.open(method, host, port, path);
  }

  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    _record(method, url);
    return _inner.openUrl(method, url);
  }

  @override
  Future<HttpClientRequest> get(String host, int port, String path) =>
      open('GET', host, port, path);
  @override
  Future<HttpClientRequest> getUrl(Uri url) => openUrl('GET', url);
  @override
  Future<HttpClientRequest> post(String host, int port, String path) =>
      open('POST', host, port, path);
  @override
  Future<HttpClientRequest> postUrl(Uri url) => openUrl('POST', url);
  @override
  Future<HttpClientRequest> put(String host, int port, String path) =>
      open('PUT', host, port, path);
  @override
  Future<HttpClientRequest> putUrl(Uri url) => openUrl('PUT', url);
  @override
  Future<HttpClientRequest> delete(String host, int port, String path) =>
      open('DELETE', host, port, path);
  @override
  Future<HttpClientRequest> deleteUrl(Uri url) => openUrl('DELETE', url);
  @override
  Future<HttpClientRequest> patch(String host, int port, String path) =>
      open('PATCH', host, port, path);
  @override
  Future<HttpClientRequest> patchUrl(Uri url) => openUrl('PATCH', url);
  @override
  Future<HttpClientRequest> head(String host, int port, String path) =>
      open('HEAD', host, port, path);
  @override
  Future<HttpClientRequest> headUrl(Uri url) => openUrl('HEAD', url);

  @override
  Duration get idleTimeout => _inner.idleTimeout;
  @override
  set idleTimeout(Duration value) => _inner.idleTimeout = value;
  @override
  Duration? get connectionTimeout => _inner.connectionTimeout;
  @override
  set connectionTimeout(Duration? value) => _inner.connectionTimeout = value;
  @override
  int? get maxConnectionsPerHost => _inner.maxConnectionsPerHost;
  @override
  set maxConnectionsPerHost(int? value) => _inner.maxConnectionsPerHost = value;
  @override
  bool get autoUncompress => _inner.autoUncompress;
  @override
  set autoUncompress(bool value) => _inner.autoUncompress = value;
  @override
  String? get userAgent => _inner.userAgent;
  @override
  set userAgent(String? value) => _inner.userAgent = value;

  @override
  set authenticate(
          Future<bool> Function(Uri url, String scheme, String? realm)? f) =>
      _inner.authenticate = f;
  @override
  set authenticateProxy(
          Future<bool> Function(
                  String host, int port, String scheme, String? realm)?
              f) =>
      _inner.authenticateProxy = f;
  @override
  set badCertificateCallback(
          bool Function(X509Certificate cert, String host, int port)?
              callback) =>
      _inner.badCertificateCallback = callback;
  @override
  set findProxy(String Function(Uri url)? f) => _inner.findProxy = f;
  @override
  set connectionFactory(
          Future<ConnectionTask<Socket>> Function(
                  Uri url, String? proxyHost, int? proxyPort)?
              f) =>
      _inner.connectionFactory = f;
  @override
  set keyLog(Function(String line)? callback) => _inner.keyLog = callback;

  @override
  void addCredentials(Uri url, String realm, HttpClientCredentials creds) =>
      _inner.addCredentials(url, realm, creds);
  @override
  void addProxyCredentials(
          String host, int port, String realm, HttpClientCredentials creds) =>
      _inner.addProxyCredentials(host, port, realm, creds);
  @override
  void close({bool force = false}) => _inner.close(force: force);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<void> settle(WidgetTester tester,
      {Duration budget = const Duration(seconds: 25)}) async {
    final deadline = DateTime.now().add(budget);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (!tester.binding.hasScheduledFrame) break;
    }
  }

  /// Pumps for the FULL duration. `settle` exits as soon as the frame queue is
  /// empty, which says nothing about in-flight network work.
  Future<void> quiesce(WidgetTester tester, Duration duration) async {
    final deadline = DateTime.now().add(duration);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<bool> waitFor(WidgetTester tester, Finder f,
      {Duration timeout = const Duration(seconds: 90)}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      if (f.evaluate().isNotEmpty) return true;
    }
    return false;
  }

  testWidgets('cloud OFF: nothing financial leaves the device', (tester) async {
    if (_qaEmail.isEmpty || _qaPassword.isEmpty || _qaUserId.isEmpty) {
      fail('QA_EMAIL/QA_PASSWORD/QA_USER_ID are required');
    }
    HttpOverrides.global = _RecordingHttpOverrides();
    addTearDown(() => HttpOverrides.global = null);

    final previousFatal = WidgetController.hitTestWarningShouldBeFatal;
    WidgetController.hitTestWarningShouldBeFatal = false;
    addTearDown(
        () => WidgetController.hitTestWarningShouldBeFatal = previousFatal);

    app.main();
    await settle(tester, budget: const Duration(seconds: 60));

    final client = supabase.Supabase.instance.client;
    final owner = await AppSession.instance.readLocalDataOwnerUid();
    if (owner != null && owner != _qaUserId) {
      fail('ABORT — the local database belongs to another account.');
    }
    final res = await client.auth
        .signInWithPassword(email: _qaEmail, password: _qaPassword);
    await AppSession.instance
        .setIdentity(method: 'email', email: _qaEmail, userId: res.user!.id);
    await AppSession.instance.reconcileAccountOnboarding(client);
    await AppSession.instance.markWelcomeManifestoSeen();
    await settle(tester, budget: const Duration(seconds: 60));
    if (!AppSession.instance.hasCompletedOnboarding) {
      await AppSession.instance.finishOnboarding();
      await settle(tester, budget: const Duration(seconds: 45));
    }
    expect(await waitFor(tester, find.byType(AppShell)), isTrue,
        reason: 'shell never mounted');

    final container =
        ProviderScope.containerOf(tester.element(find.byType(AppShell)));

    // Turn cloud and AI OFF through the repository the app itself reads.
    final settingsRepo = container.read(userSettingsRepositoryProvider);
    final current = await settingsRepo.getSettings();
    // `cloudProcessingEnabled` / `aiConsentGranted` are derived getters; the
    // stored form is the consent STATE, and `declined` is the explicit refusal
    // rather than `unset`, which only means "not asked yet".
    await settingsRepo.saveSettings(current.copyWith(
      cloudConsentState: ConsentState.declined,
      aiConsentState: ConsentState.declined,
    ));
    expect(
      (await settingsRepo.getSettings()).cloudProcessingEnabled,
      isFalse,
      reason: 'the write did not take, so the rest of this run is meaningless',
    );
    // Long enough for the revocation itself to finish propagating. Writing the
    // setting enqueues an outbox row, and draining it POSTs the settings record
    // — which is how the server learns consent is off. That one write is the
    // revocation, not a leak, and measuring across it would confuse the two.
    // What must not happen is settings traffic AFTER it has drained.
    // NOT `settle` — that breaks the moment no frame is scheduled, and an
    // outbox drain is network work that schedules no frames, so a "60 second"
    // settle returned in milliseconds and measured across the revocation it was
    // meant to wait out. This pumps for the full duration regardless.
    await quiesce(tester, const Duration(seconds: 45));

    // Everything recorded up to here is setup: the sign-in that had to happen
    // for a session to exist, and the revocation propagating. The assertion is
    // about what follows.
    final setupCount = _transcript.length;

    // Drive the surfaces that would sync if anything still did.
    final router = GoRouter.of(tester.element(find.byType(AppShell)));
    for (final route in const [
      '/',
      '/transactions',
      '/reports',
      '/accounts',
      '/budgets',
      '/goals',
      '/cards',
      '/subscriptions',
      '/settings',
    ]) {
      router.go(route);
      await settle(tester);
    }
    // Give any debounced or scheduled sync a real chance to fire — again a
    // full pump, not a settle.
    await quiesce(tester, const Duration(seconds: 45));

    final after = _transcript.sublist(setupCount);
    // A DENYLIST of user-data paths, not a blanket `/rest/v1/` prefix. The
    // first version of this test used the prefix and was wrong: `ConsentAuthority`
    // deliberately permits `EgressClass.catalog` and `auth` with cloud off, and
    // catalog sync delivers parser rules, feature flags and the force-update
    // kill switch over `/rest/v1/` — gating it would disable safety controls for
    // the most privacy-conscious users. Naming the tables the policy protects is
    // the only way this test can tell a leak from a permitted call.
    const userDataPaths = <String>[
      '/rest/v1/user_transactions',
      '/rest/v1/user_accounts',
      '/rest/v1/user_budgets',
      '/rest/v1/user_goals',
      '/rest/v1/user_cards',
      '/rest/v1/user_subscriptions',
      '/rest/v1/user_settings',
      '/rest/v1/user_achievements',
      '/rest/v1/user_streaks',
      '/rest/v1/user_xp_levels',
      '/rest/v1/profiles',
      '/rest/v1/sender_bank_mappings',
      '/rest/v1/processed_captures',
      '/functions/v1/',
    ];
    final financial = after
        .where((line) => userDataPaths.any(line.contains))
        .toList();

    // Printed BEFORE the assertion, always. The framework truncates a failure
    // message, and the transcript is the entire value of this test — a run that
    // fails without showing what it saw costs another twenty-minute cycle.
    debugPrint('[CLOUD-OFF] setup=$setupCount post-setup=${after.length}');
    for (final line in after) {
      debugPrint('[CLOUD-OFF] $line');
    }

    expect(
      financial,
      isEmpty,
      reason: 'cloud processing and AI consent are OFF, so nothing carrying '
          'user data may be transmitted. These were:\n'
          '${financial.join("\n")}\n\nfull post-setup transcript '
          '(${after.length} requests):\n${after.join("\n")}',
    );
    // A transcript that recorded nothing at all would pass the assertion above
    // without proving the recorder works.
    expect(_transcript, isNotEmpty,
        reason: 'the recorder captured no request whatsoever — it is not '
            'installed, and this run proves nothing');
  }, timeout: const Timeout(Duration(minutes: 20)));
}
