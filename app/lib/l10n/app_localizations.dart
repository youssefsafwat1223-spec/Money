import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_ar.dart';
import 'app_localizations_en.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppL10n
/// returned by `AppL10n.of(context)`.
///
/// Applications need to include `AppL10n.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppL10n.localizationsDelegates,
///   supportedLocales: AppL10n.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppL10n.supportedLocales
/// property.
abstract class AppL10n {
  AppL10n(String locale)
      : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppL10n of(BuildContext context) {
    return Localizations.of<AppL10n>(context, AppL10n)!;
  }

  static const LocalizationsDelegate<AppL10n> delegate = _AppL10nDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
    delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
  ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('ar'),
    Locale('en')
  ];

  /// No description provided for @appTitle.
  ///
  /// In ar, this message translates to:
  /// **'قرش'**
  String get appTitle;

  /// No description provided for @setupHeaderTitle.
  ///
  /// In ar, this message translates to:
  /// **'لنُجهّز قِرش'**
  String get setupHeaderTitle;

  /// No description provided for @setupHeaderSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'كام خطوة سريعة وتكون جاهز.'**
  String get setupHeaderSubtitle;

  /// No description provided for @setupStepLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخطوة {current} من {total}'**
  String setupStepLabel(int current, int total);

  /// No description provided for @setupCountryTitle.
  ///
  /// In ar, this message translates to:
  /// **'دولتك وعملتك'**
  String get setupCountryTitle;

  /// No description provided for @setupCountryBody.
  ///
  /// In ar, this message translates to:
  /// **'بنستخدمها كعملة أساسية لحساباتك.'**
  String get setupCountryBody;

  /// No description provided for @setupNotificationsTitle.
  ///
  /// In ar, this message translates to:
  /// **'فعّل الإشعارات'**
  String get setupNotificationsTitle;

  /// No description provided for @setupNotificationsBody.
  ///
  /// In ar, this message translates to:
  /// **'لتصلك كل عملية فور حدوثها.'**
  String get setupNotificationsBody;

  /// No description provided for @setupNotificationsCta.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل'**
  String get setupNotificationsCta;

  /// No description provided for @setupCloudTitle.
  ///
  /// In ar, this message translates to:
  /// **'المعالجة الذكية'**
  String get setupCloudTitle;

  /// No description provided for @setupCloudBody.
  ///
  /// In ar, this message translates to:
  /// **'يعالج قِرش رسائل البنك التي تشاركها عبر خادمه والذكاء الاصطناعي لتحويلها إلى عمليات وتقارير، بدون تخزين أرقامك الكاملة.'**
  String get setupCloudBody;

  /// No description provided for @setupCloudCta.
  ///
  /// In ar, this message translates to:
  /// **'متابعة'**
  String get setupCloudCta;

  /// No description provided for @setupShortcutTitle.
  ///
  /// In ar, this message translates to:
  /// **'ثبّت اختصار قِرش'**
  String get setupShortcutTitle;

  /// No description provided for @setupShortcutBody.
  ///
  /// In ar, this message translates to:
  /// **'هو اللي بيبعتلنا رسائل البنك تلقائياً.'**
  String get setupShortcutBody;

  /// No description provided for @setupShortcutStep1Title.
  ///
  /// In ar, this message translates to:
  /// **'احذف القديم'**
  String get setupShortcutStep1Title;

  /// No description provided for @setupShortcutStep1Body.
  ///
  /// In ar, this message translates to:
  /// **'افتح تطبيق Shortcuts وروح لتبويب Automation واحذف أي أتمتة قديمة للتطبيق.'**
  String get setupShortcutStep1Body;

  /// No description provided for @setupShortcutStep2Title.
  ///
  /// In ar, this message translates to:
  /// **'جديد (+)'**
  String get setupShortcutStep2Title;

  /// No description provided for @setupShortcutStep2Body.
  ///
  /// In ar, this message translates to:
  /// **'اضغط New Automation (+) ومرّر للأسفل حتى تلقى «Message».'**
  String get setupShortcutStep2Body;

  /// No description provided for @setupShortcutStep3Title.
  ///
  /// In ar, this message translates to:
  /// **'حدّد الرسائل'**
  String get setupShortcutStep3Title;

  /// No description provided for @setupShortcutStep3Body.
  ///
  /// In ar, this message translates to:
  /// **'اضغط «Message Contents» واكتب رمز عملتك مثل {currency}.'**
  String setupShortcutStep3Body(String currency);

  /// No description provided for @setupShortcutStep4Title.
  ///
  /// In ar, this message translates to:
  /// **'بدون تأكيد'**
  String get setupShortcutStep4Title;

  /// No description provided for @setupShortcutStep4Body.
  ///
  /// In ar, this message translates to:
  /// **'فعّل «Run Immediately» واقفل «Notify When Run» لو ظهر، ثم Next.'**
  String get setupShortcutStep4Body;

  /// No description provided for @setupShortcutStep5Title.
  ///
  /// In ar, this message translates to:
  /// **'إرسال للتطبيق'**
  String get setupShortcutStep5Title;

  /// No description provided for @setupShortcutStep5Body.
  ///
  /// In ar, this message translates to:
  /// **'اختر New Blank Automation وابحث عن «Process Bank SMS»، وفي SMS Text اختر «Shortcut Input».'**
  String get setupShortcutStep5Body;

  /// No description provided for @setupShortcutStep6Title.
  ///
  /// In ar, this message translates to:
  /// **'حفظ'**
  String get setupShortcutStep6Title;

  /// No description provided for @setupShortcutStep6Body.
  ///
  /// In ar, this message translates to:
  /// **'اقفل «Show When Run» لو ظهر، واضغط حفظ.'**
  String get setupShortcutStep6Body;

  /// No description provided for @setupShortcutCta.
  ///
  /// In ar, this message translates to:
  /// **'ثبّتّه'**
  String get setupShortcutCta;

  /// No description provided for @setupFinishCta.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ'**
  String get setupFinishCta;

  /// No description provided for @brandTagline.
  ///
  /// In ar, this message translates to:
  /// **'فلوسك أوضح. قرارك أذكى.'**
  String get brandTagline;

  /// No description provided for @brandContinueCta.
  ///
  /// In ar, this message translates to:
  /// **'لنبدأ'**
  String get brandContinueCta;

  /// No description provided for @authTitle.
  ///
  /// In ar, this message translates to:
  /// **'رحلتك المالية محفوظة'**
  String get authTitle;

  /// No description provided for @authSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'سجّل دخولك لحماية بياناتك واستعادتها على أجهزتك.'**
  String get authSubtitle;

  /// No description provided for @authTrustLocalEncryption.
  ///
  /// In ar, this message translates to:
  /// **'تشفير محلي'**
  String get authTrustLocalEncryption;

  /// No description provided for @authTrustOnDevice.
  ///
  /// In ar, this message translates to:
  /// **'مشفّرة على جهازك، ومتزامنة بأمان'**
  String get authTrustOnDevice;

  /// No description provided for @authTermsNotice.
  ///
  /// In ar, this message translates to:
  /// **'بالمتابعة أنت توافق على شروط الاستخدام وسياسة الخصوصية.'**
  String get authTermsNotice;

  /// No description provided for @authAppleCta.
  ///
  /// In ar, this message translates to:
  /// **'المتابعة بحساب Apple'**
  String get authAppleCta;

  /// No description provided for @authGoogleCta.
  ///
  /// In ar, this message translates to:
  /// **'المتابعة بحساب Google'**
  String get authGoogleCta;

  /// No description provided for @authSignInError.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تسجيل الدخول. جرب تاني.'**
  String get authSignInError;

  /// No description provided for @authBackupFoundTitle.
  ///
  /// In ar, this message translates to:
  /// **'لقينا نسخة احتياطية لحسابك'**
  String get authBackupFoundTitle;

  /// No description provided for @authBackupFoundBody.
  ///
  /// In ar, this message translates to:
  /// **'تحب نرجّع بياناتك من آخر نسخة، ولا تبدأ من جديد؟'**
  String get authBackupFoundBody;

  /// No description provided for @authBackupStartFresh.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ من جديد'**
  String get authBackupStartFresh;

  /// No description provided for @authBackupRestore.
  ///
  /// In ar, this message translates to:
  /// **'استرجاعها'**
  String get authBackupRestore;

  /// No description provided for @storyPromiseTitle.
  ///
  /// In ar, this message translates to:
  /// **'متحمّسين\nنبدأ معك'**
  String get storyPromiseTitle;

  /// No description provided for @storyPromiseSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'ونكون شريكك في رحلتك المالية.'**
  String get storyPromiseSubtitle;

  /// No description provided for @storyPromiseHighlight.
  ///
  /// In ar, this message translates to:
  /// **'في قِرش، نؤمن أن الاستقرار المالي يبدأ بعادات بسيطة.'**
  String get storyPromiseHighlight;

  /// No description provided for @storyPromiseBody.
  ///
  /// In ar, this message translates to:
  /// **'بنينا تطبيقًا يساعدك على إدارة أموالك بسهولة، من تسجيل المصروفات ووضع الميزانيات، إلى تنبيهات الاشتراكات والتقارير الذكية.'**
  String get storyPromiseBody;

  /// No description provided for @storyPromiseSectionTitle.
  ///
  /// In ar, this message translates to:
  /// **'هدفنا؟'**
  String get storyPromiseSectionTitle;

  /// No description provided for @storyPromiseSectionBody.
  ///
  /// In ar, this message translates to:
  /// **'أن تعرف أين يذهب مالك، وتدّخر أكثر وتعيش براحة أكبر.'**
  String get storyPromiseSectionBody;

  /// No description provided for @storyPromiseClosing.
  ///
  /// In ar, this message translates to:
  /// **'قِرش...\nشريكك في رحلتك المالية.'**
  String get storyPromiseClosing;

  /// No description provided for @storySpendingTitle.
  ///
  /// In ar, this message translates to:
  /// **'المصروفات الصغيرة بتفرق'**
  String get storySpendingTitle;

  /// No description provided for @storySpendingBody.
  ///
  /// In ar, this message translates to:
  /// **'المصروفات اليومية قد تبدو بسيطة،\nلكنها مع الوقت تصنع فرقًا كبيرًا.'**
  String get storySpendingBody;

  /// No description provided for @storySpendingHighlight.
  ///
  /// In ar, this message translates to:
  /// **'ما لا تتابعه... يصعب عليك التحكم به'**
  String get storySpendingHighlight;

  /// No description provided for @storySpendingSupporting.
  ///
  /// In ar, this message translates to:
  /// **'يساعدك قِرش على رؤية الصورة كاملة،\nوفهم أين تذهب أموالك.'**
  String get storySpendingSupporting;

  /// No description provided for @storyContinueCta.
  ///
  /// In ar, this message translates to:
  /// **'كمّل'**
  String get storyContinueCta;

  /// No description provided for @storyStartCta.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ مع قِرش'**
  String get storyStartCta;

  /// No description provided for @storySkip.
  ///
  /// In ar, this message translates to:
  /// **'تخطّي'**
  String get storySkip;

  /// No description provided for @storyPageOneSemanticLabel.
  ///
  /// In ar, this message translates to:
  /// **'الصفحة ١ من ٢'**
  String get storyPageOneSemanticLabel;

  /// No description provided for @storyPageTwoSemanticLabel.
  ///
  /// In ar, this message translates to:
  /// **'الصفحة ٢ من ٢'**
  String get storyPageTwoSemanticLabel;

  /// No description provided for @next.
  ///
  /// In ar, this message translates to:
  /// **'التالي'**
  String get next;

  /// No description provided for @skip.
  ///
  /// In ar, this message translates to:
  /// **'تخطي'**
  String get skip;

  /// No description provided for @registerAndStart.
  ///
  /// In ar, this message translates to:
  /// **'التسجيل والبدء'**
  String get registerAndStart;

  /// No description provided for @welcomeTitle.
  ///
  /// In ar, this message translates to:
  /// **'مساعدك المالي اليومي'**
  String get welcomeTitle;

  /// No description provided for @welcomeSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'صاحبك في فلوسك'**
  String get welcomeSubtitle;

  /// No description provided for @today.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get today;

  /// No description provided for @yesterday.
  ///
  /// In ar, this message translates to:
  /// **'أمس'**
  String get yesterday;

  /// No description provided for @welcomeDescription.
  ///
  /// In ar, this message translates to:
  /// **'اعرف أين تذهب أموالك، وادّخر تلقائيًا بطريقة ذكية وسهلة.'**
  String get welcomeDescription;

  /// No description provided for @secureOnDevice.
  ///
  /// In ar, this message translates to:
  /// **'آمن · على جهازك'**
  String get secureOnDevice;

  /// No description provided for @effortless.
  ///
  /// In ar, this message translates to:
  /// **'بدون مجهود'**
  String get effortless;

  /// No description provided for @noTyping.
  ///
  /// In ar, this message translates to:
  /// **'لا تكتب — إحنا نفهمها لك'**
  String get noTyping;

  /// No description provided for @smsReadingDesc.
  ///
  /// In ar, this message translates to:
  /// **'شارك رسالة البنك مع قرش، ونطلّع المبلغ والمتجر ونصنّفها على جهازك.'**
  String get smsReadingDesc;

  /// No description provided for @now.
  ///
  /// In ar, this message translates to:
  /// **'الآن'**
  String get now;

  /// No description provided for @snbSmsText.
  ///
  /// In ar, this message translates to:
  /// **'عملية مدى شراء بـ '**
  String get snbSmsText;

  /// No description provided for @snbSmsSuffix.
  ///
  /// In ar, this message translates to:
  /// **' لدى هاف مليون.'**
  String get snbSmsSuffix;

  /// No description provided for @alrajhi.
  ///
  /// In ar, this message translates to:
  /// **'الراجحي'**
  String get alrajhi;

  /// No description provided for @oneMinuteAgo.
  ///
  /// In ar, this message translates to:
  /// **'قبل دقيقة'**
  String get oneMinuteAgo;

  /// No description provided for @alrajhiSmsText.
  ///
  /// In ar, this message translates to:
  /// **'تم خصم '**
  String get alrajhiSmsText;

  /// No description provided for @alrajhiSmsSuffix.
  ///
  /// In ar, this message translates to:
  /// **' لدى مطعم هامبرغيني.'**
  String get alrajhiSmsSuffix;

  /// No description provided for @localProcessing.
  ///
  /// In ar, this message translates to:
  /// **'معالجة محلية بالكامل'**
  String get localProcessing;

  /// No description provided for @privacyFirst.
  ///
  /// In ar, this message translates to:
  /// **'الخصوصية أولاً'**
  String get privacyFirst;

  /// No description provided for @howItWorks.
  ///
  /// In ar, this message translates to:
  /// **'كيف يعمل؟'**
  String get howItWorks;

  /// No description provided for @smsToTx.
  ///
  /// In ar, this message translates to:
  /// **'من رسالة بنك إلى عملية واضحة'**
  String get smsToTx;

  /// No description provided for @howItWorksDesc.
  ///
  /// In ar, this message translates to:
  /// **'قرش يلتقط المعنى من الرسالة، ويحوّلها لتصنيف ومبلغ ومتجر بدون إدخال يدوي.'**
  String get howItWorksDesc;

  /// No description provided for @howItWorksNote1.
  ///
  /// In ar, this message translates to:
  /// **'لا حاجة لاختيار مصرفك — يتعرّف قِرش عليه من نص الرسالة.'**
  String get howItWorksNote1;

  /// No description provided for @howItWorksNote2.
  ///
  /// In ar, this message translates to:
  /// **'لو ظهرت بطاقة جديدة، قرش يضيفها تلقائياً من آخر 4 أرقام.'**
  String get howItWorksNote2;

  /// No description provided for @howItWorksNote3.
  ///
  /// In ar, this message translates to:
  /// **'تقدر تراجع وتعدل أي عملية أو بطاقة من داخل التطبيق.'**
  String get howItWorksNote3;

  /// No description provided for @messageFromBank.
  ///
  /// In ar, this message translates to:
  /// **'رسالة من البنك'**
  String get messageFromBank;

  /// No description provided for @burgerBoutiqueSms.
  ///
  /// In ar, this message translates to:
  /// **'شراء 45 ريال لدى BURGER BOUTIQUE'**
  String get burgerBoutiqueSms;

  /// No description provided for @burgerBoutiqueSub.
  ///
  /// In ar, this message translates to:
  /// **'مطاعم · الآن · مدى'**
  String get burgerBoutiqueSub;

  /// No description provided for @burgerBoutiqueAmount.
  ///
  /// In ar, this message translates to:
  /// **'-45 ريال'**
  String get burgerBoutiqueAmount;

  /// No description provided for @financialMotivation.
  ///
  /// In ar, this message translates to:
  /// **'التحفيز المالي'**
  String get financialMotivation;

  /// No description provided for @saveLikeGame.
  ///
  /// In ar, this message translates to:
  /// **'وفّر وكأنها لعبة يومية'**
  String get saveLikeGame;

  /// No description provided for @saveLikeGameDesc.
  ///
  /// In ar, this message translates to:
  /// **'حدّد أهدافك المالية ووفّر الفروقات يومًا بعد يوم بطابع تشجيعي ذكي.'**
  String get saveLikeGameDesc;

  /// No description provided for @totalSavings.
  ///
  /// In ar, this message translates to:
  /// **'مجموع الادخار المتراكم'**
  String get totalSavings;

  /// No description provided for @sar.
  ///
  /// In ar, this message translates to:
  /// **'ر.س'**
  String get sar;

  /// No description provided for @travelVault.
  ///
  /// In ar, this message translates to:
  /// **'خزنة السفر'**
  String get travelVault;

  /// No description provided for @completedPercent.
  ///
  /// In ar, this message translates to:
  /// **'75% مكتمل'**
  String get completedPercent;

  /// No description provided for @goalLimit.
  ///
  /// In ar, this message translates to:
  /// **'الهدف: 15,000 ر.س'**
  String get goalLimit;

  /// No description provided for @remainingAmount.
  ///
  /// In ar, this message translates to:
  /// **'متبقي: 3,750 ر.س'**
  String get remainingAmount;

  /// No description provided for @easyToUse.
  ///
  /// In ar, this message translates to:
  /// **'سهل الاستخدام'**
  String get easyToUse;

  /// No description provided for @selectCountryCurrency.
  ///
  /// In ar, this message translates to:
  /// **'اختَر بلدك وعملتك'**
  String get selectCountryCurrency;

  /// No description provided for @selectCountryDesc.
  ///
  /// In ar, this message translates to:
  /// **'نعرض الأعلام الرسمية، ونضبط العملة الأساسية، وتقدر تضيف عملات ثانية لو عندك بطاقات أو اشتراكات خارجية.'**
  String get selectCountryDesc;

  /// No description provided for @mainCountryCurrency.
  ///
  /// In ar, this message translates to:
  /// **'البلد والعملة الأساسية'**
  String get mainCountryCurrency;

  /// No description provided for @additionalCurrencies.
  ///
  /// In ar, this message translates to:
  /// **'العملات الإضافية'**
  String get additionalCurrencies;

  /// No description provided for @activeSubscriptions.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات النشطة'**
  String get activeSubscriptions;

  /// No description provided for @none.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد'**
  String get none;

  /// No description provided for @noActiveSubs.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد اشتراكات نشطة'**
  String get noActiveSubs;

  /// No description provided for @selectCountryTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر بلدك وعملتك الأساسية'**
  String get selectCountryTitle;

  /// No description provided for @searchCountryPlaceholder.
  ///
  /// In ar, this message translates to:
  /// **'البحث عن بلد أو عملة...'**
  String get searchCountryPlaceholder;

  /// No description provided for @additionalCurrenciesTitle.
  ///
  /// In ar, this message translates to:
  /// **'العملات الإضافية'**
  String get additionalCurrenciesTitle;

  /// No description provided for @additionalCurrenciesDesc.
  ///
  /// In ar, this message translates to:
  /// **'اختياري، اختر العملات التي تتعامل بها بجانب عملتك الأساسية.'**
  String get additionalCurrenciesDesc;

  /// No description provided for @expectedSubscriptions.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات المتوقعة'**
  String get expectedSubscriptions;

  /// No description provided for @expectedSubscriptionsDesc.
  ///
  /// In ar, this message translates to:
  /// **'حدد الاشتراكات النشطة لديك وسنقوم بالتعرف عليها تلقائياً.'**
  String get expectedSubscriptionsDesc;

  /// No description provided for @completePrivacy.
  ///
  /// In ar, this message translates to:
  /// **'خصوصية تامّة'**
  String get completePrivacy;

  /// No description provided for @dataStaysOnDevice.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك تبقى في جهازك'**
  String get dataStaysOnDevice;

  /// No description provided for @privacyPrinciples.
  ///
  /// In ar, this message translates to:
  /// **'مبادئ الأمان والخصوصية لدينا تعني أنك المتحكم الوحيد ببياناتك المالية.'**
  String get privacyPrinciples;

  /// No description provided for @privacyRule1.
  ///
  /// In ar, this message translates to:
  /// **'يعالج قِرش رسائل البنك التي تشاركها عبر خادمه والذكاء الاصطناعي'**
  String get privacyRule1;

  /// No description provided for @privacyRule2.
  ///
  /// In ar, this message translates to:
  /// **'نعالج فقط رسائل البنك التي تشاركها أو تلصقها بنفسك'**
  String get privacyRule2;

  /// No description provided for @privacyRule3.
  ///
  /// In ar, this message translates to:
  /// **'ما نبيع بياناتك أبداً، ولك كامل الحرية في حذفها'**
  String get privacyRule3;

  /// No description provided for @enableAutoTracking.
  ///
  /// In ar, this message translates to:
  /// **'شارك رسائل البنك مع قرش'**
  String get enableAutoTracking;

  /// No description provided for @setupAppleShortcut.
  ///
  /// In ar, this message translates to:
  /// **'إعداد اختصار Apple'**
  String get setupAppleShortcut;

  /// No description provided for @autoTrackingSubtitleAndroid.
  ///
  /// In ar, this message translates to:
  /// **'من تطبيق الرسائل، اختر رسالة البنك ثم مشاركة إلى قرش. سنحللها على جهازك ونضيف العملية.'**
  String get autoTrackingSubtitleAndroid;

  /// No description provided for @autoTrackingSubtitleIos.
  ///
  /// In ar, this message translates to:
  /// **'اتبع الخطوات مرة واحدة، وبعدها يمرّر iPhone رسائل البنك إلى قرش بأمان.'**
  String get autoTrackingSubtitleIos;

  /// No description provided for @smsActivationSnack.
  ///
  /// In ar, this message translates to:
  /// **'تقدر تشارك رسالة البنك مع قرش أو تلصقها يدويًا.'**
  String get smsActivationSnack;

  /// No description provided for @howWillActivationWork.
  ///
  /// In ar, this message translates to:
  /// **'كيف سيتم التفعيل؟'**
  String get howWillActivationWork;

  /// No description provided for @allowSmsReading.
  ///
  /// In ar, this message translates to:
  /// **'فهمت'**
  String get allowSmsReading;

  /// No description provided for @gotIt.
  ///
  /// In ar, this message translates to:
  /// **'تمام، فهمت'**
  String get gotIt;

  /// No description provided for @laterAddManually.
  ///
  /// In ar, this message translates to:
  /// **'لاحقاً، سأقوم بالإضافة يدوياً'**
  String get laterAddManually;

  /// No description provided for @shortcutSetupGuide.
  ///
  /// In ar, this message translates to:
  /// **'دليل إعداد الاختصار'**
  String get shortcutSetupGuide;

  /// No description provided for @doStepsOnceFromShortcuts.
  ///
  /// In ar, this message translates to:
  /// **'نفّذ هذه الخطوات مرة واحدة من تطبيق Apple Shortcuts.'**
  String get doStepsOnceFromShortcuts;

  /// No description provided for @signInToStart.
  ///
  /// In ar, this message translates to:
  /// **'سجّل دخولك للبدء'**
  String get signInToStart;

  /// No description provided for @signInSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'الدخول لتحديد هويتك ومزامنة إعداداتك فقط. بياناتك المالية تبقى آمنة على جهازك.'**
  String get signInSubtitle;

  /// No description provided for @noPassword.
  ///
  /// In ar, this message translates to:
  /// **'بدون كلمة مرور'**
  String get noPassword;

  /// No description provided for @continueWithApple.
  ///
  /// In ar, this message translates to:
  /// **'المتابعة مع Apple'**
  String get continueWithApple;

  /// No description provided for @continueWithGoogle.
  ///
  /// In ar, this message translates to:
  /// **'المتابعة مع Google'**
  String get continueWithGoogle;

  /// No description provided for @or.
  ///
  /// In ar, this message translates to:
  /// **'أو'**
  String get or;

  /// No description provided for @continueWithEmail.
  ///
  /// In ar, this message translates to:
  /// **'المتابعة بالبريد الإلكتروني'**
  String get continueWithEmail;

  /// No description provided for @email.
  ///
  /// In ar, this message translates to:
  /// **'البريد الإلكتروني'**
  String get email;

  /// No description provided for @sendOtpCode.
  ///
  /// In ar, this message translates to:
  /// **'إرسال رمز الدخول الآمن'**
  String get sendOtpCode;

  /// No description provided for @byContinuingAgree.
  ///
  /// In ar, this message translates to:
  /// **'بالمتابعة توافق على شروط الخدمة وسياسة الخصوصية الخاصة بـ قرش.'**
  String get byContinuingAgree;

  /// No description provided for @enterOtpCode.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رمز التحقق'**
  String get enterOtpCode;

  /// No description provided for @otpSentTo.
  ///
  /// In ar, this message translates to:
  /// **'أرسلنا رمز التحقق المكون من 6 أرقام إلى البريد الإلكتروني:'**
  String get otpSentTo;

  /// No description provided for @verifyCode.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الرمز'**
  String get verifyCode;

  /// No description provided for @demoOtpCode.
  ///
  /// In ar, this message translates to:
  /// **'للتجربة: الرمز 123456'**
  String get demoOtpCode;

  /// No description provided for @invalidOtpCode.
  ///
  /// In ar, this message translates to:
  /// **'الرمز غير صحيح'**
  String get invalidOtpCode;

  /// No description provided for @enterPasswordOrRecoveryCodeError.
  ///
  /// In ar, this message translates to:
  /// **'اكتب كلمة مرور النسخة أو رمز الاسترداد.'**
  String get enterPasswordOrRecoveryCodeError;

  /// No description provided for @recoveryCodeIncorrect.
  ///
  /// In ar, this message translates to:
  /// **'رمز الاسترداد غير صحيح أو لا يطابق النسخة.'**
  String get recoveryCodeIncorrect;

  /// No description provided for @backupPasswordIncorrect.
  ///
  /// In ar, this message translates to:
  /// **'كلمة مرور النسخة الاحتياطية غير صحيحة.'**
  String get backupPasswordIncorrect;

  /// No description provided for @backupFound.
  ///
  /// In ar, this message translates to:
  /// **'وجدنا نسخة احتياطية لحسابك'**
  String get backupFound;

  /// No description provided for @restoreDesc.
  ///
  /// In ar, this message translates to:
  /// **'استعادة بياناتك المشفّرة تتم على جهازك فقط. كلمة المرور لا تخرج من هاتفك.'**
  String get restoreDesc;

  /// No description provided for @recoveryCodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'رمز الاسترداد'**
  String get recoveryCodeLabel;

  /// No description provided for @backupPasswordLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة مرور النسخة الاحتياطية'**
  String get backupPasswordLabel;

  /// No description provided for @recoveryCodeHint.
  ///
  /// In ar, this message translates to:
  /// **'XXXX-XXXX-XXXX'**
  String get recoveryCodeHint;

  /// No description provided for @backupPasswordHint.
  ///
  /// In ar, this message translates to:
  /// **'اكتب كلمة المرور التي اخترتها'**
  String get backupPasswordHint;

  /// No description provided for @useBackupPassword.
  ///
  /// In ar, this message translates to:
  /// **'استخدام كلمة مرور النسخة'**
  String get useBackupPassword;

  /// No description provided for @useRecoveryCode.
  ///
  /// In ar, this message translates to:
  /// **'استخدام رمز الاسترداد'**
  String get useRecoveryCode;

  /// No description provided for @restore.
  ///
  /// In ar, this message translates to:
  /// **'استعادة'**
  String get restore;

  /// No description provided for @startFresh.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ جديد'**
  String get startFresh;

  /// No description provided for @notNow.
  ///
  /// In ar, this message translates to:
  /// **'ليس الآن'**
  String get notNow;

  /// No description provided for @restoreNotEnabled.
  ///
  /// In ar, this message translates to:
  /// **'الاستعادة السحابية غير مفعّلة في هذا البناء.'**
  String get restoreNotEnabled;

  /// No description provided for @appleSecuritySteps.
  ///
  /// In ar, this message translates to:
  /// **'خطوات الأمان لآبل'**
  String get appleSecuritySteps;

  /// No description provided for @iosShortcutSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'بسبب قيود نظام iOS، نستخدم تطبيق الاختصارات الرسمي من Apple لتمرير رسائل البنك لـ قرش تلقائياً وبأمان تام.'**
  String get iosShortcutSubtitle;

  /// No description provided for @stepsLabel.
  ///
  /// In ar, this message translates to:
  /// **'الخطوات:'**
  String get stepsLabel;

  /// No description provided for @multipleCurrenciesQuestion.
  ///
  /// In ar, this message translates to:
  /// **'تتعامل بأكثر من عملة؟'**
  String get multipleCurrenciesQuestion;

  /// No description provided for @multipleCurrenciesDesc.
  ///
  /// In ar, this message translates to:
  /// **'إذا كانت تصلك رسائل بنكية بعملات مختلفة، كرّر نفس الخطوات لكل عملة.'**
  String get multipleCurrenciesDesc;

  /// No description provided for @continueWithoutAccount.
  ///
  /// In ar, this message translates to:
  /// **'أكمل بدون حساب'**
  String get continueWithoutAccount;

  /// No description provided for @continueWithoutAccountSub.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك تبقى محلية على جهازك.'**
  String get continueWithoutAccountSub;

  /// No description provided for @smsPermissionRationaleTitle.
  ///
  /// In ar, this message translates to:
  /// **'محتاجين إذن قراءة رسائل البنك بس'**
  String get smsPermissionRationaleTitle;

  /// No description provided for @smsPermissionRationaleBody.
  ///
  /// In ar, this message translates to:
  /// **'يقرأ قِرش رسائل المصرف الواردة على جهازك ليسجّل عملياتك تلقائيًا. لا يقرأ رسائلك الشخصية، ويتم التحليل على الجهاز افتراضيًا — لا يخرج منه شيء إلا إذا فعّلت المعالجة السحابية بنفسك.'**
  String get smsPermissionRationaleBody;

  /// No description provided for @listeningTitle.
  ///
  /// In ar, this message translates to:
  /// **'جاهزين — بنستنى رسالتك الأولى'**
  String get listeningTitle;

  /// No description provided for @listeningSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'اعمل أي شراء بكارتك وهيظهر هنا تلقائياً.'**
  String get listeningSubtitle;

  /// No description provided for @pasteMessageInstead.
  ///
  /// In ar, this message translates to:
  /// **'ألصق رسالة مصرفية بدلًا من ذلك'**
  String get pasteMessageInstead;

  /// No description provided for @skipForNow.
  ///
  /// In ar, this message translates to:
  /// **'تخطي الآن'**
  String get skipForNow;

  /// No description provided for @shortcutVerifyTitle.
  ///
  /// In ar, this message translates to:
  /// **'خلينا نتأكد إن الاختصار شغّال'**
  String get shortcutVerifyTitle;

  /// No description provided for @shortcutVerifyBody.
  ///
  /// In ar, this message translates to:
  /// **'ارجع لتطبيق Shortcuts وابعت نفسك رسالة فيها كلمة العملة، ثم ارجع هنا.'**
  String get shortcutVerifyBody;

  /// No description provided for @shortcutVerifyWaiting.
  ///
  /// In ar, this message translates to:
  /// **'بنستنى رسالة...'**
  String get shortcutVerifyWaiting;

  /// No description provided for @recheckSetup.
  ///
  /// In ar, this message translates to:
  /// **'راجع الإعداد'**
  String get recheckSetup;

  /// No description provided for @filterKeywordsLabel.
  ///
  /// In ar, this message translates to:
  /// **'كلمة المفتاح:'**
  String get filterKeywordsLabel;

  /// No description provided for @firstTxTitle.
  ///
  /// In ar, this message translates to:
  /// **'أول عملية اتسجّلت لوحدها!'**
  String get firstTxTitle;

  /// No description provided for @firstTxTrustLine.
  ///
  /// In ar, this message translates to:
  /// **'لم تفعل شيئًا — قرأ قِرش رسالة مصرفك وسجّلها.'**
  String get firstTxTrustLine;

  /// No description provided for @firstTxContinue.
  ///
  /// In ar, this message translates to:
  /// **'تمام، كمّل'**
  String get firstTxContinue;

  /// No description provided for @firstTxNeedsCheck.
  ///
  /// In ar, this message translates to:
  /// **'محتاجة تأكيد سريع'**
  String get firstTxNeedsCheck;

  /// No description provided for @firstTxNeedsCheckSub.
  ///
  /// In ar, this message translates to:
  /// **'قِرش غير متأكد تمامًا — راجعها سريعًا.'**
  String get firstTxNeedsCheckSub;

  /// No description provided for @wrongCategoryTap.
  ///
  /// In ar, this message translates to:
  /// **'التصنيف غير صحيح؟ اضغط لتغييره'**
  String get wrongCategoryTap;

  /// No description provided for @couponsTitle.
  ///
  /// In ar, this message translates to:
  /// **'العروض'**
  String get couponsTitle;

  /// No description provided for @couponsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'عروض شركاء تساعدك توفر في مصروفاتك اليومية.'**
  String get couponsSubtitle;

  /// No description provided for @couponsFilterAll.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get couponsFilterAll;

  /// No description provided for @couponsFeaturedSection.
  ///
  /// In ar, this message translates to:
  /// **'عروض مميزة'**
  String get couponsFeaturedSection;

  /// No description provided for @couponsEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عروض حالياً'**
  String get couponsEmptyTitle;

  /// No description provided for @couponsEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'هنعرض لك عروض الشركاء هنا أول ما تكون متاحة.'**
  String get couponsEmptyBody;

  /// No description provided for @couponsFilterEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عروض بهذا الفلتر'**
  String get couponsFilterEmptyTitle;

  /// No description provided for @couponsFilterEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'جرّب فئة أو وسم مختلف.'**
  String get couponsFilterEmptyBody;

  /// No description provided for @couponsErrorTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل العروض'**
  String get couponsErrorTitle;

  /// No description provided for @couponsErrorBody.
  ///
  /// In ar, this message translates to:
  /// **'حاول مرة أخرى بعد لحظات.'**
  String get couponsErrorBody;

  /// No description provided for @couponsRetry.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get couponsRetry;

  /// No description provided for @couponsLoading.
  ///
  /// In ar, this message translates to:
  /// **'تحميل العروض...'**
  String get couponsLoading;

  /// No description provided for @couponsCopyCode.
  ///
  /// In ar, this message translates to:
  /// **'نسخ الكود'**
  String get couponsCopyCode;

  /// No description provided for @couponsCodeCopied.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ الكود {code}'**
  String couponsCodeCopied(String code);

  /// No description provided for @couponsOpenPartner.
  ///
  /// In ar, this message translates to:
  /// **'فتح موقع الشريك'**
  String get couponsOpenPartner;

  /// No description provided for @couponsUseOffer.
  ///
  /// In ar, this message translates to:
  /// **'احصل على العرض'**
  String get couponsUseOffer;

  /// No description provided for @couponsOpenFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر فتح الرابط'**
  String get couponsOpenFailed;

  /// No description provided for @couponsOfferUnavailable.
  ///
  /// In ar, this message translates to:
  /// **'هذا العرض غير متاح حاليًا'**
  String get couponsOfferUnavailable;

  /// No description provided for @couponsTerms.
  ///
  /// In ar, this message translates to:
  /// **'الشروط'**
  String get couponsTerms;

  /// No description provided for @couponsValidUntil.
  ///
  /// In ar, this message translates to:
  /// **'ينتهي {date}'**
  String couponsValidUntil(String date);

  /// No description provided for @couponsOpenEnded.
  ///
  /// In ar, this message translates to:
  /// **'مفتوح'**
  String get couponsOpenEnded;

  /// No description provided for @couponsExpiresToday.
  ///
  /// In ar, this message translates to:
  /// **'ينتهي اليوم'**
  String get couponsExpiresToday;

  /// No description provided for @couponsExpiresInDays.
  ///
  /// In ar, this message translates to:
  /// **'{days} يوم'**
  String couponsExpiresInDays(int days);

  /// No description provided for @couponsAvailableGlobally.
  ///
  /// In ar, this message translates to:
  /// **'متاح في كل الدول'**
  String get couponsAvailableGlobally;

  /// No description provided for @couponsAvailableIn.
  ///
  /// In ar, this message translates to:
  /// **'متاح في {countries}'**
  String couponsAvailableIn(String countries);

  /// No description provided for @couponsCardSemantics.
  ///
  /// In ar, this message translates to:
  /// **'عرض من {partner}: {title}'**
  String couponsCardSemantics(String partner, String title);

  /// No description provided for @couponsCodeSemantics.
  ///
  /// In ar, this message translates to:
  /// **'كود الخصم {code}'**
  String couponsCodeSemantics(String code);

  /// No description provided for @couponsOffline.
  ///
  /// In ar, this message translates to:
  /// **'هذه آخر العروض المتاحة لديك دون اتصال.'**
  String get couponsOffline;

  /// No description provided for @referralTitle.
  ///
  /// In ar, this message translates to:
  /// **'دعوة الأصدقاء'**
  String get referralTitle;

  /// No description provided for @referralSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'ادعُ أصدقاءك بالرمز، ولما ينضمّوا ويأكّدوا حسابهم تكسب تقارير بدون إعلانات.'**
  String get referralSubtitle;

  /// No description provided for @referralYourCodeLabel.
  ///
  /// In ar, this message translates to:
  /// **'رمز الدعوة'**
  String get referralYourCodeLabel;

  /// No description provided for @referralCopyAction.
  ///
  /// In ar, this message translates to:
  /// **'نسخ'**
  String get referralCopyAction;

  /// No description provided for @referralCopiedToast.
  ///
  /// In ar, this message translates to:
  /// **'تم نسخ الرمز.'**
  String get referralCopiedToast;

  /// No description provided for @referralShareAction.
  ///
  /// In ar, this message translates to:
  /// **'مشاركة'**
  String get referralShareAction;

  /// No description provided for @referralShareMessage.
  ///
  /// In ar, this message translates to:
  /// **'جرّب قرش! استخدم رمز الدعوة {code} وانت بتسجّل. حمّل التطبيق وابدأ.'**
  String referralShareMessage(String code);

  /// No description provided for @referralProgressLabel.
  ///
  /// In ar, this message translates to:
  /// **'{progress} / {required} دعوات صالحة'**
  String referralProgressLabel(int progress, int required);

  /// No description provided for @referralCycleLabel.
  ///
  /// In ar, this message translates to:
  /// **'الدورة {cycle}'**
  String referralCycleLabel(int cycle);

  /// No description provided for @referralRewardTitle.
  ///
  /// In ar, this message translates to:
  /// **'المكافأة'**
  String get referralRewardTitle;

  /// No description provided for @referralRewardDays.
  ///
  /// In ar, this message translates to:
  /// **'تقارير بدون إعلانات لمدة {days} يومًا'**
  String referralRewardDays(int days);

  /// No description provided for @referralRewardScopeNote.
  ///
  /// In ar, this message translates to:
  /// **'تزيل المكافأة إعلانات تصدير التقارير فقط — وليست اشتراكًا بلا إعلانات لكامل التطبيق.'**
  String get referralRewardScopeNote;

  /// No description provided for @referralRewardActiveUntil.
  ///
  /// In ar, this message translates to:
  /// **'تقارير بدون إعلانات حتى {date}'**
  String referralRewardActiveUntil(String date);

  /// No description provided for @referralEntitlementInactive.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مكافأة نشطة حاليًا.'**
  String get referralEntitlementInactive;

  /// No description provided for @referralApplyTitle.
  ///
  /// In ar, this message translates to:
  /// **'عندك رمز دعوة؟'**
  String get referralApplyTitle;

  /// No description provided for @referralApplyHint.
  ///
  /// In ar, this message translates to:
  /// **'أدخل رمز صديقك مرة واحدة.'**
  String get referralApplyHint;

  /// No description provided for @referralApplyPlaceholder.
  ///
  /// In ar, this message translates to:
  /// **'رمز الدعوة'**
  String get referralApplyPlaceholder;

  /// No description provided for @referralApplyAction.
  ///
  /// In ar, this message translates to:
  /// **'تفعيل الرمز'**
  String get referralApplyAction;

  /// No description provided for @referralApplySuccess.
  ///
  /// In ar, this message translates to:
  /// **'تم قبول الرمز.'**
  String get referralApplySuccess;

  /// No description provided for @referralQualifiedToast.
  ///
  /// In ar, this message translates to:
  /// **'تم احتساب دعوتك.'**
  String get referralQualifiedToast;

  /// No description provided for @referralAlreadyReferredNote.
  ///
  /// In ar, this message translates to:
  /// **'تم تفعيل رمز دعوة على حسابك.'**
  String get referralAlreadyReferredNote;

  /// No description provided for @referralLoading.
  ///
  /// In ar, this message translates to:
  /// **'جارٍ التحميل…'**
  String get referralLoading;

  /// No description provided for @referralErrorTitle.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تحميل الدعوات'**
  String get referralErrorTitle;

  /// No description provided for @referralErrorBody.
  ///
  /// In ar, this message translates to:
  /// **'حاول مرة أخرى بعد لحظات.'**
  String get referralErrorBody;

  /// No description provided for @referralRetry.
  ///
  /// In ar, this message translates to:
  /// **'إعادة المحاولة'**
  String get referralRetry;

  /// No description provided for @referralUnavailableTitle.
  ///
  /// In ar, this message translates to:
  /// **'الدعوات غير متاحة حاليًا'**
  String get referralUnavailableTitle;

  /// No description provided for @referralUnavailableBody.
  ///
  /// In ar, this message translates to:
  /// **'هنعرض لك دعوة الأصدقاء هنا أول ما تكون متاحة.'**
  String get referralUnavailableBody;

  /// No description provided for @referralErrorInvalidCode.
  ///
  /// In ar, this message translates to:
  /// **'رمز غير صحيح.'**
  String get referralErrorInvalidCode;

  /// No description provided for @referralErrorSelfReferral.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكنك استخدام رمزك الخاص.'**
  String get referralErrorSelfReferral;

  /// No description provided for @referralErrorAlreadyReferred.
  ///
  /// In ar, this message translates to:
  /// **'لقد استخدمت رمز دعوة من قبل.'**
  String get referralErrorAlreadyReferred;

  /// No description provided for @referralErrorNoActiveRule.
  ///
  /// In ar, this message translates to:
  /// **'الدعوات غير متاحة حاليًا.'**
  String get referralErrorNoActiveRule;

  /// No description provided for @referralErrorIdentityUnverified.
  ///
  /// In ar, this message translates to:
  /// **'أكمل تأكيد حسابك لتُحتسب دعوتك.'**
  String get referralErrorIdentityUnverified;

  /// No description provided for @referralErrorGeneric.
  ///
  /// In ar, this message translates to:
  /// **'حصل خطأ، حاول تاني.'**
  String get referralErrorGeneric;

  /// Title of the Android prominent disclosure shown immediately before the RECEIVE_SMS system dialog.
  ///
  /// In ar, this message translates to:
  /// **'قراءة رسائل البنك تلقائياً'**
  String get smsDisclosureTitle;

  /// Opening line of the SMS prominent disclosure.
  ///
  /// In ar, this message translates to:
  /// **'ليسجّل قِرش مصاريفك تلقائيًا، يحتاج إذن قراءة الرسائل الواردة على جهازك.'**
  String get smsDisclosureIntro;

  /// Disclosure point: what Qirsh looks for in incoming messages.
  ///
  /// In ar, this message translates to:
  /// **'يفحص قِرش الرسائل الواردة ليتعرّف على العمليات المالية (شراء، تحويل، سحب، إيداع).'**
  String get smsDisclosureDetect;

  /// Disclosure point: non-financial messages are discarded, not stored.
  ///
  /// In ar, this message translates to:
  /// **'الرسائل غير المالية — الشخصية ورموز التحقق — بتتجاهَل ومابتتخزّنش.'**
  String get smsDisclosureFilter;

  /// Disclosure point: parsing happens on-device.
  ///
  /// In ar, this message translates to:
  /// **'يتم التحليل على جهازك افتراضيًا. وإذا فعّلت المعالجة السحابية، يُرسَل نص منقّى (دون أرقام البطاقات والحسابات والهواتف) إلى خوادم قِرش.'**
  String get smsDisclosureOnDevice;

  /// Disclosure point: cloud sync is a separate, off-by-default consent.
  ///
  /// In ar, this message translates to:
  /// **'المزامنة السحابية مغلقة افتراضيًا، وإذا فعّلتها فذلك بموافقة منفصلة عن هذا الإذن.'**
  String get smsDisclosureCloud;

  /// Disclosure point: how to turn the feature off or revoke the permission.
  ///
  /// In ar, this message translates to:
  /// **'تقدر توقف القراءة التلقائية من إعدادات قِرش، أو تسحب الإذن من إعدادات الجهاز، في أي وقت.'**
  String get smsDisclosureControl;

  /// Decline button on the SMS prominent disclosure.
  ///
  /// In ar, this message translates to:
  /// **'ليس الآن'**
  String get smsDisclosureDecline;

  /// Affirmative button that proceeds to the system permission dialog.
  ///
  /// In ar, this message translates to:
  /// **'موافق، اطلب الإذن'**
  String get smsDisclosureAccept;

  /// No description provided for @couponsForYouSection.
  ///
  /// In ar, this message translates to:
  /// **'لأماكن تتسوق منها'**
  String get couponsForYouSection;

  /// No description provided for @couponsForYouSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'مطابقة تمت على هذا الجهاز من مصروفاتك. لا يُرسَل أي شيء منها لأي مكان.'**
  String get couponsForYouSubtitle;

  /// No description provided for @couponsStoresSection.
  ///
  /// In ar, this message translates to:
  /// **'المتاجر'**
  String get couponsStoresSection;

  /// No description provided for @couponsStoresSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'متاجر لديها عروض سارية.'**
  String get couponsStoresSubtitle;

  /// No description provided for @couponsMerchantOffers.
  ///
  /// In ar, this message translates to:
  /// **'عروض {merchant}'**
  String couponsMerchantOffers(String merchant);

  /// No description provided for @couponsMerchantEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عروض سارية هنا الآن'**
  String get couponsMerchantEmptyTitle;

  /// No description provided for @couponsMerchantEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'لا عروض لهذا المتجر حاليًا. تابعنا لاحقًا.'**
  String get couponsMerchantEmptyBody;

  /// No description provided for @couponsPersonalizationTitle.
  ///
  /// In ar, this message translates to:
  /// **'رتّب العروض حسب أماكن تسوقك'**
  String get couponsPersonalizationTitle;

  /// No description provided for @couponsPersonalizationBody.
  ///
  /// In ar, this message translates to:
  /// **'يطابق قِرش عملياتك مع المتاجر على هذا الجهاز ويعرض عروضها أولًا. مصروفاتك لا تغادر هاتفك من أجل هذا، ولا تُرسَل للمتاجر.'**
  String get couponsPersonalizationBody;

  /// No description provided for @couponsPersonalizationOff.
  ///
  /// In ar, this message translates to:
  /// **'مُعطّل — ترتيب العروض واحد للجميع.'**
  String get couponsPersonalizationOff;

  /// No description provided for @couponsPersonalizationOn.
  ///
  /// In ar, this message translates to:
  /// **'مُفعّل — عروض المتاجر التي تستخدمها تظهر أولًا.'**
  String get couponsPersonalizationOn;

  /// No description provided for @couponsValuePercent.
  ///
  /// In ar, this message translates to:
  /// **'خصم {percent}%'**
  String couponsValuePercent(String percent);

  /// No description provided for @couponsValueFixed.
  ///
  /// In ar, this message translates to:
  /// **'خصم {amount}'**
  String couponsValueFixed(String amount);

  /// No description provided for @couponsValueFreeShipping.
  ///
  /// In ar, this message translates to:
  /// **'توصيل مجاني'**
  String get couponsValueFreeShipping;

  /// No description provided for @couponsValueMinSpend.
  ///
  /// In ar, this message translates to:
  /// **'عند {amount} أو أكثر'**
  String couponsValueMinSpend(String amount);

  /// No description provided for @couponsValueUpTo.
  ///
  /// In ar, this message translates to:
  /// **'حتى {amount}'**
  String couponsValueUpTo(String amount);

  /// No description provided for @couponsVerifiedByUs.
  ///
  /// In ar, this message translates to:
  /// **'تحقّق منه قِرش'**
  String get couponsVerifiedByUs;

  /// No description provided for @couponsVerifiedByProvider.
  ///
  /// In ar, this message translates to:
  /// **'مؤكَّد من المزوّد'**
  String get couponsVerifiedByProvider;

  /// No description provided for @couponsUnverified.
  ///
  /// In ar, this message translates to:
  /// **'غير مُتحقَّق منه'**
  String get couponsUnverified;

  /// No description provided for @savingsTitle.
  ///
  /// In ar, this message translates to:
  /// **'ما وفّرته'**
  String get savingsTitle;

  /// No description provided for @savingsEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد مبالغ موفَّرة بعد'**
  String get savingsEmptyTitle;

  /// No description provided for @savingsEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'عند استخدامك عرضًا وتأكيده، سيظهر هنا.'**
  String get savingsEmptyBody;

  /// No description provided for @savingsVerifiedLabel.
  ///
  /// In ar, this message translates to:
  /// **'مؤكَّد من المتجر'**
  String get savingsVerifiedLabel;

  /// No description provided for @savingsEstimatedLabel.
  ///
  /// In ar, this message translates to:
  /// **'تقديري'**
  String get savingsEstimatedLabel;

  /// No description provided for @savingsSelfReportedLabel.
  ///
  /// In ar, this message translates to:
  /// **'بتأكيدك أنت'**
  String get savingsSelfReportedLabel;

  /// No description provided for @savingsBreakdownNote.
  ///
  /// In ar, this message translates to:
  /// **'نفصل هذه الأرقام لأنها ليست بنفس درجة التأكيد. المؤكَّد فقط هو ما أبلغنا به المتجر.'**
  String get savingsBreakdownNote;

  /// No description provided for @savingsCurrencyNote.
  ///
  /// In ar, this message translates to:
  /// **'العملات لا تُجمع معًا.'**
  String get savingsCurrencyNote;

  /// No description provided for @savingsConfirmTitle.
  ///
  /// In ar, this message translates to:
  /// **'هل استخدمت هذا العرض؟'**
  String get savingsConfirmTitle;

  /// No description provided for @savingsConfirmBody.
  ///
  /// In ar, this message translates to:
  /// **'أدخل قيمة طلبك لنحسب ما وفّرته. الحساب يتم على جهازك ولا يُرسَل لأي مكان.'**
  String get savingsConfirmBody;

  /// No description provided for @savingsConfirmAmountLabel.
  ///
  /// In ar, this message translates to:
  /// **'قيمة الطلب'**
  String get savingsConfirmAmountLabel;

  /// No description provided for @savingsConfirmAction.
  ///
  /// In ar, this message translates to:
  /// **'احسب'**
  String get savingsConfirmAction;

  /// No description provided for @savingsCannotCompute.
  ///
  /// In ar, this message translates to:
  /// **'لا يمكننا حساب رقم دقيق لهذا العرض، فلن نعرض رقمًا.'**
  String get savingsCannotCompute;

  /// No description provided for @savingsReversedNote.
  ///
  /// In ar, this message translates to:
  /// **'أُلغي هذا المبلغ بعد أن تراجع المتجر عن العملية.'**
  String get savingsReversedNote;

  /// Label above a third-party advertisement, distinguishing it from Qirsh's own offers.
  ///
  /// In ar, this message translates to:
  /// **'إعلان'**
  String get adLabel;

  /// Settings toggle enabling Android automatic bank-SMS capture.
  ///
  /// In ar, this message translates to:
  /// **'الالتقاط التلقائي لرسائل البنك'**
  String get smsAutoCaptureTitle;

  /// No description provided for @smsAutoCaptureSubtitleOff.
  ///
  /// In ar, this message translates to:
  /// **'مطفأ — أضف عملياتك يدويًا أو بالمشاركة'**
  String get smsAutoCaptureSubtitleOff;

  /// No description provided for @smsAutoCaptureSubtitleOn.
  ///
  /// In ar, this message translates to:
  /// **'يعمل — تُقرأ رسائل البنك الواردة على جهازك فقط'**
  String get smsAutoCaptureSubtitleOn;

  /// No description provided for @smsAutoCaptureSubtitleBlocked.
  ///
  /// In ar, this message translates to:
  /// **'تم رفض الإذن — افتح إعدادات النظام للسماح'**
  String get smsAutoCaptureSubtitleBlocked;

  /// No description provided for @smsAutoCaptureOpenSettings.
  ///
  /// In ar, this message translates to:
  /// **'فتح إعدادات النظام'**
  String get smsAutoCaptureOpenSettings;

  /// No description provided for @smsAutoCaptureDeniedTitle.
  ///
  /// In ar, this message translates to:
  /// **'لم يُمنح الإذن'**
  String get smsAutoCaptureDeniedTitle;

  /// No description provided for @smsAutoCaptureDeniedBody.
  ///
  /// In ar, this message translates to:
  /// **'الالتقاط التلقائي يحتاج إذن قراءة الرسائل الواردة. تقدر تكمل بالإضافة اليدوية أو بمشاركة الرسالة مع قرش.'**
  String get smsAutoCaptureDeniedBody;

  /// Accurate description of what Qirsh does and does not read.
  ///
  /// In ar, this message translates to:
  /// **'على أندرويد، قرش يقرأ الرسائل الواردة فقط بعد ما تشغّل الالتقاط التلقائي وتمنح الإذن. لا يقرأ إشعارات تطبيقات البنوك، ولا يفتح أرشيف رسائلك.'**
  String get smsCaptureTrustNotice;

  /// Generic cancel action in a dialog.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get commonCancel;

  /// No description provided for @helpTitle.
  ///
  /// In ar, this message translates to:
  /// **'كيف تستخدم قِرش'**
  String get helpTitle;

  /// No description provided for @helpSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'دليل مختصر لأهم ما يمكنك فعله في التطبيق.'**
  String get helpSubtitle;

  /// No description provided for @helpSettingsTile.
  ///
  /// In ar, this message translates to:
  /// **'كيف تستخدم قِرش'**
  String get helpSettingsTile;

  /// No description provided for @helpSettingsSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'دليل الاستخدام والأسئلة الشائعة'**
  String get helpSettingsSubtitle;

  /// No description provided for @helpSectionBasics.
  ///
  /// In ar, this message translates to:
  /// **'الأساسيات'**
  String get helpSectionBasics;

  /// No description provided for @helpSectionReports.
  ///
  /// In ar, this message translates to:
  /// **'التقارير والتحليلات'**
  String get helpSectionReports;

  /// No description provided for @helpSectionPlanning.
  ///
  /// In ar, this message translates to:
  /// **'التخطيط'**
  String get helpSectionPlanning;

  /// No description provided for @helpSectionPrivacy.
  ///
  /// In ar, this message translates to:
  /// **'الخصوصية والبيانات'**
  String get helpSectionPrivacy;

  /// No description provided for @helpAddTransactionTitle.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل عملية'**
  String get helpAddTransactionTitle;

  /// No description provided for @helpAddTransactionBody.
  ///
  /// In ar, this message translates to:
  /// **'اضغط زر الإضافة في الشاشة الرئيسية، ثم اختر الإضافة اليدوية أو الصق نص رسالة البنك. يقرأ قِرش الرسالة ويستخرج المبلغ والتاجر والتاريخ، وتبقى لك الكلمة الأخيرة قبل الحفظ.'**
  String get helpAddTransactionBody;

  /// No description provided for @helpSmartInboxTitle.
  ///
  /// In ar, this message translates to:
  /// **'صندوق الوارد الذكي'**
  String get helpSmartInboxTitle;

  /// No description provided for @helpSmartInboxBody.
  ///
  /// In ar, this message translates to:
  /// **'العمليات التي يلتقطها قِرش من رسائل البنك تصل هنا أولًا. راجعها وأكّدها أو عدّل تصنيفها، فتنتقل بعدها إلى سجل عملياتك.'**
  String get helpSmartInboxBody;

  /// No description provided for @helpCategoriesTitle.
  ///
  /// In ar, this message translates to:
  /// **'التصنيفات'**
  String get helpCategoriesTitle;

  /// No description provided for @helpCategoriesBody.
  ///
  /// In ar, this message translates to:
  /// **'لكل عملية تصنيف يحدد مكانها في التقارير والميزانيات. غيّر التصنيف من تفاصيل العملية، ويتعلّم قِرش اختيارك للمتجر نفسه مستقبلًا.'**
  String get helpCategoriesBody;

  /// No description provided for @helpPeriodTitle.
  ///
  /// In ar, this message translates to:
  /// **'تغيير الفترة'**
  String get helpPeriodTitle;

  /// No description provided for @helpPeriodBody.
  ///
  /// In ar, this message translates to:
  /// **'أعلى قوائم العمليات والتقارير تجد مُحدِّد الفترة: اليوم، الأسبوع، الشهر، السنة، أو مدى مخصص. كل الأرقام في الشاشة تتبع الفترة المختارة.'**
  String get helpPeriodBody;

  /// No description provided for @helpAnnualTitle.
  ///
  /// In ar, this message translates to:
  /// **'التقرير السنوي'**
  String get helpAnnualTitle;

  /// No description provided for @helpAnnualBody.
  ///
  /// In ar, this message translates to:
  /// **'اختر «هذه السنة» أو «السنة الماضية» من مُحدِّد الفترة لتقرأ سلوكك المالي على مدار سنة كاملة: الإجمالي، التصنيفات، الاتجاهات، وأكثر المتاجر إنفاقًا.'**
  String get helpAnnualBody;

  /// No description provided for @helpAccountsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الحسابات والبطاقات'**
  String get helpAccountsTitle;

  /// No description provided for @helpAccountsBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف حسابًا لكل محفظة أو بنك، ولكل حساب عملته الخاصة. تظهر البطاقات تلقائيًا من رسائل البنك، ويمكنك إضافتها يدويًا.'**
  String get helpAccountsBody;

  /// No description provided for @helpBudgetsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الميزانيات'**
  String get helpBudgetsTitle;

  /// No description provided for @helpBudgetsBody.
  ///
  /// In ar, this message translates to:
  /// **'حدد سقفًا لتصنيف أو لكل المصروفات، واختر دوريته. ينبّهك قِرش عند بلوغ 80% ثم عند التجاوز.'**
  String get helpBudgetsBody;

  /// No description provided for @helpGoalsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الأهداف'**
  String get helpGoalsTitle;

  /// No description provided for @helpGoalsBody.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ هدف ادخار بمبلغ وموعد، ثم أضف إليه مساهمات. يحسب قِرش المبلغ اليومي الموصى به ليبقى الهدف في مساره.'**
  String get helpGoalsBody;

  /// No description provided for @helpPrivacyTitle.
  ///
  /// In ar, this message translates to:
  /// **'تحكّمك في بياناتك'**
  String get helpPrivacyTitle;

  /// No description provided for @helpPrivacyBody.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك المالية محفوظة على جهازك ومشفّرة. من شاشة الخصوصية يمكنك التحكم في المعالجة السحابية والتحليل بالذكاء الاصطناعي، وسحب موافقتك في أي وقت.'**
  String get helpPrivacyBody;

  /// No description provided for @helpBackupTitle.
  ///
  /// In ar, this message translates to:
  /// **'النسخ الاحتياطي والاستعادة'**
  String get helpBackupTitle;

  /// No description provided for @helpBackupBody.
  ///
  /// In ar, this message translates to:
  /// **'صدّر نسخة مشفّرة من بياناتك واحتفظ بها، أو استعدها على جهاز آخر. تتم المعاينة على جهازك قبل أي كتابة، ولا تخرج كلمة المرور منه.'**
  String get helpBackupBody;

  /// No description provided for @helpFooter.
  ///
  /// In ar, this message translates to:
  /// **'لم تجد إجابتك؟ راسلنا من شاشة الإعدادات.'**
  String get helpFooter;

  /// No description provided for @coachMarkNext.
  ///
  /// In ar, this message translates to:
  /// **'التالي'**
  String get coachMarkNext;

  /// No description provided for @coachMarkDone.
  ///
  /// In ar, this message translates to:
  /// **'تمام'**
  String get coachMarkDone;

  /// No description provided for @coachMarkSkip.
  ///
  /// In ar, this message translates to:
  /// **'تخطّي'**
  String get coachMarkSkip;

  /// No description provided for @coachDashboardAddTitle.
  ///
  /// In ar, this message translates to:
  /// **'سجّل أول عملية'**
  String get coachDashboardAddTitle;

  /// No description provided for @coachDashboardAddBody.
  ///
  /// In ar, this message translates to:
  /// **'من زر الإضافة تسجّل عملية يدويًا أو تلصق نص رسالة البنك ليقرأها قِرش نيابةً عنك.'**
  String get coachDashboardAddBody;

  /// No description provided for @coachDashboardPeriodTitle.
  ///
  /// In ar, this message translates to:
  /// **'اختر الفترة'**
  String get coachDashboardPeriodTitle;

  /// No description provided for @coachDashboardPeriodBody.
  ///
  /// In ar, this message translates to:
  /// **'مُحدِّد الفترة يغيّر كل الأرقام في الشاشة: اليوم، الأسبوع، الشهر، السنة، أو مدى مخصص.'**
  String get coachDashboardPeriodBody;

  /// No description provided for @coachDashboardInboxTitle.
  ///
  /// In ar, this message translates to:
  /// **'صندوق الوارد الذكي'**
  String get coachDashboardInboxTitle;

  /// No description provided for @coachDashboardInboxBody.
  ///
  /// In ar, this message translates to:
  /// **'ما يلتقطه قِرش من رسائل البنك ينتظرك هنا للمراجعة قبل أن يدخل سجلك.'**
  String get coachDashboardInboxBody;

  /// No description provided for @coachDashboardHelpTitle.
  ///
  /// In ar, this message translates to:
  /// **'الدليل متاح دائمًا'**
  String get coachDashboardHelpTitle;

  /// No description provided for @coachDashboardHelpBody.
  ///
  /// In ar, this message translates to:
  /// **'تجد «كيف تستخدم قِرش» في الإعدادات في أي وقت، ويمكنك إعادة هذه الجولة من هناك.'**
  String get coachDashboardHelpBody;

  /// No description provided for @helpReplayTour.
  ///
  /// In ar, this message translates to:
  /// **'إعادة الجولة التعريفية'**
  String get helpReplayTour;

  /// No description provided for @helpReplayTourDone.
  ///
  /// In ar, this message translates to:
  /// **'ستظهر الجولة التعريفية من جديد.'**
  String get helpReplayTourDone;

  /// No description provided for @setLoadingCountries.
  ///
  /// In ar, this message translates to:
  /// **'تحميل الدول...'**
  String get setLoadingCountries;

  /// No description provided for @setLoadingCurrencies.
  ///
  /// In ar, this message translates to:
  /// **'تحميل العملات...'**
  String get setLoadingCurrencies;

  /// No description provided for @setCountry.
  ///
  /// In ar, this message translates to:
  /// **'الدولة'**
  String get setCountry;

  /// No description provided for @setBaseCurrency.
  ///
  /// In ar, this message translates to:
  /// **'العملة الأساسية'**
  String get setBaseCurrency;

  /// No description provided for @setName.
  ///
  /// In ar, this message translates to:
  /// **'الاسم'**
  String get setName;

  /// No description provided for @setNameInApp.
  ///
  /// In ar, this message translates to:
  /// **'اسمك في التطبيق'**
  String get setNameInApp;

  /// No description provided for @setAccountData.
  ///
  /// In ar, this message translates to:
  /// **'بيانات حسابك'**
  String get setAccountData;

  /// No description provided for @setMobileNumber.
  ///
  /// In ar, this message translates to:
  /// **'رقم الموبايل'**
  String get setMobileNumber;

  /// No description provided for @setAddYourNumber.
  ///
  /// In ar, this message translates to:
  /// **'أضف رقمك'**
  String get setAddYourNumber;

  /// No description provided for @setAppearance.
  ///
  /// In ar, this message translates to:
  /// **'المظهر'**
  String get setAppearance;

  /// No description provided for @setAppearanceSub.
  ///
  /// In ar, this message translates to:
  /// **'فاتح، داكن، أو حسب النظام'**
  String get setAppearanceSub;

  /// No description provided for @setAccountsAndDues.
  ///
  /// In ar, this message translates to:
  /// **'حساباتك والتزاماتك'**
  String get setAccountsAndDues;

  /// No description provided for @setSyncConflicts.
  ///
  /// In ar, this message translates to:
  /// **'تعارضات المزامنة'**
  String get setSyncConflicts;

  /// No description provided for @setSyncConflictsSub.
  ///
  /// In ar, this message translates to:
  /// **'عناصر عُدّلت على أكثر من جهاز — بحاجة لقرارك'**
  String get setSyncConflictsSub;

  /// No description provided for @setAccountsWallets.
  ///
  /// In ar, this message translates to:
  /// **'الحسابات والمحافظ'**
  String get setAccountsWallets;

  /// No description provided for @setAccountsWalletsSub.
  ///
  /// In ar, this message translates to:
  /// **'حسابات متعددة، كل واحد بعملته الخاصة'**
  String get setAccountsWalletsSub;

  /// No description provided for @setAllCards.
  ///
  /// In ar, this message translates to:
  /// **'كل البطاقات'**
  String get setAllCards;

  /// No description provided for @setAllCardsSub.
  ///
  /// In ar, this message translates to:
  /// **'نظرة عامة على بطاقاتك مجمّعة حسب الحساب'**
  String get setAllCardsSub;

  /// No description provided for @setSubsAndBills.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات والفواتير'**
  String get setSubsAndBills;

  /// No description provided for @setSubsAndBillsSub.
  ///
  /// In ar, this message translates to:
  /// **'التزاماتك الدورية ومواعيد السداد'**
  String get setSubsAndBillsSub;

  /// No description provided for @setPlans.
  ///
  /// In ar, this message translates to:
  /// **'الخطط'**
  String get setPlans;

  /// No description provided for @setPlansSub.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية رحلة أو مناسبة تتابع نفسها'**
  String get setPlansSub;

  /// No description provided for @setToolsAndSettings.
  ///
  /// In ar, this message translates to:
  /// **'أدوات وإعدادات'**
  String get setToolsAndSettings;

  /// No description provided for @setCategories.
  ///
  /// In ar, this message translates to:
  /// **'التصنيفات'**
  String get setCategories;

  /// No description provided for @setCategoriesSub.
  ///
  /// In ar, this message translates to:
  /// **'نظم المصروفات والدخل والتحويلات'**
  String get setCategoriesSub;

  /// No description provided for @setAchievements.
  ///
  /// In ar, this message translates to:
  /// **'الإنجازات والمستوى'**
  String get setAchievements;

  /// No description provided for @setAchievementsSub.
  ///
  /// In ar, this message translates to:
  /// **'شارات ومستويات تشجع عادة المتابعة'**
  String get setAchievementsSub;

  /// No description provided for @setCurrencyRepair.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد عملة الميزانيات والأهداف'**
  String get setCurrencyRepair;

  /// No description provided for @setCurrencyRepairSub.
  ///
  /// In ar, this message translates to:
  /// **'راجع عملة بيانات التخطيط القديمة بأمان'**
  String get setCurrencyRepairSub;

  /// No description provided for @setAppleShortcut.
  ///
  /// In ar, this message translates to:
  /// **'اختصار آبل'**
  String get setAppleShortcut;

  /// No description provided for @setAppleShortcutSub.
  ///
  /// In ar, this message translates to:
  /// **'مرر رسائل البنك إلى قرش عبر Shortcuts'**
  String get setAppleShortcutSub;

  /// No description provided for @setRewardsAndSupport.
  ///
  /// In ar, this message translates to:
  /// **'المكافآت والدعم'**
  String get setRewardsAndSupport;

  /// No description provided for @setInviteFriends.
  ///
  /// In ar, this message translates to:
  /// **'دعوة الأصدقاء'**
  String get setInviteFriends;

  /// No description provided for @setInviteFriendsSub.
  ///
  /// In ar, this message translates to:
  /// **'شارك رمز دعوتك واكسب تقارير بدون إعلانات'**
  String get setInviteFriendsSub;

  /// No description provided for @setAdPrivacyOptions.
  ///
  /// In ar, this message translates to:
  /// **'خيارات خصوصية الإعلانات'**
  String get setAdPrivacyOptions;

  /// No description provided for @setAdPrivacyOptionsSub.
  ///
  /// In ar, this message translates to:
  /// **'إدارة موافقتك على الإعلانات'**
  String get setAdPrivacyOptionsSub;

  /// No description provided for @setContactUs.
  ///
  /// In ar, this message translates to:
  /// **'تواصل معنا'**
  String get setContactUs;

  /// No description provided for @setContactUsSub.
  ///
  /// In ar, this message translates to:
  /// **'الدعم الفني والإجابة على استفساراتك'**
  String get setContactUsSub;

  /// No description provided for @setAboutQirsh.
  ///
  /// In ar, this message translates to:
  /// **'عن قرش'**
  String get setAboutQirsh;

  /// No description provided for @setAboutQirshSub.
  ///
  /// In ar, this message translates to:
  /// **'معلومات التطبيق والإصدار'**
  String get setAboutQirshSub;

  /// No description provided for @setCaptureStatus.
  ///
  /// In ar, this message translates to:
  /// **'رصد العمليات'**
  String get setCaptureStatus;

  /// No description provided for @setCaptureStatusSub.
  ///
  /// In ar, this message translates to:
  /// **'حالة الربط مع رسائل البنك واختصار آبل'**
  String get setCaptureStatusSub;

  /// No description provided for @setConfirmCaptured.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد العمليات الملتقطة'**
  String get setConfirmCaptured;

  /// No description provided for @setNotifyOnCapture.
  ///
  /// In ar, this message translates to:
  /// **'إشعار عند التقاط عملية'**
  String get setNotifyOnCapture;

  /// No description provided for @setHideOnLockScreen.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء التفاصيل الحساسة على شاشة القفل'**
  String get setHideOnLockScreen;

  /// No description provided for @setYourAlerts.
  ///
  /// In ar, this message translates to:
  /// **'تنبيهاتك'**
  String get setYourAlerts;

  /// No description provided for @setQirshMessages.
  ///
  /// In ar, this message translates to:
  /// **'رسائل ونصائح قرش'**
  String get setQirshMessages;

  /// No description provided for @setBudget80Alert.
  ///
  /// In ar, this message translates to:
  /// **'تنبيه 80% من الميزانية'**
  String get setBudget80Alert;

  /// No description provided for @setBudgetOverAlert.
  ///
  /// In ar, this message translates to:
  /// **'تنبيه تجاوز الميزانية'**
  String get setBudgetOverAlert;

  /// No description provided for @setDailyReminder.
  ///
  /// In ar, this message translates to:
  /// **'التذكير اليومي'**
  String get setDailyReminder;

  /// No description provided for @setDailyReminderTime.
  ///
  /// In ar, this message translates to:
  /// **'كل يوم الساعة 10 مساءً'**
  String get setDailyReminderTime;

  /// No description provided for @setWeeklyReport.
  ///
  /// In ar, this message translates to:
  /// **'التقرير الأسبوعي'**
  String get setWeeklyReport;

  /// No description provided for @setBillReminders.
  ///
  /// In ar, this message translates to:
  /// **'تذكير الاشتراكات والفواتير'**
  String get setBillReminders;

  /// No description provided for @setGoalCelebrations.
  ///
  /// In ar, this message translates to:
  /// **'احتفالات الأهداف'**
  String get setGoalCelebrations;

  /// No description provided for @setAchievementAlerts.
  ///
  /// In ar, this message translates to:
  /// **'تنبيهات الإنجازات'**
  String get setAchievementAlerts;

  /// No description provided for @setQuietHours.
  ///
  /// In ar, this message translates to:
  /// **'ساعات الهدوء'**
  String get setQuietHours;

  /// No description provided for @setDisabled.
  ///
  /// In ar, this message translates to:
  /// **'معطّل'**
  String get setDisabled;

  /// No description provided for @setEditQuietHours.
  ///
  /// In ar, this message translates to:
  /// **'تعديل وقت الهدوء'**
  String get setEditQuietHours;

  /// No description provided for @setNotificationTools.
  ///
  /// In ar, this message translates to:
  /// **'أدوات الإشعارات'**
  String get setNotificationTools;

  /// No description provided for @setTestNotifications.
  ///
  /// In ar, this message translates to:
  /// **'اختبار إشعارات قرش'**
  String get setTestNotifications;

  /// No description provided for @setTestNotificationsSub.
  ///
  /// In ar, this message translates to:
  /// **'أرسل إشعارًا تجريبيًا إلى هذا الجهاز'**
  String get setTestNotificationsSub;

  /// No description provided for @setMessageCentre.
  ///
  /// In ar, this message translates to:
  /// **'مركز رسائل قرش'**
  String get setMessageCentre;

  /// No description provided for @setMessageCentreSub.
  ///
  /// In ar, this message translates to:
  /// **'الإشعارات والحملات والإعلانات السابقة'**
  String get setMessageCentreSub;

  /// No description provided for @setDataTransfer.
  ///
  /// In ar, this message translates to:
  /// **'نقل البيانات'**
  String get setDataTransfer;

  /// No description provided for @setDataTransferSub.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك المالية تظل تحت سيطرتك'**
  String get setDataTransferSub;

  /// No description provided for @setImportFile.
  ///
  /// In ar, this message translates to:
  /// **'استيراد ملف'**
  String get setImportFile;

  /// No description provided for @setImportFileSub.
  ///
  /// In ar, this message translates to:
  /// **'CSV من أي تطبيق أو ZIP صادر من قرش'**
  String get setImportFileSub;

  /// No description provided for @setExportCsv.
  ///
  /// In ar, this message translates to:
  /// **'تصدير العمليات CSV'**
  String get setExportCsv;

  /// No description provided for @setExportCsvSub.
  ///
  /// In ar, this message translates to:
  /// **'ملف بسيط لكل عملياتك'**
  String get setExportCsvSub;

  /// No description provided for @setExportAll.
  ///
  /// In ar, this message translates to:
  /// **'تصدير كل بيانات قرش'**
  String get setExportAll;

  /// No description provided for @setExportAllSub.
  ///
  /// In ar, this message translates to:
  /// **'حزمة ZIP قابلة للنقل والاستعادة'**
  String get setExportAllSub;

  /// No description provided for @setSecurityPrivacy.
  ///
  /// In ar, this message translates to:
  /// **'الأمان والخصوصية'**
  String get setSecurityPrivacy;

  /// No description provided for @setEncryptedDbPart1.
  ///
  /// In ar, this message translates to:
  /// **'بياناتك على الجهاز مخزّنة بقاعدة بيانات مشفّرة، '**
  String get setEncryptedDbPart1;

  /// No description provided for @setEncryptedDbPart2.
  ///
  /// In ar, this message translates to:
  /// **'ومفتاحها محفوظ في خزنة النظام'**
  String get setEncryptedDbPart2;

  /// No description provided for @setPrivacyAndData.
  ///
  /// In ar, this message translates to:
  /// **'الخصوصية والبيانات'**
  String get setPrivacyAndData;

  /// No description provided for @setPrivacyAndDataSub.
  ///
  /// In ar, this message translates to:
  /// **'أمان بياناتك وسياسة الخصوصية'**
  String get setPrivacyAndDataSub;

  /// No description provided for @setHideAmounts.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء الأرقام في الواجهة'**
  String get setHideAmounts;

  /// No description provided for @setExitAndErase.
  ///
  /// In ar, this message translates to:
  /// **'الخروج وحذف البيانات'**
  String get setExitAndErase;

  /// No description provided for @setExitAndEraseSub.
  ///
  /// In ar, this message translates to:
  /// **'إجراءات لا يمكن التراجع عن بعضها'**
  String get setExitAndEraseSub;

  /// No description provided for @setStartOver.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ من جديد'**
  String get setStartOver;

  /// No description provided for @setStartOverSub.
  ///
  /// In ar, this message translates to:
  /// **'امسح البيانات المحلية مع إبقاء الحساب نشطًا'**
  String get setStartOverSub;

  /// No description provided for @setSignOut.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج'**
  String get setSignOut;

  /// No description provided for @setDeleteAccount.
  ///
  /// In ar, this message translates to:
  /// **'حذف الحساب وكل بياناتي'**
  String get setDeleteAccount;

  /// No description provided for @setDeleteAccountSub.
  ///
  /// In ar, this message translates to:
  /// **'إجراء نهائي يتطلب تأكيدك'**
  String get setDeleteAccountSub;

  /// No description provided for @setTestNotificationSent.
  ///
  /// In ar, this message translates to:
  /// **'أرسلنا إشعاراً تجريبياً من قرش.'**
  String get setTestNotificationSent;

  /// No description provided for @setTestNotificationFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر إرسال الإشعار التجريبي.'**
  String get setTestNotificationFailed;

  /// No description provided for @setUnsyncedData.
  ///
  /// In ar, this message translates to:
  /// **'بيانات غير محفوظة سحابيًا'**
  String get setUnsyncedData;

  /// No description provided for @setCancel.
  ///
  /// In ar, this message translates to:
  /// **'إلغاء'**
  String get setCancel;

  /// No description provided for @setSignOutDiscard.
  ///
  /// In ar, this message translates to:
  /// **'تسجيل الخروج وحذف غير المحفوظ'**
  String get setSignOutDiscard;

  /// No description provided for @setUnsyncedCheckFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر التحقق من البيانات غير المحفوظة. حاول مجدداً.'**
  String get setUnsyncedCheckFailed;

  /// No description provided for @setSignOutFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تسجيل الخروج بأمان. حاول مجدداً.'**
  String get setSignOutFailed;

  /// No description provided for @setPhotoUpdated.
  ///
  /// In ar, this message translates to:
  /// **'تم تحديث الصورة.'**
  String get setPhotoUpdated;

  /// No description provided for @setSave.
  ///
  /// In ar, this message translates to:
  /// **'حفظ'**
  String get setSave;

  /// No description provided for @setCategoriesSheetIntro.
  ///
  /// In ar, this message translates to:
  /// **'أضف أو عدّل التصنيفات التي تظهر في العمليات والتقارير.'**
  String get setCategoriesSheetIntro;

  /// No description provided for @setAddCategory.
  ///
  /// In ar, this message translates to:
  /// **'إضافة تصنيف'**
  String get setAddCategory;

  /// No description provided for @setExpenses.
  ///
  /// In ar, this message translates to:
  /// **'مصروفات'**
  String get setExpenses;

  /// No description provided for @setIncome.
  ///
  /// In ar, this message translates to:
  /// **'دخل'**
  String get setIncome;

  /// No description provided for @setTransfers.
  ///
  /// In ar, this message translates to:
  /// **'تحويلات'**
  String get setTransfers;

  /// No description provided for @setEditCategory.
  ///
  /// In ar, this message translates to:
  /// **'تعديل تصنيف'**
  String get setEditCategory;

  /// No description provided for @setCategoryName.
  ///
  /// In ar, this message translates to:
  /// **'اسم التصنيف'**
  String get setCategoryName;

  /// No description provided for @setIncomeCategory.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف دخل'**
  String get setIncomeCategory;

  /// No description provided for @setIcon.
  ///
  /// In ar, this message translates to:
  /// **'الأيقونة'**
  String get setIcon;

  /// No description provided for @setColor.
  ///
  /// In ar, this message translates to:
  /// **'اللون'**
  String get setColor;

  /// No description provided for @setEnterCategoryName.
  ///
  /// In ar, this message translates to:
  /// **'اكتب اسم التصنيف.'**
  String get setEnterCategoryName;

  /// No description provided for @setSaveChanges.
  ///
  /// In ar, this message translates to:
  /// **'حفظ التعديلات'**
  String get setSaveChanges;

  /// No description provided for @setAdd.
  ///
  /// In ar, this message translates to:
  /// **'إضافة'**
  String get setAdd;

  /// No description provided for @setDeleteCategoryQ.
  ///
  /// In ar, this message translates to:
  /// **'حذف التصنيف؟'**
  String get setDeleteCategoryQ;

  /// No description provided for @setDeleteCategoryBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم نقل عملياته إلى «أخرى» أو «دخل»، وحذف أي ميزانية مرتبطة به.'**
  String get setDeleteCategoryBody;

  /// No description provided for @setDelete.
  ///
  /// In ar, this message translates to:
  /// **'حذف'**
  String get setDelete;

  /// No description provided for @setQuietHoursNote.
  ///
  /// In ar, this message translates to:
  /// **'نؤجل الإشعارات المجدولة خلال هذه الفترة لأول وقت مسموح.'**
  String get setQuietHoursNote;

  /// No description provided for @setStarts.
  ///
  /// In ar, this message translates to:
  /// **'تبدأ'**
  String get setStarts;

  /// No description provided for @setEnds.
  ///
  /// In ar, this message translates to:
  /// **'تنتهي'**
  String get setEnds;

  /// No description provided for @setAboutApp.
  ///
  /// In ar, this message translates to:
  /// **'عن التطبيق'**
  String get setAboutApp;

  /// No description provided for @setAboutBody.
  ///
  /// In ar, this message translates to:
  /// **'قرش لتتبع المصروفات من رسائل البنك والإدخال اليدوي. يمكنك نقل بياناتك المالية كملفات CSV أو حزمة ZIP من قسم البيانات والخصوصية.'**
  String get setAboutBody;

  /// No description provided for @setOk.
  ///
  /// In ar, this message translates to:
  /// **'تمام'**
  String get setOk;

  /// No description provided for @setSupportBody.
  ///
  /// In ar, this message translates to:
  /// **'للدعم أو الملاحظات انسخ البريد وأرسل لنا تفاصيل المشكلة، نوع الجهاز، وخطوات تكرارها.'**
  String get setSupportBody;

  /// No description provided for @setCopyEmail.
  ///
  /// In ar, this message translates to:
  /// **'نسخ البريد'**
  String get setCopyEmail;

  /// No description provided for @setEraseAllQ.
  ///
  /// In ar, this message translates to:
  /// **'مسح جميع البيانات؟'**
  String get setEraseAllQ;

  /// No description provided for @setEraseAllBody.
  ///
  /// In ar, this message translates to:
  /// **'سيتم مسح جميع بياناتك المحلية. لا يمكن التراجع.'**
  String get setEraseAllBody;

  /// No description provided for @setErase.
  ///
  /// In ar, this message translates to:
  /// **'مسح'**
  String get setErase;

  /// No description provided for @setSettingsLoadFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تحميل الإعدادات. حاول مرة أخرى بعد قليل.'**
  String get setSettingsLoadFailed;

  /// No description provided for @setSettings.
  ///
  /// In ar, this message translates to:
  /// **'الإعدادات'**
  String get setSettings;

  /// No description provided for @setBack.
  ///
  /// In ar, this message translates to:
  /// **'رجوع'**
  String get setBack;

  /// No description provided for @setThemeAuto.
  ///
  /// In ar, this message translates to:
  /// **'تلقائي'**
  String get setThemeAuto;

  /// No description provided for @setThemeLight.
  ///
  /// In ar, this message translates to:
  /// **'فاتح'**
  String get setThemeLight;

  /// No description provided for @setThemeDark.
  ///
  /// In ar, this message translates to:
  /// **'داكن'**
  String get setThemeDark;

  /// No description provided for @setEdit.
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get setEdit;

  /// No description provided for @setAppLockFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذر تفعيل القفل. تأكد من إعداد بصمة أو رمز للجهاز.'**
  String get setAppLockFailed;

  /// No description provided for @setAppLock.
  ///
  /// In ar, this message translates to:
  /// **'قفل التطبيق'**
  String get setAppLock;

  /// No description provided for @setNoBankMessageYet.
  ///
  /// In ar, this message translates to:
  /// **'لم نرصد أي رسالة بنكية بعد'**
  String get setNoBankMessageYet;

  /// No description provided for @setCaptureEnableFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر تفعيل إشعارات رصد البنك'**
  String get setCaptureEnableFailed;

  /// No description provided for @setNoBankMessagesRecently.
  ///
  /// In ar, this message translates to:
  /// **'لم نستقبل رسائل بنكية منذ فترة'**
  String get setNoBankMessagesRecently;

  /// No description provided for @setBankCaptureStatus.
  ///
  /// In ar, this message translates to:
  /// **'حالة رصد رسائل البنك'**
  String get setBankCaptureStatus;

  /// No description provided for @setCheck.
  ///
  /// In ar, this message translates to:
  /// **'تحقق'**
  String get setCheck;

  /// No description provided for @setBackupFirst.
  ///
  /// In ar, this message translates to:
  /// **'خُذ نسخة احتياطية أولًا إن أردت الاحتفاظ بها.'**
  String get setBackupFirst;

  /// No description provided for @setToday.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get setToday;

  /// No description provided for @bdgError.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ'**
  String get bdgError;

  /// No description provided for @bdgTabBudgets.
  ///
  /// In ar, this message translates to:
  /// **'الميزانيات'**
  String get bdgTabBudgets;

  /// No description provided for @bdgTabHistory.
  ///
  /// In ar, this message translates to:
  /// **'سجل الميزانيات'**
  String get bdgTabHistory;

  /// No description provided for @bdgTabGoals.
  ///
  /// In ar, this message translates to:
  /// **'الأهداف'**
  String get bdgTabGoals;

  /// No description provided for @bdgEmptyBudgetsTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد ميزانيات'**
  String get bdgEmptyBudgetsTitle;

  /// No description provided for @bdgEmptyBudgetsBody.
  ///
  /// In ar, this message translates to:
  /// **'أنشئ أول ميزانية يومية أو أسبوعية أو شهرية لتبدأ المتابعة.'**
  String get bdgEmptyBudgetsBody;

  /// No description provided for @bdgEmptyGoalsTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد أهداف'**
  String get bdgEmptyGoalsTitle;

  /// No description provided for @bdgEmptyGoalsBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف هدف ادخار ليتابع قِرش تقدمك إلى جانب ميزانياتك.'**
  String get bdgEmptyGoalsBody;

  /// No description provided for @bdgAddGoal.
  ///
  /// In ar, this message translates to:
  /// **'إضافة هدف'**
  String get bdgAddGoal;

  /// No description provided for @bdgEmptyHistoryTitle.
  ///
  /// In ar, this message translates to:
  /// **'السجل فارغ'**
  String get bdgEmptyHistoryTitle;

  /// No description provided for @bdgEmptyHistoryBody.
  ///
  /// In ar, this message translates to:
  /// **'اختر فترة تحتوي على ميزانيات أو أضف ميزانية جديدة، وسيظهر كل يوم/أسبوع/شهر هنا كسجلّ منفصل.'**
  String get bdgEmptyHistoryBody;

  /// No description provided for @bdgAddBudget.
  ///
  /// In ar, this message translates to:
  /// **'إضافة ميزانية'**
  String get bdgAddBudget;

  /// No description provided for @bdgDeleteTitle.
  ///
  /// In ar, this message translates to:
  /// **'حذف الميزانية؟'**
  String get bdgDeleteTitle;

  /// No description provided for @bdgDeleteBody.
  ///
  /// In ar, this message translates to:
  /// **'سيُحذف سقف الميزانية. لن تتأثر العمليات نفسها.'**
  String get bdgDeleteBody;

  /// No description provided for @bdgDeleteFailed.
  ///
  /// In ar, this message translates to:
  /// **'تعذّر حذف الميزانية الآن.'**
  String get bdgDeleteFailed;

  /// No description provided for @bdgFilterAll.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get bdgFilterAll;

  /// No description provided for @bdgFilterDaily.
  ///
  /// In ar, this message translates to:
  /// **'يومي'**
  String get bdgFilterDaily;

  /// No description provided for @bdgFilterWeekly.
  ///
  /// In ar, this message translates to:
  /// **'أسبوعي'**
  String get bdgFilterWeekly;

  /// No description provided for @bdgFilterMonthly.
  ///
  /// In ar, this message translates to:
  /// **'شهري'**
  String get bdgFilterMonthly;

  /// No description provided for @bdgFilterYearly.
  ///
  /// In ar, this message translates to:
  /// **'سنوي'**
  String get bdgFilterYearly;

  /// No description provided for @bdgStatHistoryCount.
  ///
  /// In ar, this message translates to:
  /// **'ميزانيات في السجل'**
  String get bdgStatHistoryCount;

  /// No description provided for @bdgStatTargetSavings.
  ///
  /// In ar, this message translates to:
  /// **'مجموع المدخرات المستهدفة'**
  String get bdgStatTargetSavings;

  /// No description provided for @bdgStatTotalBudgeted.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الميزانيات المرصودة'**
  String get bdgStatTotalBudgeted;

  /// No description provided for @bdgStatActiveGoals.
  ///
  /// In ar, this message translates to:
  /// **'أهداف نشطة'**
  String get bdgStatActiveGoals;

  /// No description provided for @bdgStatProgress.
  ///
  /// In ar, this message translates to:
  /// **'نسبة التقدم'**
  String get bdgStatProgress;

  /// No description provided for @bdgStatTotalSaved.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الادخار'**
  String get bdgStatTotalSaved;

  /// No description provided for @bdgStateSafeF.
  ///
  /// In ar, this message translates to:
  /// **'آمنة'**
  String get bdgStateSafeF;

  /// No description provided for @bdgStateNear.
  ///
  /// In ar, this message translates to:
  /// **'اقتربت'**
  String get bdgStateNear;

  /// No description provided for @bdgStateOverF.
  ///
  /// In ar, this message translates to:
  /// **'تجاوزت'**
  String get bdgStateOverF;

  /// No description provided for @bdgBudgetsWord.
  ///
  /// In ar, this message translates to:
  /// **'ميزانيات'**
  String get bdgBudgetsWord;

  /// No description provided for @bdgUsageRate.
  ///
  /// In ar, this message translates to:
  /// **'نسبة الاستهلاك'**
  String get bdgUsageRate;

  /// No description provided for @bdgActualSpend.
  ///
  /// In ar, this message translates to:
  /// **'المصروف الفعلي'**
  String get bdgActualSpend;

  /// No description provided for @bdgBudgetWord.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية'**
  String get bdgBudgetWord;

  /// No description provided for @bdgOver.
  ///
  /// In ar, this message translates to:
  /// **'تجاوز'**
  String get bdgOver;

  /// No description provided for @bdgSafe.
  ///
  /// In ar, this message translates to:
  /// **'آمن'**
  String get bdgSafe;

  /// No description provided for @bdgAllExpenses.
  ///
  /// In ar, this message translates to:
  /// **'كل المصروفات'**
  String get bdgAllExpenses;

  /// No description provided for @bdgCategory.
  ///
  /// In ar, this message translates to:
  /// **'تصنيف'**
  String get bdgCategory;

  /// No description provided for @bdgSpent.
  ///
  /// In ar, this message translates to:
  /// **'مصروف'**
  String get bdgSpent;

  /// No description provided for @bdgRemaining.
  ///
  /// In ar, this message translates to:
  /// **'باقي'**
  String get bdgRemaining;

  /// No description provided for @bdgLimit.
  ///
  /// In ar, this message translates to:
  /// **'الحد'**
  String get bdgLimit;

  /// No description provided for @bdgSaved.
  ///
  /// In ar, this message translates to:
  /// **'وفّرت'**
  String get bdgSaved;

  /// No description provided for @bdgPeriodCurrent.
  ///
  /// In ar, this message translates to:
  /// **'الفترة الحالية'**
  String get bdgPeriodCurrent;

  /// No description provided for @bdgPeriodOver.
  ///
  /// In ar, this message translates to:
  /// **'فترة تجاوزت الحد'**
  String get bdgPeriodOver;

  /// No description provided for @bdgPeriodEnded.
  ///
  /// In ar, this message translates to:
  /// **'فترة منتهية'**
  String get bdgPeriodEnded;

  /// No description provided for @bdgRecordLive.
  ///
  /// In ar, this message translates to:
  /// **'ما زال هذا السجل يُحدَّث حتى نهاية الفترة.'**
  String get bdgRecordLive;

  /// No description provided for @bdgRecordFinal.
  ///
  /// In ar, this message translates to:
  /// **'هذا السجل محسوب من العمليات الفعلية داخل هذه الفترة.'**
  String get bdgRecordFinal;

  /// No description provided for @bdgEditBudget.
  ///
  /// In ar, this message translates to:
  /// **'تعديل الميزانية'**
  String get bdgEditBudget;

  /// No description provided for @bdgPeriodTransactions.
  ///
  /// In ar, this message translates to:
  /// **'عمليات الفترة'**
  String get bdgPeriodTransactions;

  /// No description provided for @bdgNoConfirmedTx.
  ///
  /// In ar, this message translates to:
  /// **'لم تُسجَّل عمليات مؤكدة ضمن هذه الفترة.'**
  String get bdgNoConfirmedTx;

  /// No description provided for @bdgCountedOpenAll.
  ///
  /// In ar, this message translates to:
  /// **'داخلة في الحساب — افتح «العمليات» لعرضها كلها.'**
  String get bdgCountedOpenAll;

  /// No description provided for @bdgDailyBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية يومية'**
  String get bdgDailyBudget;

  /// No description provided for @bdgWeeklyBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية أسبوعية'**
  String get bdgWeeklyBudget;

  /// No description provided for @bdgYearlyBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية سنوية'**
  String get bdgYearlyBudget;

  /// No description provided for @bdgMonthlyBudget.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية شهرية'**
  String get bdgMonthlyBudget;

  /// No description provided for @bdgTransactionWord.
  ///
  /// In ar, this message translates to:
  /// **'عملية'**
  String get bdgTransactionWord;

  /// No description provided for @bdgGoalDone.
  ///
  /// In ar, this message translates to:
  /// **'اكتمل الهدف'**
  String get bdgGoalDone;

  /// No description provided for @bdgEnvelopeTitle.
  ///
  /// In ar, this message translates to:
  /// **'وزّع دخلك على المظاريف'**
  String get bdgEnvelopeTitle;

  /// No description provided for @bdgEnvelopeBody.
  ///
  /// In ar, this message translates to:
  /// **'اكتب راتبك ووزّعه بضغطة — و«قِرش» يحسب لك المتاح كل يوم'**
  String get bdgEnvelopeBody;

  /// No description provided for @bdgMoreTxCounted.
  ///
  /// In ar, this message translates to:
  /// **'باقي {count} عملية داخلة في الحساب — افتح «العمليات» لعرضها كلها.'**
  String bdgMoreTxCounted(int count);

  /// No description provided for @txnError.
  ///
  /// In ar, this message translates to:
  /// **'حدث خطأ'**
  String get txnError;

  /// No description provided for @txnTransactionWord.
  ///
  /// In ar, this message translates to:
  /// **'عملية'**
  String get txnTransactionWord;

  /// No description provided for @txnFilterPending.
  ///
  /// In ar, this message translates to:
  /// **'تصفية: قيد المراجعة'**
  String get txnFilterPending;

  /// No description provided for @txnConfirmAll.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد الكل'**
  String get txnConfirmAll;

  /// No description provided for @txnTabTransactions.
  ///
  /// In ar, this message translates to:
  /// **'العمليات'**
  String get txnTabTransactions;

  /// No description provided for @txnTabBills.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير'**
  String get txnTabBills;

  /// No description provided for @txnEmptyPeriodTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات في هذه الفترة'**
  String get txnEmptyPeriodTitle;

  /// No description provided for @txnEmptyPeriodBody.
  ///
  /// In ar, this message translates to:
  /// **'غيّر الفترة أو أضف رسالة بنك جديدة من زر +.'**
  String get txnEmptyPeriodBody;

  /// No description provided for @txnConfirmAllTitle.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد كل العمليات المعلّقة؟'**
  String get txnConfirmAllTitle;

  /// No description provided for @txnConfirm.
  ///
  /// In ar, this message translates to:
  /// **'تأكيد'**
  String get txnConfirm;

  /// No description provided for @txnPickAccount.
  ///
  /// In ar, this message translates to:
  /// **'اختر الحساب'**
  String get txnPickAccount;

  /// No description provided for @txnSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث باسم متجر، تصنيف، مبلغ أو عملة'**
  String get txnSearchHint;

  /// No description provided for @txnClearSearch.
  ///
  /// In ar, this message translates to:
  /// **'مسح البحث'**
  String get txnClearSearch;

  /// No description provided for @txnRangeToday.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get txnRangeToday;

  /// No description provided for @txnRangeThisWeek.
  ///
  /// In ar, this message translates to:
  /// **'هذا الأسبوع'**
  String get txnRangeThisWeek;

  /// No description provided for @txnRangeThisMonth.
  ///
  /// In ar, this message translates to:
  /// **'هذا الشهر'**
  String get txnRangeThisMonth;

  /// No description provided for @txnRangeLastMonth.
  ///
  /// In ar, this message translates to:
  /// **'الشهر السابق'**
  String get txnRangeLastMonth;

  /// No description provided for @txnRange7.
  ///
  /// In ar, this message translates to:
  /// **'آخر 7 أيام'**
  String get txnRange7;

  /// No description provided for @txnRange30.
  ///
  /// In ar, this message translates to:
  /// **'آخر 30 يومًا'**
  String get txnRange30;

  /// No description provided for @txnRange90.
  ///
  /// In ar, this message translates to:
  /// **'آخر 90 يومًا'**
  String get txnRange90;

  /// No description provided for @txnRangeThisYear.
  ///
  /// In ar, this message translates to:
  /// **'هذه السنة'**
  String get txnRangeThisYear;

  /// No description provided for @txnRangeLastYear.
  ///
  /// In ar, this message translates to:
  /// **'السنة الماضية'**
  String get txnRangeLastYear;

  /// No description provided for @txnRangeCustom.
  ///
  /// In ar, this message translates to:
  /// **'مخصص'**
  String get txnRangeCustom;

  /// No description provided for @txnPickRange.
  ///
  /// In ar, this message translates to:
  /// **'اختر فترة العرض'**
  String get txnPickRange;

  /// No description provided for @txnFrom.
  ///
  /// In ar, this message translates to:
  /// **'من'**
  String get txnFrom;

  /// No description provided for @txnTo.
  ///
  /// In ar, this message translates to:
  /// **'إلى'**
  String get txnTo;

  /// No description provided for @txnApplyCustomRange.
  ///
  /// In ar, this message translates to:
  /// **'تطبيق الفترة المخصصة'**
  String get txnApplyCustomRange;

  /// No description provided for @txnKindAll.
  ///
  /// In ar, this message translates to:
  /// **'الكل'**
  String get txnKindAll;

  /// No description provided for @txnKindExpense.
  ///
  /// In ar, this message translates to:
  /// **'مصروفات'**
  String get txnKindExpense;

  /// No description provided for @txnKindIncome.
  ///
  /// In ar, this message translates to:
  /// **'دخل'**
  String get txnKindIncome;

  /// No description provided for @txnKindTransfer.
  ///
  /// In ar, this message translates to:
  /// **'تحويلات'**
  String get txnKindTransfer;

  /// No description provided for @txnPendingReview.
  ///
  /// In ar, this message translates to:
  /// **'قيد المراجعة'**
  String get txnPendingReview;

  /// No description provided for @txnCategory.
  ///
  /// In ar, this message translates to:
  /// **'التصنيف'**
  String get txnCategory;

  /// No description provided for @txnFilterByCategory.
  ///
  /// In ar, this message translates to:
  /// **'تصفية حسب التصنيف'**
  String get txnFilterByCategory;

  /// No description provided for @txnAllCategories.
  ///
  /// In ar, this message translates to:
  /// **'كل التصنيفات'**
  String get txnAllCategories;

  /// No description provided for @txnBillsSubs.
  ///
  /// In ar, this message translates to:
  /// **'اشتراكات'**
  String get txnBillsSubs;

  /// No description provided for @txnBillsInstalments.
  ///
  /// In ar, this message translates to:
  /// **'أقساط'**
  String get txnBillsInstalments;

  /// No description provided for @txnAddSub.
  ///
  /// In ar, this message translates to:
  /// **'إضافة اشتراك'**
  String get txnAddSub;

  /// No description provided for @txnAddInstalment.
  ///
  /// In ar, this message translates to:
  /// **'إضافة قسط'**
  String get txnAddInstalment;

  /// No description provided for @txnLearnBills.
  ///
  /// In ar, this message translates to:
  /// **'اعرف أكثر عن الفواتير'**
  String get txnLearnBills;

  /// No description provided for @txnSubsEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'اشتراكاتك، متابعة تلقائية'**
  String get txnSubsEmptyTitle;

  /// No description provided for @txnInstEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'أقساطك، واضحة كل شهر'**
  String get txnInstEmptyTitle;

  /// No description provided for @txnSubsEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف اشتراكك يدويًا أو دعه يُكتشف تلقائيًا من العمليات المتكررة.'**
  String get txnSubsEmptyBody;

  /// No description provided for @txnInstEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف القسط بتاريخه وتنبيهه ليظهر في الفواتير قبل الاستحقاق.'**
  String get txnInstEmptyBody;

  /// No description provided for @txnSuggestionsTitle.
  ///
  /// In ar, this message translates to:
  /// **'اقتراحات من العمليات المتكررة'**
  String get txnSuggestionsTitle;

  /// No description provided for @txnHowSubsTitle.
  ///
  /// In ar, this message translates to:
  /// **'كيف يتابع قِرش الاشتراكات؟'**
  String get txnHowSubsTitle;

  /// No description provided for @txnHowInstTitle.
  ///
  /// In ar, this message translates to:
  /// **'كيف يتابع قِرش الأقساط؟'**
  String get txnHowInstTitle;

  /// No description provided for @txnHowSubsBody.
  ///
  /// In ar, this message translates to:
  /// **'يتابع قِرش الأنماط المتكررة تلقائيًا، ويمكنك أيضًا إضافة اشتراك يدويًا بالمبلغ وتاريخ التجديد والتنبيه.'**
  String get txnHowSubsBody;

  /// No description provided for @txnHowInstBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف القسط يدويًا بالمبلغ وتاريخ الاستحقاق والتنبيه. لاحقًا نضيف المتبقي وعدد الأقساط.'**
  String get txnHowInstBody;

  /// No description provided for @txnTotalMonthlySubs.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الاشتراكات الشهرية'**
  String get txnTotalMonthlySubs;

  /// No description provided for @txnTotalMonthlyInst.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الأقساط الشهرية'**
  String get txnTotalMonthlyInst;

  /// No description provided for @txnActive.
  ///
  /// In ar, this message translates to:
  /// **'نشط'**
  String get txnActive;

  /// No description provided for @txnPerYear.
  ///
  /// In ar, this message translates to:
  /// **'سنويًا'**
  String get txnPerYear;

  /// No description provided for @txnDueToday.
  ///
  /// In ar, this message translates to:
  /// **'مستحق اليوم'**
  String get txnDueToday;

  /// No description provided for @txnPaused.
  ///
  /// In ar, this message translates to:
  /// **'متوقف'**
  String get txnPaused;

  /// No description provided for @txnCancelled.
  ///
  /// In ar, this message translates to:
  /// **'ملغي'**
  String get txnCancelled;

  /// No description provided for @txnCycleWeekly.
  ///
  /// In ar, this message translates to:
  /// **'أسبوعي'**
  String get txnCycleWeekly;

  /// No description provided for @txnCycleMonthly.
  ///
  /// In ar, this message translates to:
  /// **'شهري'**
  String get txnCycleMonthly;

  /// No description provided for @txnCycleYearly.
  ///
  /// In ar, this message translates to:
  /// **'سنوي'**
  String get txnCycleYearly;

  /// No description provided for @txnTotalValueLabel.
  ///
  /// In ar, this message translates to:
  /// **'القيمة الكلية: '**
  String get txnTotalValueLabel;

  /// No description provided for @txnPaidManuallyLabel.
  ///
  /// In ar, this message translates to:
  /// **'مدفوع يدويًا: '**
  String get txnPaidManuallyLabel;

  /// No description provided for @txnAdd.
  ///
  /// In ar, this message translates to:
  /// **'إضافة'**
  String get txnAdd;

  /// No description provided for @txnBillsAndSubs.
  ///
  /// In ar, this message translates to:
  /// **'الفواتير والاشتراكات'**
  String get txnBillsAndSubs;

  /// No description provided for @txnPeriodSpendTotal.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي مصروفات الفترة'**
  String get txnPeriodSpendTotal;

  /// No description provided for @txnActiveMonthlySpend.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي الصرف الشهري النشط'**
  String get txnActiveMonthlySpend;

  /// No description provided for @txnTxForPeriod.
  ///
  /// In ar, this message translates to:
  /// **'عملية للفترة'**
  String get txnTxForPeriod;

  /// No description provided for @txnTotalSpent.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المصروف'**
  String get txnTotalSpent;

  /// No description provided for @txnActiveSub.
  ///
  /// In ar, this message translates to:
  /// **'اشتراك نشط'**
  String get txnActiveSub;

  /// No description provided for @txnRunningInst.
  ///
  /// In ar, this message translates to:
  /// **'قسط جاري'**
  String get txnRunningInst;

  /// No description provided for @txnYearlyTotal.
  ///
  /// In ar, this message translates to:
  /// **'المجموع سنويًا'**
  String get txnYearlyTotal;

  /// No description provided for @txnSmartInbox.
  ///
  /// In ar, this message translates to:
  /// **'صندوق المراجعة الذكي'**
  String get txnSmartInbox;

  /// No description provided for @txnReviewTx.
  ///
  /// In ar, this message translates to:
  /// **'راجع العملية'**
  String get txnReviewTx;

  /// No description provided for @txnHide.
  ///
  /// In ar, this message translates to:
  /// **'إخفاء'**
  String get txnHide;

  /// No description provided for @txnSuspectTxPlural.
  ///
  /// In ar, this message translates to:
  /// **'عمليات مشبوهة'**
  String get txnSuspectTxPlural;

  /// No description provided for @txnDismissAll.
  ///
  /// In ar, this message translates to:
  /// **'تجاهل الكل'**
  String get txnDismissAll;

  /// No description provided for @txnNoSuspectTx.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات مشبوهة'**
  String get txnNoSuspectTx;

  /// No description provided for @txnSimilarExists.
  ///
  /// In ar, this message translates to:
  /// **'عملية مشابهة موجودة'**
  String get txnSimilarExists;

  /// No description provided for @txnSimilarBody.
  ///
  /// In ar, this message translates to:
  /// **'هذه العملية تشبه عملية موجودة بالمبلغ والتاجر والوقت نفسها.'**
  String get txnSimilarBody;

  /// No description provided for @txnTheNew.
  ///
  /// In ar, this message translates to:
  /// **'الجديدة'**
  String get txnTheNew;

  /// No description provided for @txnNoClearMerchant.
  ///
  /// In ar, this message translates to:
  /// **'بدون تاجر واضح'**
  String get txnNoClearMerchant;

  /// No description provided for @txnTheExisting.
  ///
  /// In ar, this message translates to:
  /// **'الموجودة'**
  String get txnTheExisting;

  /// No description provided for @txnDismissDuplicate.
  ///
  /// In ar, this message translates to:
  /// **'تجاهل التكرار'**
  String get txnDismissDuplicate;

  /// No description provided for @txnSaveAsNew.
  ///
  /// In ar, this message translates to:
  /// **'احفظ كجديدة'**
  String get txnSaveAsNew;

  /// No description provided for @txnEditTx.
  ///
  /// In ar, this message translates to:
  /// **'تعديل العملية'**
  String get txnEditTx;

  /// No description provided for @txnChangeCategory.
  ///
  /// In ar, this message translates to:
  /// **'تغيير التصنيف'**
  String get txnChangeCategory;

  /// No description provided for @txnTimeInSms.
  ///
  /// In ar, this message translates to:
  /// **'وقت العملية داخل SMS'**
  String get txnTimeInSms;

  /// No description provided for @txnTimeReceived.
  ///
  /// In ar, this message translates to:
  /// **'وقت استلام الرسالة'**
  String get txnTimeReceived;

  /// No description provided for @txnDupBannerReview.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{عملية مشبوهة واحدة} =2{عمليتان مشبوهتان} few{{count} عمليات مشبوهة} many{{count} عملية مشبوهة} other{{count} عملية مشبوهة}} — اضغط للمراجعة'**
  String txnDupBannerReview(int count);

  /// No description provided for @txnDismissAllDupesBody.
  ///
  /// In ar, this message translates to:
  /// **'ستُزال كل تنبيهات التكرار المعروضة. العمليات نفسها لن تتأثر، لكن لا يمكن مراجعتها من هنا مرة أخرى.'**
  String get txnDismissAllDupesBody;

  /// No description provided for @txnTimeSource.
  ///
  /// In ar, this message translates to:
  /// **'مصدر الوقت: {source}'**
  String txnTimeSource(String source);

  /// No description provided for @txnRecurredMonths.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{تكرر شهرًا واحدًا} =2{تكرر شهرين} few{تكرر {count} أشهر} many{تكرر {count} شهرًا} other{تكرر {count} شهرًا}} · اضغط للتفعيل'**
  String txnRecurredMonths(int count);

  /// No description provided for @txnConfirmAllBody.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{سيتم تأكيد عملية واحدة بتصنيفها الحالي.} =2{سيتم تأكيد عمليتين بتصنيفيهما الحاليين.} few{سيتم تأكيد {count} عمليات بتصنيفاتها الحالية.} many{سيتم تأكيد {count} عملية بتصنيفاتها الحالية.} other{سيتم تأكيد {count} عملية بتصنيفاتها الحالية.}}'**
  String txnConfirmAllBody(int count);

  /// No description provided for @txnOverdueDays.
  ///
  /// In ar, this message translates to:
  /// **'{days, plural, =1{متأخر يومًا واحدًا} =2{متأخر يومين} few{متأخر {days} أيام} many{متأخر {days} يومًا} other{متأخر {days} يومًا}}'**
  String txnOverdueDays(int days);

  /// No description provided for @txnInDays.
  ///
  /// In ar, this message translates to:
  /// **'{days, plural, =1{بعد يوم واحد} =2{بعد يومين} few{بعد {days} أيام} many{بعد {days} يومًا} other{بعد {days} يومًا}}'**
  String txnInDays(int days);

  /// No description provided for @txnPerInstalment.
  ///
  /// In ar, this message translates to:
  /// **'{amount} / قسط'**
  String txnPerInstalment(String amount);

  /// No description provided for @txnPaidOfTotal.
  ///
  /// In ar, this message translates to:
  /// **'{paid} من {total} قسط مدفوع'**
  String txnPaidOfTotal(int paid, int total);

  /// No description provided for @txnRemainingInstalments.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{متبقٍ قسط واحد} =2{متبقٍ قسطان} few{متبقٍ {count} أقساط} many{متبقٍ {count} قسطًا} other{متبقٍ {count} قسط}}'**
  String txnRemainingInstalments(int count);

  /// No description provided for @txnInterestRate.
  ///
  /// In ar, this message translates to:
  /// **'فائدة {rate}%'**
  String txnInterestRate(String rate);

  /// No description provided for @txnNextInstalment.
  ///
  /// In ar, this message translates to:
  /// **'القسط القادم: {due}'**
  String txnNextInstalment(String due);

  /// No description provided for @txnEstPerMonth.
  ///
  /// In ar, this message translates to:
  /// **'{amount} {currency}/شهر'**
  String txnEstPerMonth(String amount, String currency);

  /// No description provided for @txnSmartInboxCount.
  ///
  /// In ar, this message translates to:
  /// **'صندوق المراجعة الذكي · {count}'**
  String txnSmartInboxCount(int count);

  /// No description provided for @txnDismissNAlerts.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{تجاهل تنبيهًا واحدًا؟} =2{تجاهل تنبيهين؟} few{تجاهل {count} تنبيهات؟} many{تجاهل {count} تنبيهًا؟} other{تجاهل {count} تنبيه؟}}'**
  String txnDismissNAlerts(int count);

  /// No description provided for @txnDismissAllCount.
  ///
  /// In ar, this message translates to:
  /// **'تجاهل الكل ({count})'**
  String txnDismissAllCount(int count);

  /// No description provided for @subsOverdue.
  ///
  /// In ar, this message translates to:
  /// **'متأخر'**
  String get subsOverdue;

  /// No description provided for @subsToday.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get subsToday;

  /// No description provided for @subsTabSubs.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات ({count})'**
  String subsTabSubs(int count);

  /// No description provided for @subsTabInst.
  ///
  /// In ar, this message translates to:
  /// **'الأقساط ({count})'**
  String subsTabInst(int count);

  /// No description provided for @subsMonthlyScoped.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات الشهرية · {account}'**
  String subsMonthlyScoped(String account);

  /// No description provided for @subsPerYearApprox.
  ///
  /// In ar, this message translates to:
  /// **'≈ {amount}/سنة'**
  String subsPerYearApprox(String amount);

  /// No description provided for @subsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات والفواتير'**
  String get subsTitle;

  /// No description provided for @subsMonthlyTotal.
  ///
  /// In ar, this message translates to:
  /// **'الاشتراكات الشهرية'**
  String get subsMonthlyTotal;

  /// No description provided for @subsActiveSubs.
  ///
  /// In ar, this message translates to:
  /// **'اشتراكات نشطة'**
  String get subsActiveSubs;

  /// No description provided for @subsRunningInst.
  ///
  /// In ar, this message translates to:
  /// **'أقساط جارية'**
  String get subsRunningInst;

  /// No description provided for @subsMonthlyInstCommit.
  ///
  /// In ar, this message translates to:
  /// **'التزام الأقساط شهريًا'**
  String get subsMonthlyInstCommit;

  /// No description provided for @subsEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'اشتراكاتك في مكان واحد'**
  String get subsEmptyTitle;

  /// No description provided for @subsAutoDetected.
  ///
  /// In ar, this message translates to:
  /// **'مكتشفة تلقائيًا'**
  String get subsAutoDetected;

  /// No description provided for @subsAddNewSub.
  ///
  /// In ar, this message translates to:
  /// **'إضافة اشتراك جديد'**
  String get subsAddNewSub;

  /// No description provided for @subsMaybeUnused.
  ///
  /// In ar, this message translates to:
  /// **'قد لا تستخدم هذا الاشتراك'**
  String get subsMaybeUnused;

  /// No description provided for @subsInstEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'أقساطك، واضحة قبل ميعادها'**
  String get subsInstEmptyTitle;

  /// No description provided for @subsInstEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف القسط بالمبلغ والعدد وتاريخ الاستحقاق.'**
  String get subsInstEmptyBody;

  /// No description provided for @subsTotalInstDebt.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي مديونية الأقساط'**
  String get subsTotalInstDebt;

  /// No description provided for @subsNearestInst.
  ///
  /// In ar, this message translates to:
  /// **'أقرب قسط'**
  String get subsNearestInst;

  /// No description provided for @subsAddNewInst.
  ///
  /// In ar, this message translates to:
  /// **'إضافة قسط جديد'**
  String get subsAddNewInst;

  /// No description provided for @rptAnomalyPrivate.
  ///
  /// In ar, this message translates to:
  /// **'في يوم {date} كان الصرف أعلى من نمطك المعتاد. راجعه إن أردت معرفة السبب.'**
  String rptAnomalyPrivate(String date);

  /// No description provided for @rptAnomalyDetail.
  ///
  /// In ar, this message translates to:
  /// **'في يوم {date} صرفت {amount}، وهو أعلى من متوسطك اليومي {ratio}×.'**
  String rptAnomalyDetail(String date, String amount, String ratio);

  /// No description provided for @rptSpendLower.
  ///
  /// In ar, this message translates to:
  /// **'صرفك أقل {percent}% من نفس الفترة السابقة.'**
  String rptSpendLower(int percent);

  /// No description provided for @rptSpendHigher.
  ///
  /// In ar, this message translates to:
  /// **'صرفك أعلى {percent}% من نفس الفترة السابقة.'**
  String rptSpendHigher(int percent);

  /// No description provided for @rptHighestDayBody.
  ///
  /// In ar, this message translates to:
  /// **'أعلى يوم في الفترة وصل إلى {amount}.'**
  String rptHighestDayBody(String amount);

  /// No description provided for @rptTopCategoryHint.
  ///
  /// In ar, this message translates to:
  /// **'أكبر إنفاق لديك على {category}. راقب هذا التصنيف أولًا.'**
  String rptTopCategoryHint(String category);

  /// No description provided for @rptMerchantTxCount.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{عملية واحدة} =2{عمليتان} few{{count} عمليات} many{{count} عملية} other{{count} عملية}}'**
  String rptMerchantTxCount(int count);

  /// No description provided for @rptVsLastWeek.
  ///
  /// In ar, this message translates to:
  /// **'{sign} {percent}% مقارنة بالأسبوع الماضي'**
  String rptVsLastWeek(String sign, String percent);

  /// No description provided for @rptTopCategoryWeek.
  ///
  /// In ar, this message translates to:
  /// **'أكثر فئة صرفًا: {category}'**
  String rptTopCategoryWeek(String category);

  /// No description provided for @rptBestSavingDay.
  ///
  /// In ar, this message translates to:
  /// **'أفضل يوم توفيرًا: {date} ({amount})'**
  String rptBestSavingDay(String date, String amount);

  /// No description provided for @rptTopMerchantWeek.
  ///
  /// In ar, this message translates to:
  /// **'أكثر متجر صرفًا: {name} ({amount})'**
  String rptTopMerchantWeek(String name, String amount);

  /// No description provided for @rptTabOverview.
  ///
  /// In ar, this message translates to:
  /// **'نظرة عامة'**
  String get rptTabOverview;

  /// No description provided for @rptTabTrends.
  ///
  /// In ar, this message translates to:
  /// **'الاتجاهات'**
  String get rptTabTrends;

  /// No description provided for @rptTabDetails.
  ///
  /// In ar, this message translates to:
  /// **'التفاصيل'**
  String get rptTabDetails;

  /// No description provided for @rptUnusualSpend.
  ///
  /// In ar, this message translates to:
  /// **'صرف غير معتاد'**
  String get rptUnusualSpend;

  /// No description provided for @rptVsPrevPeriod.
  ///
  /// In ar, this message translates to:
  /// **'مقارنة بنفس الفترة السابقة'**
  String get rptVsPrevPeriod;

  /// No description provided for @rptNeedPrevPeriod.
  ///
  /// In ar, this message translates to:
  /// **'ما زلنا نحتاج فترة سابقة فيها إنفاق لعرض الاتجاه بدقة.'**
  String get rptNeedPrevPeriod;

  /// No description provided for @rptHighestSpendDay.
  ///
  /// In ar, this message translates to:
  /// **'أعلى يوم صرف'**
  String get rptHighestSpendDay;

  /// No description provided for @rptQuickTip.
  ///
  /// In ar, this message translates to:
  /// **'اقتراح سريع'**
  String get rptQuickTip;

  /// No description provided for @rptAddMoreTx.
  ///
  /// In ar, this message translates to:
  /// **'ابدأ بإضافة عمليات أكثر لنقدّم اقتراحات أوضح.'**
  String get rptAddMoreTx;

  /// No description provided for @rptSelectedPeriod.
  ///
  /// In ar, this message translates to:
  /// **'الفترة المختارة'**
  String get rptSelectedPeriod;

  /// No description provided for @rptNetPeriodSpend.
  ///
  /// In ar, this message translates to:
  /// **'صافي مصروف الفترة'**
  String get rptNetPeriodSpend;

  /// No description provided for @rptSelectedPeriodSpend.
  ///
  /// In ar, this message translates to:
  /// **'مصروف الفترة المختارة'**
  String get rptSelectedPeriodSpend;

  /// No description provided for @rptTotalExpenses.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المصروفات'**
  String get rptTotalExpenses;

  /// No description provided for @rptRefunds.
  ///
  /// In ar, this message translates to:
  /// **'المرتجعات'**
  String get rptRefunds;

  /// No description provided for @rptNet.
  ///
  /// In ar, this message translates to:
  /// **'الصافي'**
  String get rptNet;

  /// No description provided for @rptThisWeekUsage.
  ///
  /// In ar, this message translates to:
  /// **'استهلاك الأسبوع الحالي'**
  String get rptThisWeekUsage;

  /// No description provided for @rptAverage.
  ///
  /// In ar, this message translates to:
  /// **'المتوسط'**
  String get rptAverage;

  /// No description provided for @rptHighest.
  ///
  /// In ar, this message translates to:
  /// **'الأعلى'**
  String get rptHighest;

  /// No description provided for @rptTotal.
  ///
  /// In ar, this message translates to:
  /// **'الإجمالي'**
  String get rptTotal;

  /// No description provided for @rptByCategory.
  ///
  /// In ar, this message translates to:
  /// **'استهلاكك بالتصنيفات'**
  String get rptByCategory;

  /// No description provided for @rptByMerchant.
  ///
  /// In ar, this message translates to:
  /// **'مصروفاتك في المتاجر'**
  String get rptByMerchant;

  /// No description provided for @rptTopMerchantsSub.
  ///
  /// In ar, this message translates to:
  /// **'أكبر أماكن الصرف في الفترة'**
  String get rptTopMerchantsSub;

  /// No description provided for @rptMerchantsEmpty.
  ///
  /// In ar, this message translates to:
  /// **'ستظهر هنا أكثر المتاجر صرفاً بعد إضافة عمليات مؤكدة.'**
  String get rptMerchantsEmpty;

  /// No description provided for @rptIncludesRefund.
  ///
  /// In ar, this message translates to:
  /// **' · شامل مرتجع '**
  String get rptIncludesRefund;

  /// No description provided for @rptInsightsTitle.
  ///
  /// In ar, this message translates to:
  /// **'الرؤى والتقارير'**
  String get rptInsightsTitle;

  /// No description provided for @rptInsightsSub.
  ///
  /// In ar, this message translates to:
  /// **'اقرأ صرفك كاتجاهات يومية وتصنيفات ومتاجر.'**
  String get rptInsightsSub;

  /// No description provided for @rptDailyAverage.
  ///
  /// In ar, this message translates to:
  /// **'متوسط يومي'**
  String get rptDailyAverage;

  /// No description provided for @rptHighestDay.
  ///
  /// In ar, this message translates to:
  /// **'أعلى يوم'**
  String get rptHighestDay;

  /// No description provided for @rptWeekSummary.
  ///
  /// In ar, this message translates to:
  /// **'ملخص الأسبوع'**
  String get rptWeekSummary;

  /// No description provided for @bdgPeriodSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية {period} · {date}'**
  String bdgPeriodSubtitle(String period, String date);

  /// No description provided for @bdgPeriodSubtitleLive.
  ///
  /// In ar, this message translates to:
  /// **'ميزانية {period} · {date} · جارية'**
  String bdgPeriodSubtitleLive(String period, String date);

  /// No description provided for @bdgLatestOfTotal.
  ///
  /// In ar, this message translates to:
  /// **'أحدث {shown} من {total}'**
  String bdgLatestOfTotal(int shown, int total);

  /// No description provided for @bdgRemainingPrefix.
  ///
  /// In ar, this message translates to:
  /// **'باقي '**
  String get bdgRemainingPrefix;

  /// No description provided for @bdgToReachSuffix.
  ///
  /// In ar, this message translates to:
  /// **' {currency} للوصول'**
  String bdgToReachSuffix(String currency);

  /// No description provided for @setUnsyncedLedger.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{تغيير واحد في المعاملات} =2{تغييران في المعاملات} few{{count} تغييرات في المعاملات} many{{count} تغييرًا في المعاملات} other{{count} تغيير في المعاملات}}'**
  String setUnsyncedLedger(int count);

  /// No description provided for @setUnsyncedPlanning.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{تغيير واحد في الحسابات/الميزانيات/الأهداف/الفواتير} =2{تغييران في الحسابات/الميزانيات/الأهداف/الفواتير} few{{count} تغييرات في الحسابات/الميزانيات/الأهداف/الفواتير} many{{count} تغييرًا في الحسابات/الميزانيات/الأهداف/الفواتير} other{{count} تغيير في الحسابات/الميزانيات/الأهداف/الفواتير}}'**
  String setUnsyncedPlanning(int count);

  /// No description provided for @setUnsyncedInbox.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{عنصر واحد في صندوق الوارد} =2{عنصران في صندوق الوارد} few{{count} عناصر في صندوق الوارد} many{{count} عنصرًا في صندوق الوارد} other{{count} عنصر في صندوق الوارد}}'**
  String setUnsyncedInbox(int count);

  /// No description provided for @setUnsyncedCards.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{بطاقة واحدة محفوظة على هذا الجهاز فقط} =2{بطاقتان محفوظتان على هذا الجهاز فقط} few{{count} بطاقات محفوظة على هذا الجهاز فقط} many{{count} بطاقة محفوظة على هذا الجهاز فقط} other{{count} بطاقة محفوظة على هذا الجهاز فقط}}'**
  String setUnsyncedCards(int count);

  /// No description provided for @setUnsyncedUnproven.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{سجل مالي واحد لم يُرفع للسحابة بعد} =2{سجلان ماليان لم يُرفعا للسحابة بعد} few{{count} سجلات مالية لم تُرفع للسحابة بعد} many{{count} سجلًا ماليًا لم يُرفع للسحابة بعد} other{{count} سجل مالي لم يُرفع للسحابة بعد}}'**
  String setUnsyncedUnproven(int count);

  /// No description provided for @setUnsyncedConflicts.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{سجل واحد به تعارض لم يُحلّ} =2{سجلان بهما تعارض لم يُحلّ} few{{count} سجلات بها تعارض لم يُحلّ} many{{count} سجلًا به تعارض لم يُحلّ} other{{count} سجل به تعارض لم يُحلّ}}'**
  String setUnsyncedConflicts(int count);

  /// No description provided for @setListSeparator.
  ///
  /// In ar, this message translates to:
  /// **'، '**
  String get setListSeparator;

  /// No description provided for @setUnsyncedSignOutBody.
  ///
  /// In ar, this message translates to:
  /// **'لديك بيانات لم تُرفع للسحابة وسيحذفها تسجيل الخروج: {list}. خُذ نسخة احتياطية أولًا إن أردت الاحتفاظ بها.'**
  String setUnsyncedSignOutBody(String list);

  /// No description provided for @setGapDays.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{منذ يوم واحد} =2{منذ يومين} few{منذ {count} أيام} many{منذ {count} يومًا} other{منذ {count} يوم}}'**
  String setGapDays(int count);

  /// No description provided for @setGapHours.
  ///
  /// In ar, this message translates to:
  /// **'{count, plural, =1{منذ ساعة واحدة} =2{منذ ساعتين} few{منذ {count} ساعات} many{منذ {count} ساعة} other{منذ {count} ساعة}}'**
  String setGapHours(int count);

  /// No description provided for @setGapToday.
  ///
  /// In ar, this message translates to:
  /// **'اليوم'**
  String get setGapToday;

  /// No description provided for @setLastCapture.
  ///
  /// In ar, this message translates to:
  /// **'آخر عملية رصد: {gap}'**
  String setLastCapture(String gap);

  /// No description provided for @setApnsFailed.
  ///
  /// In ar, this message translates to:
  /// **'فشل تسجيل APNs: {message}'**
  String setApnsFailed(String message);

  /// No description provided for @setCheckShortcutStillOn.
  ///
  /// In ar, this message translates to:
  /// **'{subtitle} — تأكد أن الاختصار لا يزال مفعّلًا'**
  String setCheckShortcutStillOn(String subtitle);

  /// No description provided for @goalDueToday.
  ///
  /// In ar, this message translates to:
  /// **'الموعد اليوم'**
  String get goalDueToday;

  /// No description provided for @goalDaysLeft.
  ///
  /// In ar, this message translates to:
  /// **'{days, plural, =1{باقي يوم واحد} =2{باقي يومان} few{باقي {days} أيام} many{باقي {days} يومًا} other{باقي {days} يوم}}'**
  String goalDaysLeft(int days);

  /// No description provided for @goalMonthsLeft.
  ///
  /// In ar, this message translates to:
  /// **'{months, plural, =1{باقي شهر واحد} =2{باقي شهران} few{باقي {months} أشهر} many{باقي {months} شهرًا} other{باقي {months} شهر}}'**
  String goalMonthsLeft(int months);

  /// No description provided for @goalRemainingToReach.
  ///
  /// In ar, this message translates to:
  /// **'باقي {amount} {currency} للوصول'**
  String goalRemainingToReach(String amount, String currency);

  /// No description provided for @goalSavedAmount.
  ///
  /// In ar, this message translates to:
  /// **'مدخر {amount} {currency}'**
  String goalSavedAmount(String amount, String currency);

  /// No description provided for @goalTargetAmount.
  ///
  /// In ar, this message translates to:
  /// **'الهدف {amount} {currency}'**
  String goalTargetAmount(String amount, String currency);

  /// No description provided for @goalPerMonth.
  ///
  /// In ar, this message translates to:
  /// **'/شهر'**
  String get goalPerMonth;

  /// No description provided for @goalOverdue.
  ///
  /// In ar, this message translates to:
  /// **'تجاوز الموعد المستهدف'**
  String get goalOverdue;

  /// No description provided for @goalTotalSavedAll.
  ///
  /// In ar, this message translates to:
  /// **'إجمالي المدخر لكل أحلامك'**
  String get goalTotalSavedAll;

  /// No description provided for @goalTargetLabel.
  ///
  /// In ar, this message translates to:
  /// **'المستهدف'**
  String get goalTargetLabel;

  /// No description provided for @goalEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'أضف هدفك الأول وابدأ تعبئة الخزنة.'**
  String get goalEmptyBody;

  /// No description provided for @cardLinkTxTo.
  ///
  /// In ar, this message translates to:
  /// **'اربط عملية بـ •••• {last4}'**
  String cardLinkTxTo(String last4);

  /// No description provided for @cardTxLinkedTo.
  ///
  /// In ar, this message translates to:
  /// **'تم ربط العملية بـ •••• {last4}'**
  String cardTxLinkedTo(String last4);

  /// No description provided for @cardAccountWord.
  ///
  /// In ar, this message translates to:
  /// **'حساب'**
  String get cardAccountWord;

  /// No description provided for @cardUnassigned.
  ///
  /// In ar, this message translates to:
  /// **'غير مخصّصة'**
  String get cardUnassigned;

  /// No description provided for @cardBack.
  ///
  /// In ar, this message translates to:
  /// **'رجوع'**
  String get cardBack;

  /// No description provided for @cardAllCards.
  ///
  /// In ar, this message translates to:
  /// **'كل البطاقات'**
  String get cardAllCards;

  /// No description provided for @cardAddCard.
  ///
  /// In ar, this message translates to:
  /// **'إضافة بطاقة'**
  String get cardAddCard;

  /// No description provided for @cardEmptyTitle.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد بطاقات بعد'**
  String get cardEmptyTitle;

  /// No description provided for @cardEmptyBody.
  ///
  /// In ar, this message translates to:
  /// **'تظهر البطاقات تلقائيًا من رسائل البنك، ويمكنك إضافة بطاقة بتصميمك.'**
  String get cardEmptyBody;

  /// No description provided for @cardAddCardCta.
  ///
  /// In ar, this message translates to:
  /// **'أضف بطاقة'**
  String get cardAddCardCta;

  /// No description provided for @cardEdit.
  ///
  /// In ar, this message translates to:
  /// **'تعديل'**
  String get cardEdit;

  /// No description provided for @cardIn.
  ///
  /// In ar, this message translates to:
  /// **'داخل'**
  String get cardIn;

  /// No description provided for @cardOut.
  ///
  /// In ar, this message translates to:
  /// **'خارج'**
  String get cardOut;

  /// No description provided for @cardAddTx.
  ///
  /// In ar, this message translates to:
  /// **'إضافة عملية'**
  String get cardAddTx;

  /// No description provided for @cardLinkExistingTx.
  ///
  /// In ar, this message translates to:
  /// **'اربط عملية موجودة'**
  String get cardLinkExistingTx;

  /// No description provided for @cardSearchHint.
  ///
  /// In ar, this message translates to:
  /// **'ابحث بالاسم أو المبلغ'**
  String get cardSearchHint;

  /// No description provided for @cardNoTx.
  ///
  /// In ar, this message translates to:
  /// **'لا توجد عمليات'**
  String get cardNoTx;

  /// No description provided for @accAddAccount.
  ///
  /// In ar, this message translates to:
  /// **'إضافة حساب'**
  String get accAddAccount;

  /// No description provided for @accTitle.
  ///
  /// In ar, this message translates to:
  /// **'الحسابات والمحافظ'**
  String get accTitle;

  /// No description provided for @accSubtitle.
  ///
  /// In ar, this message translates to:
  /// **'كل حساب بعملته الخاصة — نقدي، بنك، محفظة أو بطاقة.'**
  String get accSubtitle;

  /// No description provided for @accDefault.
  ///
  /// In ar, this message translates to:
  /// **'افتراضي'**
  String get accDefault;

  /// No description provided for @accUnassignedCards.
  ///
  /// In ar, this message translates to:
  /// **'بطاقات غير مخصّصة'**
  String get accUnassignedCards;

  /// No description provided for @accUnassignedCardsBody.
  ///
  /// In ar, this message translates to:
  /// **'بطاقات ظهرت في رسائلك لكنها غير مرتبطة بحساب بعد.'**
  String get accUnassignedCardsBody;
}

class _AppL10nDelegate extends LocalizationsDelegate<AppL10n> {
  const _AppL10nDelegate();

  @override
  Future<AppL10n> load(Locale locale) {
    return SynchronousFuture<AppL10n>(lookupAppL10n(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['ar', 'en'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppL10nDelegate old) => false;
}

AppL10n lookupAppL10n(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'ar':
      return AppL10nAr();
    case 'en':
      return AppL10nEn();
  }

  throw FlutterError(
      'AppL10n.delegate failed to load unsupported locale "$locale". This is likely '
      'an issue with the localizations generation tool. Please file an issue '
      'on GitHub with a reproducible sample app and the gen-l10n configuration '
      'that was used.');
}
