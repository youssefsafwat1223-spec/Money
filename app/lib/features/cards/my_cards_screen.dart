import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/di/app_providers.dart';
import '../../core/theme/app_colors.dart';
import '../../core/theme/app_spacing.dart';
import '../../core/theme/app_typography.dart';
import '../../core/theme/widgets/navy_sheet_theme.dart';
import '../../core/utils/formatters.dart';
import '../../domain/entities/account_entity.dart';
import '../../domain/entities/card_entity.dart';
import '../../domain/entities/card_summary.dart';
import '../../domain/entities/transaction_entity.dart';
import '../../domain/errors/repo_exceptions.dart';
import '../common/app_screen_scaffold.dart';
import '../transactions/manual_transaction_sheet.dart';
import 'bank_mark.dart';
import 'card_form_sheet.dart';
import 'card_network_badge.dart';
import 'card_theme.dart';
import 'cards_providers.dart';
import '../../core/theme/widgets/app_toast.dart';

/// مفتاح مطابقة بطاقة مُدارة (CardEntity) بصفّ معروض: (الحساب، آخر 4 أرقام).
String _cardKey(String? accountId, String last4) => '${accountId ?? ''}|$last4';

/// ملخّص بلا عمليات لبطاقة يدوية أُضيفت للتوّ (لا تظهر بعد في التجميع المشتقّ).
CardSummary _zeroSummary(CardEntity card) => CardSummary(
      last4: card.last4,
      network: card.network,
      totalOut: 0,
      totalIn: 0,
      count: 0,
      colorTheme: card.colorTheme,
      accentHex: card.accentHex,
    );

/// صفحة «بطاقاتي»: كل البطاقات + داخل/خارج/الصافي لكل بطاقة، مع إضافة بطاقة
/// جديدة بتصميم مخصّص، أو إضافة/ربط عملية. تُفتح من الإعدادات.
class MyCardsScreen extends ConsumerWidget {
  const MyCardsScreen({super.key});

  static Future<void> open(BuildContext context) {
    return context.push('/cards');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final async = ref.watch(accountCardGroupsProvider);
    final grouping = async.valueOrNull;
    final accounts = ref.watch(accountsProvider).valueOrNull ?? const [];
    final allCards =
        ref.watch(allCardsProvider).valueOrNull ?? const <CardEntity>[];
    final accountName = {for (final a in accounts) a.id: a.name};
    // بطاقة مُدارة مطابقة لكل صفّ — لتفعيل التعديل (الملخّص وحده بلا id).
    final entityByKey = {
      for (final card in allCards) _cardKey(card.accountId, card.last4): card,
    };

    // بناء أقسام: لكل حساب بطاقاته (مشتقّة + يدوية بلا عمليات) + قسم غير المخصّصة.
    final sections = <Widget>[];
    if (grouping != null) {
      // last4 المملوكة يدويًا لحساب — لإسقاطها من «غير مخصّصة» تفاديًا للتكرار.
      final managedAssigned = <String>{
        for (final card in allCards)
          if (card.accountId != null) card.last4,
      };

      for (final account in accounts) {
        final summaries =
            grouping.byAccount[account.id] ?? const <CardSummary>[];
        final shown = {for (final s in summaries) s.last4};
        final extras = [
          for (final card in allCards)
            if (card.accountId == account.id && !shown.contains(card.last4))
              _zeroSummary(card),
        ];
        final combined = [...summaries, ...extras];
        if (combined.isEmpty) continue;
        sections.add(_SectionHeader(title: account.name));
        for (final card in combined) {
          sections.add(_CardRow(
            card: card,
            account: account,
            entity: entityByKey[_cardKey(account.id, card.last4)],
          ));
        }
      }

      // حسابات مربوطة لم تعد في قائمة الحسابات (نادر) — لا نُسقطها.
      for (final entry in grouping.byAccount.entries) {
        if (accountName.containsKey(entry.key)) continue;
        sections.add(const _SectionHeader(title: 'حساب'));
        for (final card in entry.value) {
          sections.add(_CardRow(
            card: card,
            entity: entityByKey[_cardKey(entry.key, card.last4)],
          ));
        }
      }

      // غير المخصّصة: مشتقّة بلا حساب موثوق (وغير مملوكة يدويًا) + يدوية بلا حساب.
      final unassignedBase = [
        for (final s in grouping.unassigned)
          if (!managedAssigned.contains(s.last4)) s,
      ];
      final shownUnassigned = {for (final s in unassignedBase) s.last4};
      final unassignedExtras = [
        for (final card in allCards)
          if (card.accountId == null && !shownUnassigned.contains(card.last4))
            _zeroSummary(card),
      ];
      final unassigned = [...unassignedBase, ...unassignedExtras];
      if (unassigned.isNotEmpty) {
        sections.add(const _SectionHeader(title: 'غير مخصّصة'));
        for (final card in unassigned) {
          sections.add(_CardRow(
            card: card,
            entity: entityByKey[_cardKey(null, card.last4)],
          ));
        }
      }
    }

    return AppScreenScaffold(
      header: Padding(
        padding: const EdgeInsets.fromLTRB(
            AppSpacing.s2, AppSpacing.s3, AppSpacing.gutter, AppSpacing.s3),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back_ios_new, color: c.textMain, size: 20),
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            Text('كل البطاقات', style: AppTypography.title1(c.textMain)),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.add, color: c.cta, size: 24),
              tooltip: 'إضافة بطاقة',
              onPressed: () => showCardForm(context, ref),
            ),
          ],
        ),
      ),
      body: async.isLoading && grouping == null
          ? const Center(child: CircularProgressIndicator())
          : sections.isEmpty
              ? _empty(context, ref)
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(AppSpacing.gutter,
                      AppSpacing.s2, AppSpacing.gutter, AppSpacing.s6),
                  itemCount: sections.length,
                  separatorBuilder: (_, __) =>
                      const SizedBox(height: AppSpacing.s3),
                  itemBuilder: (_, i) => sections[i],
                ),
    );
  }

  Widget _empty(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.gutter),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.credit_card_off, size: 48, color: c.textLight),
            const SizedBox(height: AppSpacing.s4),
            Text('مفيش بطاقات لسه', style: AppTypography.title2(c.textMain)),
            const SizedBox(height: AppSpacing.s2),
            Text(
              'البطاقات بتظهر تلقائيًا من رسائل البنك، وتقدر تضيف بطاقة بتصميمك.',
              textAlign: TextAlign.center,
              style: AppTypography.subhead(c.textLight),
            ),
            const SizedBox(height: AppSpacing.s4),
            FilledButton.icon(
              onPressed: () => showCardForm(context, ref),
              icon: const Icon(Icons.add),
              label: const Text('أضف بطاقة'),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s2, bottom: 2),
      child: Text(title, style: AppTypography.title2(c.textMain)),
    );
  }
}

