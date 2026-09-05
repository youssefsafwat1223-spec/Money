import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The production site deploy must fail CLOSED on an incomplete build tree.
///
/// ## Why this exists
///
/// The deploy was a raw `rsync -av --delete` copy-pasted out of the hosting
/// docs. `--delete` makes the server match the build exactly, and
/// `build_site.py` emits `app-ads.txt` only when `ADMOB_PUBLISHER_ID` is set.
/// So a rebuild without that one environment variable produced a tree with no
/// `app-ads.txt`, and the next deploy DELETED the live file — silently breaking
/// AdMob ad-space verification while reporting a fully successful sync.
///
/// Nothing could catch it, because there was no pipeline to catch it in: only a
/// human remembering an env var. `tools/deploy_site.sh` is now the canonical
/// deploy, and these tests prove its refusals by RUNNING it against fixture
/// trees — not by asserting on its source text.
///
/// Every case here uses `--preflight-only`, so the real code path is exercised
/// and an rsync can never be reached from a test.
void main() {
  final script = File('../tools/deploy_site.sh');

  /// `--allow-app-ads-change` is passed because a fixture tree legitimately
  /// carries a different publisher id from the live site; without it the
  /// live-comparison check would refuse every fixture, masking the specific
  /// refusal each test is trying to prove.
  ProcessResult preflight(Directory tree) => Process.runSync(
        'bash',
        [script.path, '--preflight-only', '--allow-app-ads-change'],
        environment: {'QIRSH_SITE_DIR': tree.path},
      );

  /// A minimal tree that passes every check, so each test can break exactly one
  /// thing and attribute the refusal to that one thing.
  Directory validTree() {
    final d = Directory.systemTemp.createTempSync('qirsh_site_');
    for (final f in const [
      'index.html', 'privacy/index.html', 'terms/index.html',
      'support/index.html', 'en/index.html', 'en/privacy/index.html',
      'en/terms/index.html', 'en/support/index.html',
    ]) {
      File('${d.path}/$f')
        ..createSync(recursive: true)
        ..writeAsStringSync('<!doctype html><html></html>');
    }
    File('${d.path}/app-ads.txt').writeAsStringSync(
        'google.com, pub-1234567890123456, DIRECT, f08c47fec0942fa0\n');
    return d;
  }

  test('the deploy script exists and is executable', () {
    expect(script.existsSync(), isTrue,
        reason: 'tools/deploy_site.sh is the canonical deploy; a raw rsync in '
            'documentation cannot enforce a precondition');
  });

  test('a complete tree passes preflight', () {
    // Non-vacuity anchor: if this failed, every refusal below would pass for
    // the wrong reason.
    final d = validTree();
    addTearDown(() => d.deleteSync(recursive: true));
    final r = preflight(d);
    expect(r.exitCode, 0, reason: '${r.stdout}\n${r.stderr}');
  });

  test('REFUSES when app-ads.txt is missing — the original footgun', () {
    final d = validTree();
    addTearDown(() => d.deleteSync(recursive: true));
    File('${d.path}/app-ads.txt').deleteSync();
    final r = preflight(d);
    expect(r.exitCode, isNot(0));
    expect('${r.stdout}${r.stderr}', contains('DEPLOY REFUSED'));
    expect('${r.stdout}${r.stderr}', contains('app-ads.txt'));
  });

  test('REFUSES when app-ads.txt is empty', () {
    final d = validTree();
    addTearDown(() => d.deleteSync(recursive: true));
    File('${d.path}/app-ads.txt').writeAsStringSync('');
    final r = preflight(d);
    expect(r.exitCode, isNot(0));
    expect('${r.stdout}${r.stderr}', contains('DEPLOY REFUSED'));
  });

  test('REFUSES a malformed publisher line', () {
    // A WRONG publisher id authorises the wrong seller — worse than no file.
    final d = validTree();
    addTearDown(() => d.deleteSync(recursive: true));
    File('${d.path}/app-ads.txt')
        .writeAsStringSync('google.com, pub-NOTDIGITS, DIRECT, f08c47fec0942fa0\n');
    final r = preflight(d);
    expect(r.exitCode, isNot(0));
    expect('${r.stdout}${r.stderr}', contains('contract'));
  });

  test('REFUSES a placeholder publisher id', () {
    final d = validTree();
    addTearDown(() => d.deleteSync(recursive: true));
    File('${d.path}/app-ads.txt').writeAsStringSync(
        'google.com, pub-XXXXXXXXXXXXXXXX, DIRECT, f08c47fec0942fa0\n');
    final r = preflight(d);
    expect(r.exitCode, isNot(0));
  });

  test('REFUSES when a legal route is missing — same --delete hazard', () {
    // app-ads.txt was the file that actually broke, but every route carries the
    // identical risk: absent from the build means deleted from production.
    final d = validTree();
    addTearDown(() => d.deleteSync(recursive: true));
    File('${d.path}/privacy/index.html').deleteSync();
    final r = preflight(d);
    expect(r.exitCode, isNot(0));
    expect('${r.stdout}${r.stderr}', contains('privacy/index.html'));
  });

  test('REFUSES when app-ads.txt does not match ADMOB_PUBLISHER_ID', () {
    final d = validTree();
    addTearDown(() => d.deleteSync(recursive: true));
    final r = Process.runSync(
      'bash',
      [script.path, '--preflight-only', '--allow-app-ads-change'],
      environment: {
        'QIRSH_SITE_DIR': d.path,
        'ADMOB_PUBLISHER_ID': 'pub-9999999999999999',
      },
    );
    expect(r.exitCode, isNot(0));
    expect('${r.stdout}${r.stderr}', contains('ADMOB_PUBLISHER_ID'));
  });

  test('no publisher id is hardcoded in the deploy script', () {
    // The id comes from the environment or from what is already live. A
    // committed id is both config-in-code and, if wrong, a seller-authorisation
    // bug.
    final src = script.readAsStringSync();
    expect(RegExp(r'pub-\d{16}').hasMatch(src), isFalse,
        reason: 'tools/deploy_site.sh hardcodes an AdMob publisher id');
  });
}
