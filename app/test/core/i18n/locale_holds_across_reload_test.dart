import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/core/i18n/locale_provider.dart';
import 'package:money_companion/domain/entities/supporting_entities.dart';
import 'package:money_companion/features/settings/settings_providers.dart';

/// `localeProvider` resolved with `maybeWhen(..., orElse: () => Locale('ar'))`.
/// `orElse` fires on every `AsyncLoading` frame, and `userSettingsProvider`
/// watches `dbRevisionProvider` — so it reloads after **every database write**.
/// An English reader's whole app therefore dropped to Arabic for the duration
/// of each reload.
///
/// It was found by looking at a screenshot: the restore overlay, captured on an
/// English device, read «جارٍ تجهيز التطبيق...». The ARB entry was correct, the
/// generated English class was correct, and the widget called `context.l10n`
/// properly. Only the rendered pixels disagreed, because the locale the whole
/// tree was resolving against had flipped underneath them.
UserSettingsEntity _settings(String language) => UserSettingsEntity(
      id: 'settings',
      country: 'SA',
      currency: 'SAR',
      language: language,
      theme: 'light',
      inputMethod: 'manual',
      notificationsJson: '{}',
      privacyModeEnabled: false,
    );

void main() {
  test('a settings reload does not change the language', () async {
    // A Completer, not `invalidate` alone: the provider has to be observably
    // stuck in AsyncLoading at the moment `localeProvider` is read, or the
    // assertion passes for the wrong reason. The first version of this test
    // did exactly that — it passed against the OLD provider too, which made it
    // worthless as a guard.
    var completer = Completer<UserSettingsEntity>();
    final container = ProviderContainer(overrides: [
      userSettingsProvider.overrideWith((ref) => completer.future),
    ]);
    addTearDown(container.dispose);
    // Listened to, so it actually recomputes when its dependency changes
    // instead of handing back a cached answer.
    final seen = <Locale>[];
    container.listen<Locale>(localeProvider, (_, next) => seen.add(next),
        fireImmediately: true);

    completer.complete(_settings('en'));
    await container.read(userSettingsProvider.future);
    expect(container.read(localeProvider), const Locale('en'));
    // The very first frame, before anything has loaded, is legitimately Arabic
    // — that is the app's deliberate default and the second test pins it. What
    // must not happen is a RETURN to Arabic once English is known.
    seen.clear();

    // A database write bumps dbRevision, which re-runs this future. Hold it
    // open so the reload is genuinely in flight.
    completer = Completer<UserSettingsEntity>();
    container.invalidate(userSettingsProvider);
    expect(container.read(userSettingsProvider).isLoading, isTrue,
        reason: 'the reload must actually be in flight for this to prove '
            'anything');

    expect(container.read(localeProvider), const Locale('en'),
        reason: 'the app flipped to Arabic mid-reload for every English user, '
            'on every database write');
    expect(seen, isNot(contains(const Locale('ar'))),
        reason: 'not one frame of Arabic may reach an English reader: '
            'observed $seen');

    completer.complete(_settings('en'));
    await container.read(userSettingsProvider.future);
    expect(container.read(localeProvider), const Locale('en'));
  });

  test('a settings ERROR does not change the language', () async {
    // This is the case the old `maybeWhen(orElse:)` actually got wrong, and it
    // is why the first version of this file was worthless: `maybeWhen` already
    // defaults `skipLoadingOnRefresh` to true, so a plain reload kept English
    // on its own. An ERROR did not — `orElse` caught it and answered Arabic.
    // A failed settings read is not rare on a device: it is what a locked
    // keychain, a busy database or a transient decrypt failure looks like.
    var fail = false;
    final container = ProviderContainer(overrides: [
      userSettingsProvider.overrideWith((ref) async {
        if (fail) throw StateError('settings unavailable');
        return _settings('en');
      }),
    ]);
    addTearDown(container.dispose);
    container.listen<Locale>(localeProvider, (_, __) {}, fireImmediately: true);

    await container.read(userSettingsProvider.future);
    expect(container.read(localeProvider), const Locale('en'));

    fail = true;
    container.invalidate(userSettingsProvider);
    await expectLater(
        container.read(userSettingsProvider.future), throwsStateError);
    expect(container.read(userSettingsProvider).hasError, isTrue);

    expect(container.read(localeProvider), const Locale('en'),
        reason: 'a failed settings read must not silently switch an English '
            "reader's entire app into Arabic");
  });

  test('Arabic is still the answer before anything is saved', () async {
    // The fallback itself is deliberate and must survive: this is an
    // Arabic-first app, and a first read with no stored preference is the one
    // case where there is genuinely no previous answer to hold.
    final completer = Completer<UserSettingsEntity>();
    final container = ProviderContainer(overrides: [
      userSettingsProvider.overrideWith((ref) => completer.future),
    ]);
    addTearDown(container.dispose);

    expect(container.read(localeProvider), const Locale('ar'),
        reason: 'first frame, nothing loaded yet');
    completer.complete(_settings('ar'));
    await container.read(userSettingsProvider.future);
    expect(container.read(localeProvider), const Locale('ar'));
  });
}
