// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Arabic (`ar`).
class AppL10nAr extends AppL10n {
  AppL10nAr([String locale = 'ar']) : super(locale);

  @override
  String get appTitle => 'قرش';

  @override
  String get setupHeaderTitle => 'يلا نجهّز قِرش';

  @override
  String get setupHeaderSubtitle => 'كام خطوة سريعة وتكون جاهز.';

  @override
  String setupStepLabel(int current, int total) {
    return 'الخطوة $current من $total';
  }

  @override
  String get setupCountryTitle => 'دولتك وعملتك';

  @override
  String get setupCountryBody => 'بنستخدمها كعملة أساسية لحساباتك.';

  @override
  String get setupNotificationsTitle => 'فعّل الإشعارات';

  @override
  String get setupNotificationsBody => 'عشان توصلك كل عملية فور حدوثها.';

  @override
  String get setupNotificationsCta => 'تفعيل';

  @override
  String get setupCloudTitle => 'المعالجة الذكية';

  @override
  String get setupCloudBody =>
      'يعالج قِرش رسائل البنك التي تشاركها عبر خادمه والذكاء الاصطناعي لتحويلها إلى عمليات وتقارير، بدون تخزين أرقامك الكاملة.';

  @override
  String get setupCloudCta => 'متابعة';

  @override
  String get setupShortcutTitle => 'ثبّت اختصار قِرش';

  @override
  String get setupShortcutBody => 'هو اللي بيبعتلنا رسائل البنك تلقائياً.';

  @override
  String get setupShortcutStep1Title => 'احذف القديم';

  @override
  String get setupShortcutStep1Body =>
      'افتح تطبيق Shortcuts وروح لتبويب Automation واحذف أي أتمتة قديمة للتطبيق.';

  @override
  String get setupShortcutStep2Title => 'جديد (+)';

  @override
  String get setupShortcutStep2Body =>
      'اضغط New Automation (+) ومرّر للأسفل حتى تلقى «Message».';

  @override
  String get setupShortcutStep3Title => 'حدّد الرسائل';

  @override
  String setupShortcutStep3Body(String currency) {
    return 'اضغط «Message Contents» واكتب رمز عملتك مثل $currency.';
  }

  @override
  String get setupShortcutStep4Title => 'بدون تأكيد';

  @override
  String get setupShortcutStep4Body =>
      'فعّل «Run Immediately» واقفل «Notify When Run» لو ظهر، ثم Next.';

  @override
  String get setupShortcutStep5Title => 'إرسال للتطبيق';

  @override
  String get setupShortcutStep5Body =>
      'اختر New Blank Automation وابحث عن «Process Bank SMS»، وفي SMS Text اختر «Shortcut Input».';

  @override
  String get setupShortcutStep6Title => 'حفظ';

  @override
  String get setupShortcutStep6Body =>
      'اقفل «Show When Run» لو ظهر، واضغط حفظ.';

  @override
  String get setupShortcutCta => 'ثبّتّه';

  @override
  String get setupFinishCta => 'ابدأ';

  @override
  String get brandTagline => 'فلوسك أوضح. قرارك أذكى.';

  @override
  String get brandContinueCta => 'يلا نبدأ';

  @override
  String get authTitle => 'رحلتك المالية محفوظة';

  @override
  String get authSubtitle => 'سجّل دخولك لحماية بياناتك واستعادتها على أجهزتك.';

  @override
  String get authTrustLocalEncryption => 'تشفير محلي';

  @override
  String get authTrustOnDevice => 'مشفّرة على جهازك، ومتزامنة بأمان';

  @override
  String get authTermsNotice =>
      'بالمتابعة أنت توافق على شروط الاستخدام وسياسة الخصوصية.';

  @override
  String get authAppleCta => 'المتابعة بحساب Apple';

  @override
  String get authGoogleCta => 'المتابعة بحساب Google';

  @override
  String get authSignInError => 'تعذّر تسجيل الدخول. جرب تاني.';

  @override
  String get authBackupFoundTitle => 'لقينا نسخة احتياطية لحسابك';

  @override
  String get authBackupFoundBody =>
      'تحب نرجّع بياناتك من آخر نسخة، ولا تبدأ من جديد؟';

  @override
  String get authBackupStartFresh => 'ابدأ من جديد';

  @override
  String get authBackupRestore => 'استرجاعها';

  @override
  String get storyPromiseTitle => 'متحمّسين\nنبدأ معك';

  @override
  String get storyPromiseSubtitle => 'ونكون شريكك في رحلتك المالية.';

  @override
  String get storyPromiseHighlight =>
      'في قِرش، نؤمن أن الاستقرار المالي يبدأ بعادات بسيطة.';

