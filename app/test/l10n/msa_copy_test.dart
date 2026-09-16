import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// User-facing Arabic must be Modern Standard Arabic.
///
/// The app shipped a mix: MSA in most places, Egyptian colloquial in others,
/// and occasionally BOTH IN THE SAME SENTENCE — `storySpendingSupporting` read
/// "قِرش يساعدك تشوف الصورة كاملة، وتفهم أين تذهب أموالك", pairing colloquial
/// تشوف with MSA أين. That inconsistency is the clearest evidence the
/// colloquial was unintentional rather than a voice.
///
/// 81 literals were converted across 23 files on 2026-09-16. This keeps them
/// converted.
///
/// ## Word boundaries are load-bearing
///
/// A plain `contains` check reports `يلا` inside `التحويلات`, `وين` inside
/// `عناوين`, and `كده` inside `تؤكده` — eleven false positives on the first
/// run, all of them correct Modern Standard Arabic. `\b` is defined over
/// [A-Za-z0-9_] and does not see Arabic at all, so the boundary has to be
/// written explicitly as "not preceded/followed by an Arabic letter". This is
/// the same mistake the egress-inventory guard made in a different alphabet:
/// a pattern that does not say what its author meant.
///
/// ## Deliberately exempt: brand voice
///
/// Two taglines keep their conversational register, because a tagline is a
/// brand decision and not a correctness defect. They are listed by key so the
/// exemption is explicit and reviewable rather than a gap in the pattern list.
/// The marker as a standalone word: not glued to another Arabic letter on
/// either side. Without this, `يلا` matches inside `التحويلات`.
RegExp _standalone(String marker) =>
    RegExp('(?<![\u0600-\u06FF])${RegExp.escape(marker)}(?![\u0600-\u06FF])');

void main() {
  /// Forms that do not occur in Modern Standard Arabic.
  const colloquial = <String, String>{
    'مفيش': 'لا يوجد / لا توجد',
    'كده': 'هكذا',
    'إزاي': 'كيف',
    'ازاي': 'كيف',
    'عشان': 'لأن / لكي',
    'علشان': 'لأن / لكي',
    'دلوقتي': 'الآن',
    'لسه': 'ما زال',
    'يلا': 'هيا',
    'بردو': 'أيضًا',
    'برضو': 'أيضًا',
    'عايز': 'تريد',
    'عاوز': 'تريد',
    'شوف': 'انظر / اطّلع',
    'وين': 'أين',
    'اللي فات': 'الماضي',
    'هتتشال': 'ستُزال',
    'هيتشال': 'سيُزال',
    'اتشال': 'أُزيل',
    'معملتش': 'لم تفعل',
    'مابيقراش': 'لا يقرأ',
  };

  /// ARB keys whose conversational register is intentional brand voice.
  const brandVoiceKeys = <String>{
    'brandTagline',    // فلوسك أوضح. قرارك أذكى.
    'welcomeSubtitle', // صاحبك في فلوسك
  };

  test('the Arabic ARB carries no colloquial forms outside brand voice', () {
    final arb = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
        as Map<String, dynamic>;
    final offenders = <String>[];
    arb.forEach((key, value) {
      if (key.startsWith('@') || value is! String) return;
      if (brandVoiceKeys.contains(key)) return;
      for (final entry in colloquial.entries) {
        if (_standalone(entry.key).hasMatch(value)) {
          offenders.add('$key: "${entry.key}" -> use ${entry.value}');
        }
      }
    });
    expect(offenders, isEmpty,
        reason: 'colloquial Arabic in user-facing strings:\n'
            '  ${offenders.join('\n  ')}');
  });

  test('brand-voice exemptions still exist and are still taglines', () {
    // If a key is deleted or repurposed, the exemption must be revisited
    // rather than silently covering something else.
    final arb = jsonDecode(File('lib/l10n/app_ar.arb').readAsStringSync())
        as Map<String, dynamic>;
    for (final key in brandVoiceKeys) {
      expect(arb.containsKey(key), isTrue,
          reason: '$key is exempted from the MSA rule but no longer exists');
      expect((arb[key] as String).length, lessThan(60),
          reason: '$key is exempted as a TAGLINE; if it has grown into body '
              'copy the exemption no longer applies');
    }
  });

  test('no colloquial in hardcoded user-facing Dart copy', () {
    final literal = RegExp(r"'([^']{2,220})'");
    final arabic = RegExp(r'[؀-ۿ]');
    final offenders = <String>[];

    void walk(Directory dir) {
      for (final e in dir.listSync()) {
        if (e is Directory) {
          walk(e);
        } else if (e is File && e.path.endsWith('.dart')) {
          // Generated localisations mirror the ARB, which is asserted above.
          if (e.path.contains('/l10n/')) continue;
          var line = 0;
          for (final text in e.readAsLinesSync()) {
            line++;
            for (final m in literal.allMatches(text)) {
              final s = m.group(1)!;
              if (!arabic.hasMatch(s)) continue;
              for (final entry in colloquial.entries) {
                if (_standalone(entry.key).hasMatch(s)) {
                  offenders.add('${e.path}:$line "${entry.key}" '
                      '-> use ${entry.value}');
                }
              }
            }
          }
        }
      }
    }

    walk(Directory('lib'));
    expect(offenders, isEmpty,
        reason: 'colloquial Arabic in hardcoded copy:\n'
            '  ${offenders.join('\n  ')}');
  });
}
