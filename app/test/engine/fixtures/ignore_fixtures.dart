import 'bank_sms_golden_fixtures.dart';

/// SMS messages that must be ignored — no UI shown, isTransaction = false.
/// These are verbatim real samples from the project spec.
final ignoreFixtures = [
  const BankSmsGoldenFixture(
    id: 'ignore_account_freeze_admin',
    description:
        'Account freeze administrative notice — no money moved, resembles phishing',
    sender: 'anb',
    rawSms: 'عزيزي عميل anb، تم تجميد حسابك لعدم تحديث بياناتك البنكية. '
        'يمكنك تحديث بياناتك من خلال تطبيق anb أو زيارة أقرب فرع',
    expectedStatus: ExpectedSmsStatus.ignored,
  ),
  const BankSmsGoldenFixture(
    id: 'ignore_device_logout_security',
    description: 'Device logout security notice — no money moved',
    sender: 'anb',
    rawSms: 'لحمايتك تم تسجيل خروج أحد أجهزتك من القنوات الرقمية، '
        'بسبب تسجيل دخول أكثر من جهاز',
    expectedStatus: ExpectedSmsStatus.ignored,
  ),
  const BankSmsGoldenFixture(
    id: 'ignore_complaint_closed_notice',
    description: 'Complaint closed notification — no money moved',
    sender: 'CIB',
    rawSms: 'Dear Customer, We would like to inform you that Your Complaint '
        '(Reference 0011389642) has been Closed.',
    expectedStatus: ExpectedSmsStatus.ignored,
  ),
  const BankSmsGoldenFixture(
    id: 'ignore_adib_chequebook_request',
    description:
        'ADIB chequebook administrative notice — no money moved, must not reach AI',
    sender: 'ADIB',
    rawSms: 'Dear Customer, thank you for requesting a new chequebook for your '
        'A/C NO: ****0535. Your request will be fulfilled at the earliest. '
        'Sincerely, ADIB',
    expectedStatus: ExpectedSmsStatus.ignored,
  ),
];