  @override
  String get storyPromiseBody =>
      'بنينا تطبيقًا يساعدك على إدارة أموالك بسهولة، من تسجيل المصروفات ووضع الميزانيات، إلى تنبيهات الاشتراكات والتقارير الذكية.';

  @override
  String get storyPromiseSectionTitle => 'هدفنا؟';

  @override
  String get storyPromiseSectionBody =>
      'أن تعرف أين يذهب مالك، وتدّخر أكثر وتعيش براحة أكبر.';

  @override
  String get storyPromiseClosing => 'قِرش...\nشريكك في رحلتك المالية.';

  @override
  String get storySpendingTitle => 'المصروفات الصغيرة بتفرق';

  @override
  String get storySpendingBody =>
      'المصروفات اليومية قد تبدو بسيطة،\nلكنها مع الوقت تصنع فرقًا كبيرًا.';

  @override
  String get storySpendingHighlight => 'ما لا تتابعه... يصعب عليك التحكم به';

  @override
  String get storySpendingSupporting =>
      'قِرش يساعدك تشوف الصورة كاملة،\nوتفهم أين تذهب أموالك.';

  @override
  String get storyContinueCta => 'كمّل';

  @override
  String get storyStartCta => 'ابدأ مع قِرش';

  @override
  String get storySkip => 'تخطّي';

  @override
  String get storyPageOneSemanticLabel => 'الصفحة ١ من ٢';

  @override
  String get storyPageTwoSemanticLabel => 'الصفحة ٢ من ٢';

  @override
  String get next => 'التالي';

  @override
  String get skip => 'تخطي';

  @override
  String get registerAndStart => 'التسجيل والبدء';

  @override
  String get welcomeTitle => 'مساعدك المالي اليومي';

  @override
  String get welcomeSubtitle => 'صاحبك في فلوسك';

  @override
  String get today => 'اليوم';

  @override
  String get yesterday => 'أمس';

  @override
  String get welcomeDescription =>
      'اعرف وين راحت فلوسك، ووفّر أوتوماتيكياً بطريقة ذكية وسهلة.';

  @override
  String get secureOnDevice => 'آمن · على جهازك';

  @override
  String get effortless => 'بدون مجهود';

  @override
  String get noTyping => 'لا تكتب — إحنا نفهمها لك';

  @override
  String get smsReadingDesc =>
      'شارك رسالة البنك مع قرش، ونطلّع المبلغ والمتجر ونصنّفها على جهازك.';

  @override
  String get now => 'الآن';

  @override
  String get snbSmsText => 'عملية مدى شراء بـ ';

  @override
  String get snbSmsSuffix => ' لدى هاف مليون.';

  @override
  String get alrajhi => 'الراجحي';

  @override
  String get oneMinuteAgo => 'قبل دقيقة';

  @override
  String get alrajhiSmsText => 'تم خصم ';

  @override
  String get alrajhiSmsSuffix => ' لدى مطعم هامبرغيني.';

  @override
  String get localProcessing => 'معالجة محلية بالكامل';

  @override
  String get privacyFirst => 'الخصوصية أولاً';

  @override
  String get howItWorks => 'كيف يعمل؟';

  @override
  String get smsToTx => 'من رسالة بنك إلى عملية واضحة';

  @override
  String get howItWorksDesc =>
      'قرش يلتقط المعنى من الرسالة، ويحوّلها لتصنيف ومبلغ ومتجر بدون إدخال يدوي.';

  @override
  String get howItWorksNote1 =>
      'مش محتاج تختار بنكك — قرش يتعرّف عليه من نص الرسالة.';

  @override
  String get howItWorksNote2 =>
      'لو ظهرت بطاقة جديدة، قرش يضيفها تلقائياً من آخر 4 أرقام.';

  @override
  String get howItWorksNote3 =>
      'تقدر تراجع وتعدل أي عملية أو بطاقة من داخل التطبيق.';

  @override
  String get messageFromBank => 'رسالة من البنك';

  @override
  String get burgerBoutiqueSms => 'شراء 45 ريال لدى BURGER BOUTIQUE';

  @override
  String get burgerBoutiqueSub => 'مطاعم · الآن · مدى';

  @override
  String get burgerBoutiqueAmount => '-45 ريال';

  @override
  String get financialMotivation => 'التحفيز المالي';

  @override
  String get saveLikeGame => 'وفّر وكأنها لعبة يومية';

  @override
  String get saveLikeGameDesc =>
      'حدّد أهدافك المالية ووفّر الفروقات يومًا بعد يوم بطابع تشجيعي ذكي.';

  @override
  String get totalSavings => 'مجموع الادخار المتراكم';