class _CardRow extends ConsumerWidget {
  const _CardRow({required this.card, this.account, this.entity});

  final CardSummary card;
  final AccountEntity? account;

  /// البطاقة المُدارة المطابقة (إن وُجدت) — أساس التعديل. للبطاقات المشتقّة
  /// فقط تكون null، فيُفتح النموذج مُهيّأً بآخر 4 أرقام/الشبكة لإنشائها.
  final CardEntity? entity;

  void _edit(BuildContext context, WidgetRef ref) {
    final e = entity;
    if (e != null) {
      showCardForm(context, ref, accountId: e.accountId, card: e);
    } else {
      showCardForm(
        context,
        ref,
        accountId: account?.id,
        initialLast4: card.last4,
        initialNetwork: card.network,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = context.colors;
    final net = card.totalIn - card.totalOut;
    return Container(
      decoration: BoxDecoration(
        gradient: cardGradient(context,
            themeKey: card.colorTheme, accentHex: card.accentHex),
        borderRadius: BorderRadius.circular(AppRadius.card),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.22),
            blurRadius: 20,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.card),
          onTap: () => context.push('/card/${card.last4}'),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.s4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (account != null) ...[
                      BankMark(
                        accountName: account!.name,
                        accountType: account!.type,
                        size: 26,
                      ),
                      const SizedBox(width: AppSpacing.s2),
                    ],
                    Icon(Icons.contactless,
                        color: Colors.white.withValues(alpha: 0.8), size: 22),
                    const Spacer(),
                    CardNetworkBadge(network: card.network),
                    const SizedBox(width: AppSpacing.s2),
                    IconButton(
                      onPressed: () => _edit(context, ref),
                      icon: Icon(Icons.edit,
                          color: Colors.white.withValues(alpha: 0.9), size: 18),
                      tooltip: 'تعديل',
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.s5),
                Row(
                  textDirection: TextDirection.ltr,
                  children: [
                    Text('•••• ${card.last4}',
                        style: AppTypography.headline(Colors.white)
                            .copyWith(letterSpacing: 2)),
                  ],
                ),
                const SizedBox(height: AppSpacing.s4),
                Row(
                  children: [
                    _flow('داخل', card.totalIn, c.success),
                    const SizedBox(width: AppSpacing.s5),
                    _flow('خارج', card.totalOut,
                        Colors.white.withValues(alpha: 0.95)),
                    const Spacer(),
                    _flow('الصافي', net, Colors.white),
                  ],
                ),
                const SizedBox(height: AppSpacing.s4),
                Row(
                  children: [
                    Expanded(
                      child: _action(
                        icon: Icons.add,
                        label: 'إضافة عملية',
                        onTap: () => ManualTransactionSheet.show(
                          context,
                          cardLast4: card.last4,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.s3),
                    Expanded(
                      child: _action(
                        icon: Icons.link,
                        label: 'اربط عملية موجودة',
                        onTap: () => _showAttachSheet(context, card.last4),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _action({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return TextButton.icon(
      onPressed: onTap,
      icon: Icon(icon, color: Colors.white, size: 18),
      label: Text(label,
          style: AppTypography.footnote(Colors.white),
          maxLines: 1,
          overflow: TextOverflow.ellipsis),
      style: TextButton.styleFrom(
        backgroundColor: Colors.white.withValues(alpha: 0.16),
        padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s3, vertical: AppSpacing.s2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
      ),
    );
  }

  Widget _flow(String label, double value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: AppTypography.caption(Colors.white.withValues(alpha: 0.6))),
        Text(Formatters.amount(value), style: AppTypography.bodyStrong(color)),
      ],
    );
  }
}

/// شيت اختيار عملية موجودة وربطها بالبطاقة [last4].
Future<void> _showAttachSheet(
  BuildContext context,
  String last4,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (_) => navySheetTheme(_AttachExistingSheet(last4: last4)),
  );
}

class _AttachExistingSheet extends ConsumerStatefulWidget {
  const _AttachExistingSheet({required this.last4});

  final String last4;

  @override
  ConsumerState<_AttachExistingSheet> createState() =>
      _AttachExistingSheetState();
}

class _AttachExistingSheetState extends ConsumerState<_AttachExistingSheet> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<TransactionEntity> _filtered(List<TransactionEntity> all) {
    final last4 = widget.last4;
    final q = _query.trim().toLowerCase();
    final items = all.where((tx) {
      if (q.isEmpty) return true;
      final merchant = (tx.rawMerchant ?? '').toLowerCase();
      final amount = Formatters.amount(tx.amount).toLowerCase();
      return merchant.contains(q) || amount.contains(q);
    }).toList()
      // غير المربوطة بنفس البطاقة تظهر أولاً.
      ..sort((a, b) {
        final aOwn = a.cardLast4 == last4 ? 1 : 0;
        final bOwn = b.cardLast4 == last4 ? 1 : 0;
        return aOwn.compareTo(bOwn);
      });
    return items;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final last4 = widget.last4;
    final async = ref.watch(allTransactionsForPickProvider);
    final all = async.valueOrNull ?? const <TransactionEntity>[];
    final items = _filtered(all);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.95,
      builder: (_, controller) => Material(
        // ListTiles below paint ink on the nearest Material; without this the
        // sheet's colored Container hides splashes (debug assertion spam).
        type: MaterialType.transparency,
        child: Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              const SizedBox(height: AppSpacing.s3),
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: c.textLight.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(AppSpacing.gutter,
                    AppSpacing.gutter, AppSpacing.gutter, AppSpacing.s2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('اربط عملية بـ •••• $last4',
                        style: AppTypography.title2(c.textMain)),
                    const SizedBox(height: AppSpacing.s3),
                    TextField(
                      controller: _search,
                      style: AppTypography.body(c.textMain),
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'ابحث بالاسم أو المبلغ',
                        prefixIcon: const Icon(Icons.search, size: 20),
                        filled: true,
                        fillColor: c.surface2.withValues(alpha: 0.45),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide(color: c.border),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: async.isLoading
                    ? const Center(child: CircularProgressIndicator())
                    : items.isEmpty
                        ? Center(
                            child: Text('مفيش عمليات',
                                style: AppTypography.subhead(c.textLight)))
                        : ListView.builder(
                            controller: controller,
                            itemCount: items.length,
                            itemBuilder: (_, i) {
                              final tx = items[i];
                              final linked = tx.cardLast4 == last4;
                              return ListTile(
                                title: Text(tx.rawMerchant ?? 'عملية',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTypography.body(c.textMain)),
                                subtitle: Text(
                                  '${Formatters.amount(tx.amount)} ${tx.currency}'
                                  '${tx.cardLast4 != null ? ' • •••• ${tx.cardLast4}' : ''}',
                                  style: AppTypography.footnote(c.textLight),
                                ),
                                trailing: linked
                                    ? Icon(Icons.check_circle, color: c.success)
                                    : Icon(Icons.add_link, color: c.textLight),
                                onTap: linked
                                    ? null
                                    : () async {
                                        try {
                                          await ref
                                              .read(
                                                  transactionRepositoryProvider)
                                              .updateCard(
                                                transactionId: tx.id,
                                                cardLast4: last4,
                                              );
                                        } on RepoException catch (e) {
                                          if (!context.mounted) return;
                                          AppToast.show(
                                              context, repoExceptionMessage(e));
                                          return;
                                        }
                                        ref.invalidate(cardSummariesProvider);
                                        ref.invalidate(
                                            accountCardGroupsProvider);
                                        ref.invalidate(
                                            allTransactionsForPickProvider);
                                        ref.invalidate(
                                            cardTransactionsProvider(last4));
                                        if (context.mounted) {
                                          Navigator.of(context).pop();
                                          AppToast.show(context,
                                              'اتربطت العملية بـ •••• $last4');
                                        }
                                      },
                              );
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
