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
  /// **'مالي'**
  String get appTitle;

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
  /// **'اعرف وين راحت فلوسك، ووفّر أوتوماتيكياً بطريقة ذكية وسهلة.'**
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
  /// **'شارك رسالة البنك مع مالي، ونطلّع المبلغ والمتجر ونصنّفها على جهازك.'**
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
  /// **'مالي يلتقط المعنى من الرسالة، ويحوّلها لتصنيف ومبلغ ومتجر بدون إدخال يدوي.'**
  String get howItWorksDesc;

  /// No description provided for @howItWorksNote1.
  ///
  /// In ar, this message translates to:
  /// **'مش محتاج تختار بنكك — مالي يتعرّف عليه من نص الرسالة.'**
  String get howItWorksNote1;

  /// No description provided for @howItWorksNote2.
  ///
  /// In ar, this message translates to:
  /// **'لو ظهرت بطاقة جديدة، مالي يضيفها تلقائياً من آخر 4 أرقام.'**
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
  /// **'كل المعالجة والذكاء يتم على هاتفك بدون إنترنت'**
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
  /// **'شارك رسائل البنك مع مالي'**
  String get enableAutoTracking;

  /// No description provided for @setupAppleShortcut.
  ///
  /// In ar, this message translates to:
  /// **'إعداد اختصار Apple'**
  String get setupAppleShortcut;

  /// No description provided for @autoTrackingSubtitleAndroid.
  ///
  /// In ar, this message translates to:
  /// **'من تطبيق الرسائل، اختر رسالة البنك ثم مشاركة إلى مالي. سنحللها على جهازك ونضيف العملية.'**
  String get autoTrackingSubtitleAndroid;

  /// No description provided for @autoTrackingSubtitleIos.
  ///
  /// In ar, this message translates to:
  /// **'اتبع الخطوات مرة واحدة، وبعدها يمرّر iPhone رسائل البنك إلى مالي بأمان.'**
  String get autoTrackingSubtitleIos;

  /// No description provided for @smsActivationSnack.
  ///
  /// In ar, this message translates to:
  /// **'تقدر تشارك رسالة البنك مع مالي أو تلصقها يدويًا.'**
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
  /// **'اعمل الخطوات دي مرة واحدة من تطبيق Apple Shortcuts.'**
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
  /// **'بالمتابعة توافق على شروط الخدمة وسياسة الخصوصية الخاصة بـ مالي.'**
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
  /// **'بسبب قيود نظام iOS، نستخدم تطبيق الاختصارات الرسمي من Apple لتمرير رسائل البنك لـ مالي تلقائياً وبأمان تام.'**
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
  /// **'مالي يقرأ رسائل البنك على جهازك فقط عشان يسجّل عملياتك تلقائياً. مش بنقرأ رسائلك الشخصية، ومفيش حاجة بتطلع برّه الجهاز.'**
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
  /// **'ألصق رسالة بنك بدلاً من كده'**
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
  /// **'إنت معملتش حاجة — مالي قرأ رسالة بنكك وسجّلها.'**
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
  /// **'مالي مش متأكد 100% — راجعها بسرعة.'**
  String get firstTxNeedsCheckSub;

  /// No description provided for @wrongCategoryTap.
  ///
  /// In ar, this message translates to:
  /// **'الفئة مش صح؟ اضغط لتغييرها'**
  String get wrongCategoryTap;
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
