import 'package:flutter_test/flutter_test.dart';
import 'package:money_companion/engine/parser/bank_institution_matcher.dart';
import 'package:money_companion/engine/parser/bank_profile.dart';

BankProfile _p(String key, String name, String country, List<String> kw) =>
    BankProfile(
      bankKey: key,
      displayName: name,
      keywords: kw,
      country: country,
    );

void main() {
  final alpha = _p('alpha_eg', 'Alpha Bank', 'EG', ['alphabank', 'ألفا']);
  final alphaSa = _p('alpha_sa', 'Alpha Bank', 'SA', ['alphabank']);
  final beta = _p('beta_eg', 'Beta Bank', 'EG', ['betabank']);
  final profiles = [alpha, alphaSa, beta];

  BankProfile? run(String name, {String? key, String? country}) =>
      BankInstitutionMatcher.match(
        bankKeySuggestion: key,
        suggestedBankName: name,
        country: country,
        availableProfiles: profiles,
      );

  test('exact bank key wins', () {
    expect(run('whatever', key: 'beta_eg', country: 'SA')?.bankKey, 'beta_eg');
  });

  test('name and country give a unique match', () {
    expect(run('The Alpha Bank S.A.E', key: 'x', country: 'EG')?.bankKey,
        'alpha_eg');
    expect(run('Alpha Bank', country: 'SA')?.bankKey, 'alpha_sa');
  });

  test('keyword contained in a longer suggested name matches', () {
    expect(run('BetaBank Egypt', country: 'EG')?.bankKey, 'beta_eg');
  });

  test('ambiguous match returns null', () {
    expect(run('Alpha Bank & Beta Bank', country: 'EG'), isNull);
    expect(run('Alpha Bank'), isNull); // both countries qualify
  });

  test('unknown bank returns null', () {
    expect(run('Gamma Trust', key: 'gamma', country: 'EG'), isNull);
  });

  test('country mismatch returns null', () {
    expect(run('Beta Bank', country: 'SA'), isNull);
  });

  test('short tokens (< 3 chars) never match', () {
    final tiny = _p('tiny', 'AB', 'EG', ['ab']);
    expect(
      BankInstitutionMatcher.match(
        suggestedBankName: 'AB Trading Egypt',
        country: 'EG',
        availableProfiles: [tiny],
      ),
      isNull,
    );
  });

  test('realistic: an Egypt-suffixed name maps to the existing EG profile', () {
    final match = BankInstitutionMatcher.match(
      bankKeySuggestion: 'qnb_eg',
      suggestedBankName: 'QNB Egypt',
      country: 'EG',
    );
    expect(match, isNotNull);
    expect(match!.country, 'EG');
    expect(match.bankKey, 'qnb_alahli');
  });
}
