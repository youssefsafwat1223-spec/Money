import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/di/app_providers.dart';
import '../../data/catalog/catalog_daos.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/utils/l10n_ext.dart';

import '../common/app_button.dart';
import 'onboarding_options.dart';
import 'widgets/neon_illustration.dart';
import 'widgets/premium_ui.dart';

TextStyle _alex(double size, FontWeight weight, double height, Color color,
    {bool tabular = false, List<Shadow>? shadows}) {
  return GoogleFonts.inter(
    fontSize: size,
    fontWeight: weight,
    height: height,
    color: color,
    shadows: shadows,
    fontFeatures: tabular ? const [FontFeature.tabularFigures()] : null,
  ).copyWith(
    fontFamilyFallback: [
      GoogleFonts.ibmPlexSansArabic().fontFamily!,
      GoogleFonts.alexandria().fontFamily!,
    ],
  );
}

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key});

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _pageController = PageController();
  int _currentIndex = 0;
  static const int _pageCount = 2;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _next() async {
    if (_currentIndex < _pageCount - 1) {
      _pageController.nextPage(
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    } else {
      // Last page (Country) — persist selection then go to auth.
      final country = ref.read(onboardingSelectionProvider);
      if (country == null) return;
      try {
        await ref
            .read(saveCountryCurrencyUseCaseProvider)
            .call(country.code, country.currencyCode);
      } catch (_) {
        // Non-blocking — settings have a sensible default.
      }
      if (mounted) context.go('/onboarding/auth');
    }
  }

  @override
  Widget build(BuildContext context) {
    return PremiumBackground(
      child: Column(
        children: [
          _TopFrame(index: _currentIndex),
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const BouncingScrollPhysics(),
              onPageChanged: (i) => setState(() => _currentIndex = i),
              children: const [
                _WelcomePage(),
                _CountryPage(),
              ],
            ),
          ),
          _BottomBar(
            index: _currentIndex,
            count: _pageCount,
            onNext: _next,
          ),
        ],
      ),
    );
  }
}

class _TopFrame extends StatelessWidget {
  const _TopFrame({required this.index});
  final int index;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Welcome / How / Country map to steps 3 / 4 / 5 of the 16-step flow.
    final fraction = ((3 + index) / 16).clamp(0.0, 1.0);
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.gutter, vertical: AppSpacing.s3),
      child: Row(
        children: [
          const SizedBox(width: 40),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s4),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(99),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 5,
                  backgroundColor: c.textLight.withValues(alpha: 0.18),
                  valueColor: AlwaysStoppedAnimation(c.cta),
                ),
              ),
            ),
          ),
          SizedBox(
            width: 56,
            child: index < _OnboardingScreenState._pageCount - 1
                ? TextButton(
                    onPressed: () => context.go('/onboarding/auth'),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(40, 40),
                    ),
                    child: Text(
                      context.l10n.skip,
                      style: _alex(12, FontWeight.w700, 1.2, c.textLight),
                    ),
                  )
                : const SizedBox(),
          ),
        ],
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar(
      {required this.index, required this.count, required this.onNext});

  final int index;
  final int count;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.gutter,
        12,
        AppSpacing.gutter,
        28,
      ),
      child: AppPrimaryButton(
        label: context.l10n.next,
        onTap: onNext,
        icon: Directionality.of(context) == TextDirection.rtl
            ? Icons.chevron_left_rounded
            : Icons.chevron_right_rounded,
        height: 56,
      ),
    );
  }
}

// ── Pages ────────────────────────────────────────────────────────────────────

class _WelcomePage extends StatelessWidget {
  const _WelcomePage();

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const NeonIllustration(
            icon: Icons.account_balance_wallet_rounded,
            size: 200,
            showBadge: false,
          ).animate().fade(duration: 700.ms).scale(curve: Curves.easeOutBack),
          const SizedBox(height: 40),
          Text(
            'مرحباً بك في قرش',
            textAlign: TextAlign.center,
            style: _alex(28, FontWeight.w900, 1.3, c.textMain),
          ),
          const SizedBox(height: 12),
          Text(
            'تطبيق ذكي يساعدك على فهم مصروفاتك\nوالتحكم فيها بسهولة',
            textAlign: TextAlign.center,
            style: _alex(15, FontWeight.w500, 1.6, c.textLight),
          ),
        ],
      ),
    );
  }
}

// ── Country page (S4) ───────────────────────────────────────────────────────

class _CountryPage extends ConsumerStatefulWidget {
  const _CountryPage();

  @override
  ConsumerState<_CountryPage> createState() => _CountryPageState();
}