  @override
  String get sar => 'ر.س';

  @override
  String get travelVault => 'خزنة السفر';

  @override
  String get completedPercent => '75% مكتمل';

  @override
  String get goalLimit => 'الهدف: 15,000 ر.س';

  @override
  String get remainingAmount => 'متبقي: 3,750 ر.س';

  @override
  String get easyToUse => 'سهل الاستخدام';

  @override
  String get selectCountryCurrency => 'اختَر بلدك وعملتك';

  @override
  String get selectCountryDesc =>
      'نعرض الأعلام الرسمية، ونضبط العملة الأساسية، وتقدر تضيف عملات ثانية لو عندك بطاقات أو اشتراكات خارجية.';

  @override
  String get mainCountryCurrency => 'البلد والعملة الأساسية';

  @override
  String get additionalCurrencies => 'العملات الإضافية';

  @override
  String get activeSubscriptions => 'الاشتراكات النشطة';

  @override
  String get none => 'لا توجد';

  @override
  String get noActiveSubs => 'لا توجد اشتراكات نشطة';

  @override
  String get selectCountryTitle => 'اختر بلدك وعملتك الأساسية';

  @override
  String get searchCountryPlaceholder => 'البحث عن بلد أو عملة...';

  @override
  String get additionalCurrenciesTitle => 'العملات الإضافية';

  @override
  String get additionalCurrenciesDesc =>
      'اختياري، اختر العملات التي تتعامل بها بجانب عملتك الأساسية.';

  @override
  String get expectedSubscriptions => 'الاشتراكات المتوقعة';

  @override
  String get expectedSubscriptionsDesc =>
      'حدد الاشتراكات النشطة لديك وسنقوم بالتعرف عليها تلقائياً.';

  @override
  String get completePrivacy => 'خصوصية تامّة';

  @override
  String get dataStaysOnDevice => 'بياناتك تبقى في جهازك';

  @override
  String get privacyPrinciples =>
      'مبادئ الأمان والخصوصية لدينا تعني أنك المتحكم الوحيد ببياناتك المالية.';

  @override
  String get privacyRule1 =>
      'يعالج قِرش رسائل البنك التي تشاركها عبر خادمه والذكاء الاصطناعي';

  @override
  String get privacyRule2 =>
      'نعالج فقط رسائل البنك التي تشاركها أو تلصقها بنفسك';

  @override
  String get privacyRule3 => 'ما نبيع بياناتك أبداً، ولك كامل الحرية في حذفها';

  @override
  String get enableAutoTracking => 'شارك رسائل البنك مع قرش';

  @override
  String get setupAppleShortcut => 'إعداد اختصار Apple';

  @override
  String get autoTrackingSubtitleAndroid =>
      'من تطبيق الرسائل، اختر رسالة البنك ثم مشاركة إلى قرش. سنحللها على جهازك ونضيف العملية.';

  @override
  String get autoTrackingSubtitleIos =>
      'اتبع الخطوات مرة واحدة، وبعدها يمرّر iPhone رسائل البنك إلى قرش بأمان.';

  @override
  String get smsActivationSnack =>
      'تقدر تشارك رسالة البنك مع قرش أو تلصقها يدويًا.';

  @override
  String get howWillActivationWork => 'كيف سيتم التفعيل؟';

  @override
  String get allowSmsReading => 'فهمت';

  @override
  String get gotIt => 'تمام، فهمت';

  @override
  String get laterAddManually => 'لاحقاً، سأقوم بالإضافة يدوياً';

  @override
  String get shortcutSetupGuide => 'دليل إعداد الاختصار';

  @override
  String get doStepsOnceFromShortcuts =>
      'اعمل الخطوات دي مرة واحدة من تطبيق Apple Shortcuts.';

  @override
  String get signInToStart => 'سجّل دخولك للبدء';

  @override
  String get signInSubtitle =>
      'الدخول لتحديد هويتك ومزامنة إعداداتك فقط. بياناتك المالية تبقى آمنة على جهازك.';

  @override
  String get noPassword => 'بدون كلمة مرور';

  @override
  String get continueWithApple => 'المتابعة مع Apple';

  @override
  String get continueWithGoogle => 'المتابعة مع Google';

  @override
  String get or => 'أو';

  @override
  String get continueWithEmail => 'المتابعة بالبريد الإلكتروني';

  @override
  String get email => 'البريد الإلكتروني';

  @override
  String get sendOtpCode => 'إرسال رمز الدخول الآمن';

  @override
  String get byContinuingAgree =>
      'بالمتابعة توافق على شروط الخدمة وسياسة الخصوصية الخاصة بـ قرش.';

