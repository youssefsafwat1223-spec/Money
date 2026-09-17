import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// ANDROID NOTIFICATION CHANNELS — the one localization problem that cannot be
/// fixed by translating a string.
///
/// Android stores a channel's NAME when the channel is first created and keeps
/// it for the lifetime of the install. Passing a different name with the same
/// id is silently ignored. So a channel created in Arabic shows an Arabic name
/// in the system Settings list forever — including for a user running the app
/// in English — and the only way to change it is a different channel id, or
/// deleting the channel, which also discards every per-channel choice the user
/// made.
///
/// The shipped strategy: the existing ids keep their existing Arabic names and
/// ARE the Arabic channels; English gets `<id>_en`. Existing (Arabic) installs
/// are untouched — same ids, same names, every mute and importance preserved —
/// and English users get English channel names from their first notification.
///
/// This is a SOURCE test, deliberately. The claims are about identifiers and
/// about what the code does NOT do, and a widget test cannot see either: there
/// is no Android channel registry in a Dart unit test, and the failure mode
/// being guarded against ("someone passes a localized name with a stable id
/// and assumes Android will use it") is invisible at runtime on any platform
/// but Android. `V1_ANDROID_NOTIFICATION_CHANNELS.md` records the reasoning;
/// this keeps the code from drifting away from it.
void main() {
  final source =
      File('lib/features/capture/services/local_notification_service.dart')
          .readAsStringSync();

  const legacyIds = [
    'capture_review',
    'capture_light_v2',
    'qirsh_growth',
    'budget_alerts',
    'achievement_alerts',
    'weekly_reports',
    'daily_reminders',
    'bill_reminders',
    'goal_milestones',
  ];

  test('every channel id keeps its existing value — no silent renames', () {
    // An id changed here is an invisible migration: existing users get a NEW
    // channel at default importance and lose whatever they had configured.
    for (final id in legacyIds) {
      expect(source, contains("'$id'"),
          reason: '$id disappeared. Changing a channel id resets every '
              "user's settings for that channel — it needs a deliberate "
              'migration note, not an edit.');
    }
  });

  test('every channel goes through the language suffix', () {
    // The point of `_channel` is that there is exactly ONE place that decides
    // the id. A raw `_xChannelId` passed straight to AndroidNotificationDetails
    // would be an Arabic-named channel shown to an English user.
    expect(source, contains('String _channel(String base) =>'));

    final rawUses = RegExp(r'AndroidNotificationDetails\(\s*\n\s*(_\w+ChannelId)')
        .allMatches(source)
        .map((m) => m.group(1))
        .toList();
    expect(rawUses, isEmpty,
        reason: 'these channels bypass _channel() and would keep an Arabic '
            'name under `en`: ${rawUses.join(", ")}');

    // Every Android notification in the file must name a channel, and the only
    // way to name one is through the helper.
    final detailBlocks =
        RegExp(r'AndroidNotificationDetails\(').allMatches(source).length;
    final channelCalls = RegExp(r'_channel\(_\w+ChannelId\)').allMatches(source).length;
    expect(channelCalls, detailBlocks,
        reason: '$detailBlocks Android notifications but only $channelCalls '
            'went through _channel()');
  });

  test('the suffix is applied only for English, so Arabic ids are unchanged',
      () {
    expect(
      source,
      contains("notificationLanguage == 'en' ? '\${base}_en' : base"),
      reason: 'the Arabic branch must return the id verbatim; anything else '
          'migrates every existing install off its configured channels',
    );
  });

  test('action button labels follow the reader, not the channel', () {
    // Action labels are read from each POST, not from the channel, so unlike
    // the channel name they were always free to be localized.
    expect(source, contains("notificationLanguage == 'en' ? 'Confirm ✓' : 'تأكيد ✓'"));
    expect(source, contains("notificationLanguage == 'en' ? 'Dismiss' : 'تجاهل'"));
  });

  test('no channel is deleted to force a rename', () {
    // deleteNotificationChannel() would let the name change in place, and it
    // is the wrong trade: it also clears importance, sound and whether the
    // user muted the channel. If this ever appears, it needs to be a stated
    // product decision, not a localization shortcut.
    expect(source, isNot(contains('deleteNotificationChannel')));
  });

  test('every channel carries a description in both languages', () {
    // A localized NAME beside an Arabic DESCRIPTION is the half-migration this
    // guards against — the Settings list would read English with Arabic
    // subtitles.
    final arabicOnlyDescriptions = RegExp(
            r"channelDescription: '[^']*[؀-ۿ][^']*'")
        .allMatches(source)
        .map((m) => m.group(0))
        .toList();
    expect(arabicOnlyDescriptions, isEmpty,
        reason: 'these descriptions are Arabic in every language: '
            '${arabicOnlyDescriptions.join(" | ")}');
  });
}