class _CountryPageState extends ConsumerState<_CountryPage> {
  void _showCountryPicker(BuildContext context) {
    String searchQuery = '';
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setModalState) {
            final c = context.colors;
            final selected = ref.read(onboardingSelectionProvider);
            final options = _countryOptions(
              ref.read(supportedCountriesProvider).valueOrNull ??
                  const <RemoteCountry>[],
              ref.read(activeCurrenciesProvider).valueOrNull ??
                  const <RemoteCurrency>[],
            );
            final normalizedSearch = searchQuery.trim().toLowerCase();
            final filteredCountries = options
                .where((country) =>
                    country.nameAr.contains(searchQuery) ||
                    country.nameEn.toLowerCase().contains(normalizedSearch) ||
                    country.currencyNameAr.contains(searchQuery) ||
                    country.currencyNameEn
                        .toLowerCase()
                        .contains(normalizedSearch) ||
                    country.currencyCode.toLowerCase().contains(
                          normalizedSearch,
                        ))
                .toList();

            return BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
              child: Container(
                height: MediaQuery.of(context).size.height * 0.7,
                decoration: BoxDecoration(
                  color: c.bg.withValues(alpha: 0.95),
                  borderRadius:
                      const BorderRadius.vertical(top: Radius.circular(24)),
                  border: Border(top: BorderSide(color: c.border)),
                ),
                child: Column(
                  children: [
                    const SizedBox(height: 12),
                    Container(
                      width: 38,
                      height: 4,
                      decoration: BoxDecoration(
                        color: c.border.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(99),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      context.l10n.selectCountryTitle,
                      style: _alex(16, FontWeight.w800, 1.2, c.textMain),
                    ),
                    const SizedBox(height: 12),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: TextField(
                        onChanged: (val) =>
                            setModalState(() => searchQuery = val),
                        style: _alex(13, FontWeight.w600, 1.2, c.textMain),
                        decoration: InputDecoration(
                          hintText: context.l10n.searchCountryPlaceholder,
                          hintStyle:
                              _alex(12, FontWeight.w500, 1.2, c.textLight),
                          prefixIcon: Icon(Icons.search_rounded,
                              color: c.textLight, size: 18),
                          filled: true,
                          fillColor: c.surface.withValues(alpha: 0.15),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 12),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: c.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16),
                            borderSide: BorderSide(color: c.accent),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    Expanded(
                      child: ListView.separated(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
                        itemCount: filteredCountries.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (context, i) {
                          final country = filteredCountries[i];
                          final isSelected = country.code == selected?.code;
                          return _CountryTile(
                            option: country,
                            selected: isSelected,
                            onTap: () {
                              ref
                                  .read(onboardingSelectionProvider.notifier)
                                  .state = country.toSelection();
                              setModalState(() {});
                              Navigator.pop(context);
                            },
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final countriesAsync = ref.watch(supportedCountriesProvider);
    final currenciesAsync = ref.watch(activeCurrenciesProvider);
    final countries = countriesAsync.valueOrNull ?? const <RemoteCountry>[];
    final currencies = currenciesAsync.valueOrNull ?? const <RemoteCurrency>[];
    final options = _countryOptions(countries, currencies);
    final selectedCountry = ref.watch(onboardingSelectionProvider);
    final selectedOption = _selectedOption(options, selectedCountry);

    if (selectedCountry == null && options.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final current = ref.read(onboardingSelectionProvider);
        if (current == null) {
          ref.read(onboardingSelectionProvider.notifier).state =
              options.first.toSelection();
        }
      });
    }

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.gutter),
      children: [
        const SizedBox(height: 8),
        Text('اختر بلدك وعملتك',
            style: _alex(26, FontWeight.w900, 1.3, c.textMain)),
        const SizedBox(height: 10),
        Text('هذا يساعدنا على تخصيص تجربتك وإصدار تقارير دقيقة.',
            style: _alex(14, FontWeight.w500, 1.55, c.textLight)),
        const SizedBox(height: 28),
        Text('البلد', style: _alex(13, FontWeight.w700, 1.2, c.textLight)),
        const SizedBox(height: 8),
        _DropdownField(
          leading: _FlagAvatar(
            code: selectedOption?.code ?? '',
            emoji: selectedOption?.flagEmoji,
            size: 28,
          ),
          label: selectedOption == null
              ? 'تحميل الدول...'
              : selectedOption.localizedName(context),
          onTap: options.isEmpty ? () {} : () => _showCountryPicker(context),
        ),
        const SizedBox(height: 18),
        Text('العملة', style: _alex(13, FontWeight.w700, 1.2, c.textLight)),
        const SizedBox(height: 8),
        _DropdownField(
          leading: Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: c.cta.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(Icons.payments_outlined, size: 16, color: c.cta),
          ),
          label: selectedOption == null
              ? 'تحميل العملات...'
              : '${selectedOption.localizedCurrency(context)} (${selectedOption.currencyCode})',
          onTap: options.isEmpty ? () {} : () => _showCountryPicker(context),
        ),
      ],
    );
  }

  List<_CountryOption> _countryOptions(
    List<RemoteCountry> countries,
    List<RemoteCurrency> currencies,
  ) {
    return [
      for (final country in countries)
        if (_preferredCurrency(country, currencies) != null)
          _CountryOption(
              country: country,
              currency: _preferredCurrency(country, currencies)!),
    ];
  }

  RemoteCurrency? _preferredCurrency(
    RemoteCountry country,
    List<RemoteCurrency> currencies,
  ) {
    final code = country.code.trim().toUpperCase();
    for (final currency in currencies) {
      if (currency.countryCodes.contains(code)) return currency;
    }
    return null;
  }

  _CountryOption? _selectedOption(
    List<_CountryOption> options,
    OnboardingCountry? selected,
  ) {
    if (selected == null) return options.isEmpty ? null : options.first;
    for (final option in options) {
      if (option.code.toLowerCase() == selected.code.toLowerCase()) {
        return option;
      }
    }
    return options.isEmpty ? null : options.first;
  }
}

class _CountryOption {
  const _CountryOption({required this.country, required this.currency});

  final RemoteCountry country;
  final RemoteCurrency currency;

  String get code => country.code.toLowerCase();
  String get flagEmoji => country.flagEmoji;
  String get currencyCode => currency.code.toUpperCase();
  String get nameAr => country.nameAr;
  String get nameEn => country.nameEn;
  String get currencyNameAr => currency.nameAr;
  String get currencyNameEn => currency.nameEn;

  String localizedName(BuildContext context) {
    return Localizations.localeOf(context).languageCode == 'en'
        ? country.nameEn
        : country.nameAr;
  }

  String localizedCurrency(BuildContext context) {
    return Localizations.localeOf(context).languageCode == 'en'
        ? currency.nameEn
        : currency.nameAr;
  }

  OnboardingCountry toSelection() {
    return OnboardingCountry(
      code: code,
      name: country.nameAr,
      currency: currency.nameAr,
      currencyCode: currencyCode,
    );
  }
}

class _DropdownField extends StatelessWidget {
  const _DropdownField({
    required this.leading,
    required this.label,
    required this.onTap,
  });

  final Widget leading;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 15),
        decoration: BoxDecoration(
          color: c.surfaceCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: c.border),
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Text(label,
                  style: _alex(15, FontWeight.w700, 1.2, c.textMain)),
            ),
            Icon(Icons.keyboard_arrow_down_rounded,
                color: c.textLight, size: 22),
          ],
        ),
      ),
    );
  }
}