  @override
  String get enterOtpCode => 'أدخل رمز التحقق';

  @override
  String get otpSentTo =>
      'أرسلنا رمز التحقق المكون من 6 أرقام إلى البريد الإلكتروني:';

  @override
  String get verifyCode => 'تأكيد الرمز';

  @override
  String get demoOtpCode => 'للتجربة: الرمز 123456';

  @override
  String get invalidOtpCode => 'الرمز غير صحيح';

  @override
  String get enterPasswordOrRecoveryCodeError =>
      'اكتب كلمة مرور النسخة أو رمز الاسترداد.';

  @override
  String get recoveryCodeIncorrect =>
      'رمز الاسترداد غير صحيح أو لا يطابق النسخة.';

  @override
  String get backupPasswordIncorrect =>
      'كلمة مرور النسخة الاحتياطية غير صحيحة.';

  @override
  String get backupFound => 'وجدنا نسخة احتياطية لحسابك';

  @override
  String get restoreDesc =>
      'استعادة بياناتك المشفّرة تتم على جهازك فقط. كلمة المرور لا تخرج من هاتفك.';

  @override
  String get recoveryCodeLabel => 'رمز الاسترداد';

  @override
  String get backupPasswordLabel => 'كلمة مرور النسخة الاحتياطية';

  @override
  String get recoveryCodeHint => 'XXXX-XXXX-XXXX';

  @override
  String get backupPasswordHint => 'اكتب كلمة المرور التي اخترتها';

  @override
  String get useBackupPassword => 'استخدام كلمة مرور النسخة';

  @override
  String get useRecoveryCode => 'استخدام رمز الاسترداد';

  @override
  String get restore => 'استعادة';

  @override
  String get startFresh => 'ابدأ جديد';

  @override
  String get notNow => 'ليس الآن';

  @override
  String get restoreNotEnabled =>
      'الاستعادة السحابية غير مفعّلة في هذا البناء.';

  @override
  String get appleSecuritySteps => 'خطوات الأمان لآبل';

  @override
  String get iosShortcutSubtitle =>
      'بسبب قيود نظام iOS، نستخدم تطبيق الاختصارات الرسمي من Apple لتمرير رسائل البنك لـ قرش تلقائياً وبأمان تام.';

  @override
  String get stepsLabel => 'الخطوات:';

  @override
  String get multipleCurrenciesQuestion => 'تتعامل بأكثر من عملة؟';

  @override
  String get multipleCurrenciesDesc =>
      'إذا كانت تصلك رسائل بنكية بعملات مختلفة، كرّر نفس الخطوات لكل عملة.';

  @override
  String get continueWithoutAccount => 'أكمل بدون حساب';

  @override
  String get continueWithoutAccountSub => 'بياناتك تبقى محلية على جهازك.';

  @override
  String get smsPermissionRationaleTitle => 'محتاجين إذن قراءة رسائل البنك بس';

  @override
  String get smsPermissionRationaleBody =>
      'قرش يقرأ رسائل البنك على جهازك فقط عشان يسجّل عملياتك تلقائياً. مش بنقرأ رسائلك الشخصية، ومفيش حاجة بتطلع برّه الجهاز.';

  @override
  String get listeningTitle => 'جاهزين — بنستنى رسالتك الأولى';

  @override
  String get listeningSubtitle => 'اعمل أي شراء بكارتك وهيظهر هنا تلقائياً.';

  @override
  String get pasteMessageInstead => 'ألصق رسالة بنك بدلاً من كده';

  @override
  String get skipForNow => 'تخطي الآن';

  @override
  String get shortcutVerifyTitle => 'خلينا نتأكد إن الاختصار شغّال';

  @override
  String get shortcutVerifyBody =>
      'ارجع لتطبيق Shortcuts وابعت نفسك رسالة فيها كلمة العملة، ثم ارجع هنا.';

  @override
  String get shortcutVerifyWaiting => 'بنستنى رسالة...';

  @override
  String get recheckSetup => 'راجع الإعداد';

  @override
  String get filterKeywordsLabel => 'كلمة المفتاح:';

  @override
  String get firstTxTitle => 'أول عملية اتسجّلت لوحدها!';

  @override
  String get firstTxTrustLine =>
      'إنت معملتش حاجة — قرش قرأ رسالة بنكك وسجّلها.';

  @override
  String get firstTxContinue => 'تمام، كمّل';

  @override
  String get firstTxNeedsCheck => 'محتاجة تأكيد سريع';

  @override
  String get firstTxNeedsCheckSub => 'قرش مش متأكد 100% — راجعها بسرعة.';

  @override
  String get wrongCategoryTap => 'الفئة مش صح؟ اضغط لتغييرها';
}
