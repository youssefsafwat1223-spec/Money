import 'package:flutter/widgets.dart';

import '../../core/data_portability/data_portability_models.dart';
import '../../core/utils/l10n_ext.dart';

/// Renders a CSV import issue in the reader's language.
///
/// These are produced by the parser, which has no BuildContext, so they carry
/// an Arabic `message` for logs and a locale-independent [ImportIssueCode] the
/// UI resolves. An issue from a site without a code yet still shows its own
/// message — visible beats blank.
String importIssueMessage(BuildContext context, ImportIssue issue) {
  final code = issue.code;
  if (code == null) return issue.message;
  final l = context.l10n;
  final arg = issue.args.isEmpty ? '' : issue.args.first;
  return switch (code) {
    ImportIssueCode.unreadableDate => l.iiUnreadableDate,
    ImportIssueCode.currencyNotIso => l.iiCurrencyNotIso,
    ImportIssueCode.amountInvalidOrZero => l.iiAmountInvalidOrZero,
    ImportIssueCode.csvNeedsTwoColumns => l.iiCsvNeedsTwoColumns,
    ImportIssueCode.headersNotRecognised => l.iiHeadersNotRecognised,
    ImportIssueCode.duplicatesFound => l.iiDuplicatesFound(arg),
  };
}

/// The issue with its row prefix, as the preview list shows it. The prefix was
/// an Arabic literal built at the render site; the row NUMBER is data.
String importIssueLine(BuildContext context, ImportIssue issue) {
  final body = importIssueMessage(context, issue);
  if (issue.rowNumber == null) return body;
  return '${context.l10n.iiRowPrefix('${issue.rowNumber}')}$body';
}