class _FlagAvatar extends StatelessWidget {
  const _FlagAvatar({required this.code, this.emoji, this.size = 30});
  final String code;
  final String? emoji;
  final double size;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.08),
      decoration: BoxDecoration(
        color: c.surface,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.72)),
        boxShadow: [
          BoxShadow(
            color: c.primary.withValues(alpha: 0.12),
            blurRadius: 12,
            spreadRadius: -6,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Center(
        child: Text(
          emoji == null || emoji!.isEmpty ? code.toUpperCase() : emoji!,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize:
                emoji == null || emoji!.isEmpty ? size * 0.32 : size * 0.54,
            fontWeight: FontWeight.w800,
            height: 1,
          ),
        ),
      ),
    );
  }
}

class _CountryTile extends StatelessWidget {
  const _CountryTile({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  final _CountryOption option;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected
              ? c.accent.withValues(alpha: 0.12)
              : c.surface.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected ? c.accent.withValues(alpha: 0.36) : c.border,
          ),
        ),
        child: Row(
          children: [
            _FlagAvatar(code: option.code, emoji: option.flagEmoji, size: 34),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(option.localizedName(context),
                      style: _alex(12, FontWeight.w800, 1.2, c.textMain)),
                  const SizedBox(height: 4),
                  Text(option.localizedCurrency(context),
                      style: _alex(10, FontWeight.w700, 1.2, c.textLight)),
                ],
              ),
            ),
            Text(
              option.currencyCode,
              style: _alex(
                  11, FontWeight.w800, 1.2, selected ? c.accent : c.textLight,
                  tabular: true),
            ),
          ],
        ),
      ),
    );
  }
}

class KsaFlagIcon extends StatelessWidget {
  const KsaFlagIcon({super.key});

  @override
  Widget build(BuildContext context) {
    return const _FlagAvatar(code: 'sa', size: 40);
  }
}
