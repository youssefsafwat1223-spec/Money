// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppL10nEn extends AppL10n {
  AppL10nEn([String locale = 'en']) : super(locale);

  @override
  String get appTitle => 'Qirsh';

  @override
  String get setupHeaderTitle => 'Let\'s set up Qirsh';

  @override
  String get setupHeaderSubtitle => 'A few quick steps and you\'re ready.';

  @override
  String setupStepLabel(int current, int total) {
    return 'Step $current of $total';
  }

  @override
  String get setupCountryTitle => 'Your country and currency';

  @override
  String get setupCountryBody =>
      'We\'ll use it as the base currency for your accounts.';

  @override
  String get setupNotificationsTitle => 'Turn on notifications';

  @override
  String get setupNotificationsBody =>
      'So every transaction reaches you the moment it happens.';

  @override
  String get setupNotificationsCta => 'Enable';

  @override
  String get setupCloudTitle => 'Smart processing';

  @override
  String get setupCloudBody =>
      'Qirsh processes bank messages you share through its server and AI to turn them into transactions and reports without storing your full numbers.';

  @override
  String get setupCloudCta => 'Continue';

  @override
  String get setupShortcutTitle => 'Install the Qirsh Shortcut';

  @override
  String get setupShortcutBody =>
      'It\'s what sends us your bank messages automatically.';

  @override
  String get setupShortcutStep1Title => 'Remove the old one';

  @override
  String get setupShortcutStep1Body =>
      'Open the Shortcuts app, go to the Automation tab, and delete any old automation for the app.';

  @override
  String get setupShortcutStep2Title => 'New (+)';

  @override
  String get setupShortcutStep2Body =>
      'Tap New Automation (+) and scroll down until you find \"Message\".';

  @override
  String get setupShortcutStep3Title => 'Filter messages';

  @override
  String setupShortcutStep3Body(String currency) {
    return 'Tap \"Message Contents\" and type your currency code, like $currency.';
  }

  @override
  String get setupShortcutStep4Title => 'No confirmation';

  @override
  String get setupShortcutStep4Body =>
      'Turn on \"Run Immediately\" and turn off \"Notify When Run\" if it appears, then Next.';

  @override
  String get setupShortcutStep5Title => 'Send to the app';

  @override
  String get setupShortcutStep5Body =>
      'Choose New Blank Automation, search for \"Process Bank SMS\", and set SMS Text to \"Shortcut Input\".';

  @override
  String get setupShortcutStep6Title => 'Save';

  @override
  String get setupShortcutStep6Body =>
      'Turn off \"Show When Run\" if it appears, and tap Save.';

  @override
  String get setupShortcutCta => 'Installed';

  @override
  String get setupFinishCta => 'Start';

  @override
  String get brandTagline => 'Your money, clearer. Your decisions, smarter.';

  @override
  String get brandContinueCta => 'Let\'s get started';

  @override
  String get authTitle => 'Your financial journey, saved';

  @override
  String get authSubtitle =>
      'Sign in to protect your data and restore it on your devices.';

  @override
  String get authTrustLocalEncryption => 'Local encryption';

  @override
  String get authTrustOnDevice => 'Encrypted on your device, synced securely';

  @override
  String get authTermsNotice =>
      'By continuing, you agree to the Terms of Service and Privacy Policy.';

  @override
  String get authAppleCta => 'Continue with Apple';

  @override
  String get authGoogleCta => 'Continue with Google';

  @override
  String get authSignInError => 'Couldn\'t sign in. Please try again.';

  @override
  String get authBackupFoundTitle => 'We found a backup for your account';

  @override
  String get authBackupFoundBody =>
      'Want to restore your data from the latest backup, or start fresh?';

  @override
  String get authBackupStartFresh => 'Start fresh';

  @override
  String get authBackupRestore => 'Restore it';

  @override
  String get storyPromiseTitle => 'Excited\nto start with you';

  @override
  String get storyPromiseSubtitle =>
      'We\'ll be your partner on your financial journey.';

  @override
  String get storyPromiseHighlight =>
      'At Qirsh, we believe financial stability starts with simple habits.';

  @override
  String get storyPromiseBody =>
      'We built an app that helps you manage your money with ease — from logging expenses and setting budgets, to subscription alerts and smart reports.';

  @override
  String get storyPromiseSectionTitle => 'Our goal?';

  @override
  String get storyPromiseSectionBody =>
      'To help you know where your money goes, save more, and live with greater ease.';

  @override
  String get storyPromiseClosing =>
      'Qirsh...\nYour partner on your financial journey.';

  @override
  String get storySpendingTitle => 'Small expenses add up';

  @override
  String get storySpendingBody =>
      'Daily expenses can seem small,\nbut over time they make a big difference.';

  @override
  String get storySpendingHighlight =>
      'What you don\'t track... is hard to control';

  @override
  String get storySpendingSupporting =>
      'Qirsh helps you see the full picture,\nand understand where your money goes.';

  @override
  String get storyContinueCta => 'Continue';

  @override
  String get storyStartCta => 'Start with Qirsh';

  @override
  String get storySkip => 'Skip';

  @override
  String get storyPageOneSemanticLabel => 'Page 1 of 2';

  @override
  String get storyPageTwoSemanticLabel => 'Page 2 of 2';

  @override
  String get next => 'Next';

  @override
  String get skip => 'Skip';

  @override
  String get registerAndStart => 'Register and Start';

  @override
  String get welcomeTitle => 'Your Daily Financial Companion';

  @override
  String get welcomeSubtitle => 'Your buddy with your money';

  @override
  String get today => 'Today';

  @override
  String get yesterday => 'Yesterday';

  @override
  String get welcomeDescription =>
      'Know where your money went, and save automatically in a smart and easy way.';

  @override
  String get secureOnDevice => 'Secure · On your device';

  @override
  String get effortless => 'Effortless';

  @override
  String get noTyping => 'No typing — we understand it for you';

  @override
  String get smsReadingDesc =>
      'Share a bank message with Qirsh; we extract amount and merchant on your device.';

  @override
  String get now => 'Now';

  @override
  String get snbSmsText => 'Mada purchase of ';

  @override
  String get snbSmsSuffix => ' at Half Million.';

  @override
  String get alrajhi => 'Al Rajhi';

  @override
  String get oneMinuteAgo => '1 minute ago';

  @override
  String get alrajhiSmsText => 'Debited ';

  @override
  String get alrajhiSmsSuffix => ' at Hamburgini restaurant.';

  @override
  String get localProcessing => 'Fully local processing';

  @override
  String get privacyFirst => 'Privacy first';

  @override
  String get howItWorks => 'How it works?';

  @override
  String get smsToTx => 'From bank message to a clear transaction';

  @override
  String get howItWorksDesc =>
      'Qirsh captures the meaning of the message and converts it into a category, amount, and merchant without manual entry.';

  @override
  String get howItWorksNote1 =>
      'No need to select your bank — Qirsh recognizes it from the message text.';

  @override
  String get howItWorksNote2 =>
      'If a new card appears, Qirsh adds it automatically from the last 4 digits.';

  @override
  String get howItWorksNote3 =>
      'You can review and edit any transaction or card inside the app.';

  @override
  String get messageFromBank => 'Message from bank';

  @override
  String get burgerBoutiqueSms => 'Purchase 45 SAR at BURGER BOUTIQUE';

  @override
  String get burgerBoutiqueSub => 'Restaurants · Now · Mada';

  @override
  String get burgerBoutiqueAmount => '-45 SAR';

  @override
  String get financialMotivation => 'Financial motivation';

  @override
  String get saveLikeGame => 'Save like a daily game';

  @override
  String get saveLikeGameDesc =>
      'Set your financial goals and save the differences day after day with a smart encouraging style.';

  @override
  String get totalSavings => 'Total accumulated savings';

  @override
  String get sar => 'SAR';

  @override
  String get travelVault => 'Travel Vault';

  @override
  String get completedPercent => '75% completed';

  @override
  String get goalLimit => 'Goal: 15,000 SAR';

  @override
  String get remainingAmount => 'Remaining: 3,750 SAR';

  @override
  String get easyToUse => 'Easy to use';

  @override
  String get selectCountryCurrency => 'Select your country and currency';

  @override
  String get selectCountryDesc =>
      'We display official flags, set the base currency, and you can add secondary currencies for external cards or subscriptions.';

  @override
  String get mainCountryCurrency => 'Country and Base Currency';

  @override
  String get additionalCurrencies => 'Additional Currencies';

  @override
  String get activeSubscriptions => 'Active Subscriptions';

  @override
  String get none => 'None';

  @override
  String get noActiveSubs => 'No active subscriptions';

  @override
  String get selectCountryTitle => 'Choose your country and base currency';

  @override
  String get searchCountryPlaceholder => 'Search for country or currency...';

  @override
  String get additionalCurrenciesTitle => 'Additional Currencies';

  @override
  String get additionalCurrenciesDesc =>
      'Optional, select currencies you deal with beside your base currency.';

  @override
  String get expectedSubscriptions => 'Expected Subscriptions';

  @override
  String get expectedSubscriptionsDesc =>
      'Select your active subscriptions and we will recognize them automatically.';

  @override
  String get completePrivacy => 'Complete Privacy';

  @override
  String get dataStaysOnDevice => 'Your data stays on your device';

  @override
  String get privacyPrinciples =>
      'Our security and privacy principles mean you are the sole controller of your financial data.';

  @override
  String get privacyRule1 =>
      'Qirsh processes bank messages you share through its server and AI';

  @override
  String get privacyRule2 =>
      'We only process bank messages you share or paste yourself';

  @override
  String get privacyRule3 =>
      'We never sell your data, and you have full freedom to delete it';

  @override
  String get enableAutoTracking => 'Share bank messages with Qirsh';

  @override
  String get setupAppleShortcut => 'Setup Apple Shortcut';

  @override
  String get autoTrackingSubtitleAndroid =>
      'From Messages, share a bank SMS to Qirsh. We parse it on your device and add the transaction.';

  @override
  String get autoTrackingSubtitleIos =>
      'Follow the steps once, and your iPhone will forward bank messages to Qirsh securely.';

  @override
  String get smsActivationSnack =>
      'You can share a bank SMS with Qirsh or paste it manually.';

  @override
  String get howWillActivationWork => 'How will it work?';

  @override
  String get allowSmsReading => 'Got it';

  @override
  String get gotIt => 'Got it';

  @override
  String get laterAddManually => 'Later, I will add manually';

  @override
  String get shortcutSetupGuide => 'Shortcut Setup Guide';

  @override
  String get doStepsOnceFromShortcuts =>
      'Perform these steps once from Apple Shortcuts app.';

  @override
  String get signInToStart => 'Sign In to Start';

  @override
  String get signInSubtitle =>
      'Sign in only to identify you and sync your settings. Your financial data stays secure on your device.';

  @override
  String get noPassword => 'No Password';

  @override
  String get continueWithApple => 'Continue with Apple';

  @override
  String get continueWithGoogle => 'Continue with Google';

  @override
  String get or => 'Or';

  @override
  String get continueWithEmail => 'Continue with Email';

  @override
  String get email => 'Email';

  @override
  String get sendOtpCode => 'Send Secure Login Code';

  @override
  String get byContinuingAgree =>
      'By continuing, you agree to Qirsh\'s Terms of Service and Privacy Policy.';

  @override
  String get enterOtpCode => 'Enter Verification Code';

  @override
  String get otpSentTo => 'We sent a 6-digit verification code to the email:';

  @override
  String get verifyCode => 'Verify Code';

  @override
  String get demoOtpCode => 'For testing: use code 123456';

  @override
  String get invalidOtpCode => 'Invalid Code';

  @override
  String get enterPasswordOrRecoveryCodeError =>
      'Type the backup password or recovery code.';

  @override
  String get recoveryCodeIncorrect =>
      'The recovery code is incorrect or doesn\'t match the backup.';

  @override
  String get backupPasswordIncorrect => 'The backup password is incorrect.';

  @override
  String get backupFound => 'We found a backup for your account';

  @override
  String get restoreDesc =>
      'Restoring your encrypted data happens on your device only. Your password never leaves your phone.';

  @override
  String get recoveryCodeLabel => 'Recovery Code';

  @override
  String get backupPasswordLabel => 'Backup Password';

  @override
  String get recoveryCodeHint => 'XXXX-XXXX-XXXX';

  @override
  String get backupPasswordHint => 'Enter the password you chose';

  @override
  String get useBackupPassword => 'Use Backup Password';

  @override
  String get useRecoveryCode => 'Use Recovery Code';

  @override
  String get restore => 'Restore';

  @override
  String get startFresh => 'Start Fresh';

  @override
  String get notNow => 'Not Now';

  @override
  String get restoreNotEnabled => 'Cloud restore is not enabled in this build.';

  @override
  String get appleSecuritySteps => 'Apple Security Steps';

  @override
  String get iosShortcutSubtitle =>
      'Due to iOS limitations, we use Apple\'s official Shortcuts app to pass bank messages to Qirsh automatically and securely.';

  @override
  String get stepsLabel => 'Steps:';

  @override
  String get multipleCurrenciesQuestion => 'Deal with multiple currencies?';

  @override
  String get multipleCurrenciesDesc =>
      'If you receive bank messages in different currencies, repeat the same steps for each currency.';

  @override
  String get continueWithoutAccount => 'Continue without account';

  @override
  String get continueWithoutAccountSub =>
      'Your data stays local on your device.';

  @override
  String get smsPermissionRationaleTitle =>
      'We just need permission to read bank messages';

  @override
  String get smsPermissionRationaleBody =>
      'Qirsh reads incoming bank SMS on your device to log your transactions automatically. It does not read personal messages, and parsing happens on your device by default — nothing leaves it unless you turn on cloud processing yourself.';

  @override
  String get listeningTitle => 'Armed — waiting for your first message';

  @override
  String get listeningSubtitle =>
      'Make any card purchase and it will appear here automatically.';

  @override
  String get pasteMessageInstead => 'Paste a bank message instead';

  @override
  String get skipForNow => 'Skip for now';

  @override
  String get shortcutVerifyTitle => 'Let\'s confirm the Shortcut works';

  @override
  String get shortcutVerifyBody =>
      'Go back to the Shortcuts app, send yourself a message with your currency keyword, then come back here.';

  @override
  String get shortcutVerifyWaiting => 'Waiting for a message...';

  @override
  String get recheckSetup => 'Re-check setup';

  @override
  String get filterKeywordsLabel => 'Keyword:';

  @override
  String get firstTxTitle => 'First transaction — captured automatically!';

  @override
  String get firstTxTrustLine =>
      'You did nothing — Qirsh read your bank\'s SMS and logged it.';

  @override
  String get firstTxContinue => 'Continue';

  @override
  String get firstTxNeedsCheck => 'Needs a quick check';

  @override
  String get firstTxNeedsCheckSub =>
      'Qirsh isn\'t 100% sure — review it quickly.';

  @override
  String get wrongCategoryTap => 'Wrong category? Tap to change it';

  @override
  String get couponsTitle => 'Offers';

  @override
  String get couponsSubtitle =>
      'Partner offers that help you save on everyday spending.';

  @override
  String get couponsFilterAll => 'All';

  @override
  String get couponsFeaturedSection => 'Featured offers';

  @override
  String get couponsEmptyTitle => 'No offers right now';

  @override
  String get couponsEmptyBody =>
      'Partner offers will appear here as soon as they are available.';

  @override
  String get couponsFilterEmptyTitle => 'No offers match this filter';

  @override
  String get couponsFilterEmptyBody => 'Try a different category or tag.';

  @override
  String get couponsErrorTitle => 'Couldn\'t load offers';

  @override
  String get couponsErrorBody => 'Please try again in a moment.';

  @override
  String get couponsRetry => 'Try again';

  @override
  String get couponsLoading => 'Loading offers...';

  @override
  String get couponsCopyCode => 'Copy code';

  @override
  String couponsCodeCopied(String code) {
    return 'Code $code copied';
  }

  @override
  String get couponsOpenPartner => 'Open partner site';

  @override
  String get couponsUseOffer => 'Get the offer';

  @override
  String get couponsOpenFailed => 'Couldn\'t open the link';

  @override
  String get couponsOfferUnavailable => 'This offer isn\'t available anymore';

  @override
  String get couponsTerms => 'Terms';

  @override
  String couponsValidUntil(String date) {
    return 'Ends $date';
  }

  @override
  String get couponsOpenEnded => 'Open-ended';

  @override
  String get couponsExpiresToday => 'Ends today';

  @override
  String couponsExpiresInDays(int days) {
    return '$days days';
  }

  @override
  String get couponsAvailableGlobally => 'Available everywhere';

  @override
  String couponsAvailableIn(String countries) {
    return 'Available in $countries';
  }

  @override
  String couponsCardSemantics(String partner, String title) {
    return 'Offer from $partner: $title';
  }

  @override
  String couponsCodeSemantics(String code) {
    return 'Discount code $code';
  }

  @override
  String get couponsOffline => 'These are the latest offers available offline.';

  @override
  String get referralTitle => 'Invite Friends';

  @override
  String get referralSubtitle =>
      'Invite friends with your code. When they join and verify, you earn ad-free reports.';

  @override
  String get referralYourCodeLabel => 'Your invite code';

  @override
  String get referralCopyAction => 'Copy';

  @override
  String get referralCopiedToast => 'Code copied.';

  @override
  String get referralShareAction => 'Share';

  @override
  String referralShareMessage(String code) {
    return 'Try Qirsh! Use invite code $code when you sign up. Download the app to start.';
  }

  @override
  String referralProgressLabel(int progress, int required) {
    return '$progress / $required valid invites';
  }

  @override
  String referralCycleLabel(int cycle) {
    return 'Cycle $cycle';
  }

  @override
  String get referralRewardTitle => 'Reward';

  @override
  String referralRewardDays(int days) {
    return 'Ad-free reports for $days days';
  }

  @override
  String get referralRewardScopeNote =>
      'The reward removes ads on report export only — not a whole-app ad-free subscription.';

  @override
  String referralRewardActiveUntil(String date) {
    return 'Ad-free reports until $date';
  }

  @override
  String get referralEntitlementInactive => 'No active reward right now.';

  @override
  String get referralApplyTitle => 'Have an invite code?';

  @override
  String get referralApplyHint => 'Enter a friend\'s code once.';

  @override
  String get referralApplyPlaceholder => 'Invite code';

  @override
  String get referralApplyAction => 'Apply code';

  @override
  String get referralApplySuccess => 'Code accepted.';

  @override
  String get referralQualifiedToast => 'Your invite was counted.';

  @override
  String get referralAlreadyReferredNote =>
      'An invite code is already applied to your account.';

  @override
  String get referralLoading => 'Loading…';

  @override
  String get referralErrorTitle => 'Couldn\'t load invites';

  @override
  String get referralErrorBody => 'Please try again in a moment.';

  @override
  String get referralRetry => 'Retry';

  @override
  String get referralUnavailableTitle => 'Invites aren\'t available right now';

  @override
  String get referralUnavailableBody =>
      'We\'ll show Invite Friends here as soon as it\'s available.';

  @override
  String get referralErrorInvalidCode => 'That code isn\'t valid.';

  @override
  String get referralErrorSelfReferral => 'You can\'t use your own code.';

  @override
  String get referralErrorAlreadyReferred =>
      'You\'ve already used an invite code.';

  @override
  String get referralErrorNoActiveRule =>
      'Invites aren\'t available right now.';

  @override
  String get referralErrorIdentityUnverified =>
      'Finish verifying your account so your invite counts.';

  @override
  String get referralErrorGeneric => 'Something went wrong. Please try again.';

  @override
  String get smsDisclosureTitle => 'Reading bank messages automatically';

  @override
  String get smsDisclosureIntro =>
      'To record your expenses automatically, Qirsh needs permission to read incoming messages on your device.';

  @override
  String get smsDisclosureDetect =>
      'Qirsh scans incoming messages to identify financial transactions (purchase, transfer, withdrawal, deposit).';

  @override
  String get smsDisclosureFilter =>
      'Non-financial messages — personal messages and verification codes — are ignored and not stored.';

  @override
  String get smsDisclosureOnDevice =>
      'Parsing happens on your device by default. If you enable cloud processing, a sanitized copy — without card, account or phone numbers — is sent to Qirsh\'s servers.';

  @override
  String get smsDisclosureCloud =>
      'Cloud sync is off by default; if you turn it on, that is a separate consent from this permission.';

  @override
  String get smsDisclosureControl =>
      'You can turn automatic reading off in Qirsh settings, or revoke the permission in device settings, at any time.';

  @override
  String get smsDisclosureDecline => 'Not now';

  @override
  String get smsDisclosureAccept => 'Agree, request permission';

  @override
  String get couponsForYouSection => 'For places you shop';

  @override
  String get couponsForYouSubtitle =>
      'Matched on this device from your own spending. Nothing about it is sent anywhere.';

  @override
  String get couponsStoresSection => 'Stores';

  @override
  String get couponsStoresSubtitle => 'Merchants with live offers.';

  @override
  String couponsMerchantOffers(String merchant) {
    return 'Offers at $merchant';
  }

  @override
  String get couponsMerchantEmptyTitle => 'No live offers here right now';

  @override
  String get couponsMerchantEmptyBody =>
      'This store has no offers at the moment. Check back later.';

  @override
  String get couponsPersonalizationTitle => 'Order offers by where you shop';

  @override
  String get couponsPersonalizationBody =>
      'Qirsh matches your transactions to stores on this device and puts their offers first. Your spending never leaves your phone for this, and it is not sent to the stores.';

  @override
  String get couponsPersonalizationOff =>
      'Off — offers are ordered the same way for everyone.';

  @override
  String get couponsPersonalizationOn =>
      'On — offers at stores you use appear first.';

  @override
  String couponsValuePercent(String percent) {
    return '$percent% off';
  }

  @override
  String couponsValueFixed(String amount) {
    return '$amount off';
  }

  @override
  String get couponsValueFreeShipping => 'Free delivery';

  @override
  String couponsValueMinSpend(String amount) {
    return 'on $amount or more';
  }

  @override
  String couponsValueUpTo(String amount) {
    return 'up to $amount';
  }

  @override
  String get couponsVerifiedByUs => 'Checked by Qirsh';

  @override
  String get couponsVerifiedByProvider => 'Confirmed by the provider';

  @override
  String get couponsUnverified => 'Not checked';

  @override
  String get savingsTitle => 'What you saved';

  @override
  String get savingsEmptyTitle => 'Nothing saved yet';

  @override
  String get savingsEmptyBody =>
      'When you use an offer and confirm it, it will show up here.';

  @override
  String get savingsVerifiedLabel => 'Confirmed by the store';

  @override
  String get savingsEstimatedLabel => 'Estimated';

  @override
  String get savingsSelfReportedLabel => 'You told us';

  @override
  String get savingsBreakdownNote =>
      'These are kept apart because they are not equally certain. Only the confirmed figure is one the store reported to us.';

  @override
  String get savingsCurrencyNote => 'Currencies are never added together.';

  @override
  String get savingsConfirmTitle => 'Did you use this offer?';

  @override
  String get savingsConfirmBody =>
      'Enter your order total and we will work out what you saved. It is calculated on your phone and sent nowhere.';

  @override
  String get savingsConfirmAmountLabel => 'Order total';

  @override
  String get savingsConfirmAction => 'Calculate';

  @override
  String get savingsCannotCompute =>
      'We cannot work out an exact figure for this offer, so we will not show one.';

  @override
  String get savingsReversedNote =>
      'This was reversed after the store cancelled the purchase.';

  @override
  String get adLabel => 'Advertisement';

  @override
  String get smsAutoCaptureTitle => 'Automatic bank-SMS capture';

  @override
  String get smsAutoCaptureSubtitleOff =>
      'Off — add transactions manually or by sharing';

  @override
  String get smsAutoCaptureSubtitleOn =>
      'On — incoming bank messages are read on your device only';

  @override
  String get smsAutoCaptureSubtitleBlocked =>
      'Permission denied — open system settings to allow';

  @override
  String get smsAutoCaptureOpenSettings => 'Open system settings';

  @override
  String get smsAutoCaptureDeniedTitle => 'Permission not granted';

  @override
  String get smsAutoCaptureDeniedBody =>
      'Automatic capture needs permission to receive messages. You can still add transactions manually or by sharing a message with Qirsh.';

  @override
  String get smsCaptureTrustNotice =>
      'On Android, Qirsh reads incoming messages only after you turn on automatic capture and grant permission. It does not read bank app notifications, and it never opens your message history.';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get helpTitle => 'How to use Qirsh';

  @override
  String get helpSubtitle =>
      'A short guide to the most useful things you can do.';

  @override
  String get helpSettingsTile => 'How to use Qirsh';

  @override
  String get helpSettingsSubtitle => 'Usage guide and common questions';

  @override
  String get helpSectionBasics => 'Basics';

  @override
  String get helpSectionReports => 'Reports and insights';

  @override
  String get helpSectionPlanning => 'Planning';

  @override
  String get helpSectionPrivacy => 'Privacy and data';

  @override
  String get helpAddTransactionTitle => 'Record a transaction';

  @override
  String get helpAddTransactionBody =>
      'Tap the add button on the home screen, then choose manual entry or paste your bank message. Qirsh reads the message and extracts the amount, merchant and date — you always confirm before anything is saved.';

  @override
  String get helpSmartInboxTitle => 'Smart Inbox';

  @override
  String get helpSmartInboxBody =>
      'Transactions Qirsh captures from bank messages arrive here first. Review and confirm them, or correct the category, and they move into your transaction history.';

  @override
  String get helpCategoriesTitle => 'Categories';

  @override
  String get helpCategoriesBody =>
      'Every transaction has a category, which decides where it appears in reports and budgets. Change it from the transaction details, and Qirsh remembers your choice for that merchant.';

  @override
  String get helpPeriodTitle => 'Changing the period';

  @override
  String get helpPeriodBody =>
      'At the top of the transactions and reports screens you\'ll find the period selector: day, week, month, year, or a custom range. Every figure on the screen follows the period you pick.';

  @override
  String get helpAnnualTitle => 'The annual report';

  @override
  String get helpAnnualBody =>
      'Choose “This year” or “Last year” in the period selector to read a full year of financial behaviour: the total, categories, trends, and where you spent most.';

  @override
  String get helpAccountsTitle => 'Accounts and cards';

  @override
  String get helpAccountsBody =>
      'Add an account for each wallet or bank, each with its own currency. Cards appear automatically from bank messages, and you can add them yourself.';

  @override
  String get helpBudgetsTitle => 'Budgets';

  @override
  String get helpBudgetsBody =>
      'Set a cap for a category or for all spending, and choose how often it resets. Qirsh warns you at 80% and again when you go over.';

  @override
  String get helpGoalsTitle => 'Goals';

  @override
  String get helpGoalsBody =>
      'Create a savings goal with an amount and a date, then add contributions. Qirsh works out the daily amount that keeps the goal on track.';

  @override
  String get helpPrivacyTitle => 'You control your data';

  @override
  String get helpPrivacyBody =>
      'Your financial data is stored encrypted on your device. From the privacy screen you control cloud processing and AI analysis, and you can withdraw consent at any time.';

  @override
  String get helpBackupTitle => 'Backup and restore';

  @override
  String get helpBackupBody =>
      'Export an encrypted copy of your data and keep it safe, or restore it on another device. The file is previewed on your device before anything is written, and your passphrase never leaves it.';

  @override
  String get helpFooter => 'Still stuck? Contact us from the settings screen.';

  @override
  String get coachMarkNext => 'Next';

  @override
  String get coachMarkDone => 'Got it';

  @override
  String get coachMarkSkip => 'Skip';

  @override
  String get coachDashboardAddTitle => 'Record your first transaction';

  @override
  String get coachDashboardAddBody =>
      'The add button lets you enter a transaction yourself, or paste a bank message for Qirsh to read for you.';

  @override
  String get coachDashboardPeriodTitle => 'Pick the period';

  @override
  String get coachDashboardPeriodBody =>
      'The period selector changes every figure on the screen: day, week, month, year, or a custom range.';

  @override
  String get coachDashboardInboxTitle => 'Smart Inbox';

  @override
  String get coachDashboardInboxBody =>
      'Whatever Qirsh captures from your bank messages waits here for review before it reaches your history.';

  @override
  String get coachDashboardHelpTitle => 'The guide is always there';

  @override
  String get coachDashboardHelpBody =>
      '“How to use Qirsh” lives in Settings, and you can replay this tour from there whenever you like.';

  @override
  String get helpReplayTour => 'Replay the guided tour';

  @override
  String get helpReplayTourDone => 'The guided tour will appear again.';

  @override
  String get setLoadingCountries => 'Loading countries…';

  @override
  String get setLoadingCurrencies => 'Loading currencies…';

  @override
  String get setCountry => 'Country';

  @override
  String get setBaseCurrency => 'Base currency';

  @override
  String get setName => 'Name';

  @override
  String get setNameInApp => 'Your name in the app';

  @override
  String get setAccountData => 'Your account details';

  @override
  String get setMobileNumber => 'Mobile number';

  @override
  String get setAddYourNumber => 'Add your number';

  @override
  String get setAppearance => 'Appearance';

  @override
  String get setAppearanceSub => 'Light, dark, or match the system';

  @override
  String get setAccountsAndDues => 'Your accounts and commitments';

  @override
  String get setSyncConflicts => 'Sync conflicts';

  @override
  String get setSyncConflictsSub =>
      'Items edited on more than one device — they need your decision';

  @override
  String get setAccountsWallets => 'Accounts and wallets';

  @override
  String get setAccountsWalletsSub =>
      'Multiple accounts, each in its own currency';

  @override
  String get setAllCards => 'All cards';

  @override
  String get setAllCardsSub => 'An overview of your cards grouped by account';

  @override
  String get setSubsAndBills => 'Subscriptions and bills';

  @override
  String get setSubsAndBillsSub => 'Your recurring commitments and due dates';

  @override
  String get setPlans => 'Plans';

  @override
  String get setPlansSub =>
      'A budget for a trip or occasion that tracks itself';

  @override
  String get setToolsAndSettings => 'Tools and settings';

  @override
  String get setCategories => 'Categories';

  @override
  String get setCategoriesSub => 'Organise expenses, income and transfers';

  @override
  String get setAchievements => 'Achievements and level';

  @override
  String get setAchievementsSub =>
      'Badges and levels that encourage the habit of tracking';

  @override
  String get setCurrencyRepair => 'Confirm the currency for budgets and goals';

  @override
  String get setCurrencyRepairSub =>
      'Safely review the currency of older planning data';

  @override
  String get setAppleShortcut => 'Apple Shortcut';

  @override
  String get setAppleShortcutSub =>
      'Pass bank messages to Qirsh through Shortcuts';

  @override
  String get setRewardsAndSupport => 'Rewards and support';

  @override
  String get setInviteFriends => 'Invite friends';

  @override
  String get setInviteFriendsSub =>
      'Share your invite code and earn ad-free reports';

  @override
  String get setAdPrivacyOptions => 'Ad privacy options';

  @override
  String get setAdPrivacyOptionsSub => 'Manage your advertising consent';

  @override
  String get setContactUs => 'Contact us';

  @override
  String get setContactUsSub =>
      'Technical support and answers to your questions';

  @override
  String get setAboutQirsh => 'About Qirsh';

  @override
  String get setAboutQirshSub => 'App information and version';

  @override
  String get setCaptureStatus => 'Transaction capture';

  @override
  String get setCaptureStatusSub =>
      'The status of bank messages and the Apple Shortcut';

  @override
  String get setConfirmCaptured => 'Confirm captured transactions';

  @override
  String get setNotifyOnCapture => 'Notify me when a transaction is captured';

  @override
  String get setHideOnLockScreen => 'Hide sensitive details on the lock screen';

  @override
  String get setYourAlerts => 'Your alerts';

  @override
  String get setQirshMessages => 'Qirsh messages and tips';

  @override
  String get setBudget80Alert => 'Alert at 80% of a budget';

  @override
  String get setBudgetOverAlert => 'Alert when a budget is exceeded';

  @override
  String get setDailyReminder => 'Daily reminder';

  @override
  String get setDailyReminderTime => 'Every day at 10 PM';

  @override
  String get setWeeklyReport => 'Weekly report';

  @override
  String get setBillReminders => 'Subscription and bill reminders';

  @override
  String get setGoalCelebrations => 'Goal celebrations';

  @override
  String get setAchievementAlerts => 'Achievement alerts';

  @override
  String get setQuietHours => 'Quiet hours';

  @override
  String get setDisabled => 'Off';

  @override
  String get setEditQuietHours => 'Edit quiet hours';

  @override
  String get setNotificationTools => 'Notification tools';

  @override
  String get setTestNotifications => 'Test Qirsh notifications';

  @override
  String get setTestNotificationsSub =>
      'Send a test notification to this device';

  @override
  String get setMessageCentre => 'Qirsh message centre';

  @override
  String get setMessageCentreSub =>
      'Past notifications, campaigns and announcements';

  @override
  String get setDataTransfer => 'Data transfer';

  @override
  String get setDataTransferSub =>
      'Your financial data stays under your control';

  @override
  String get setImportFile => 'Import a file';

  @override
  String get setImportFileSub =>
      'A CSV from any app, or a ZIP exported by Qirsh';

  @override
  String get setExportCsv => 'Export transactions as CSV';

  @override
  String get setExportCsvSub => 'A simple file with all your transactions';

  @override
  String get setExportAll => 'Export all Qirsh data';

  @override
  String get setExportAllSub => 'A ZIP package you can move and restore';

  @override
  String get setSecurityPrivacy => 'Security and privacy';

  @override
  String get setEncryptedDbPart1 =>
      'Your data on this device is kept in an encrypted database, ';

  @override
  String get setEncryptedDbPart2 =>
      'and its key is stored in the system keychain';

  @override
  String get setPrivacyAndData => 'Privacy and data';

  @override
  String get setPrivacyAndDataSub =>
      'Your data security and the privacy policy';

  @override
  String get setHideAmounts => 'Hide amounts in the interface';

  @override
  String get setExitAndErase => 'Sign out and erase data';

  @override
  String get setExitAndEraseSub => 'Some of these actions cannot be undone';

  @override
  String get setStartOver => 'Start over';

  @override
  String get setStartOverSub => 'Erase local data but keep the account active';

  @override
  String get setSignOut => 'Sign out';

  @override
  String get setDeleteAccount => 'Delete my account and all my data';

  @override
  String get setDeleteAccountSub =>
      'A final action that needs your confirmation';

  @override
  String get setTestNotificationSent =>
      'We sent a test notification from Qirsh.';

  @override
  String get setTestNotificationFailed =>
      'We could not send the test notification.';

  @override
  String get setUnsyncedData => 'Data not saved to the cloud';

  @override
  String get setCancel => 'Cancel';

  @override
  String get setSignOutDiscard => 'Sign out and discard unsaved data';

  @override
  String get setUnsyncedCheckFailed =>
      'We could not check for unsaved data. Please try again.';

  @override
  String get setSignOutFailed =>
      'We could not sign out safely. Please try again.';

  @override
  String get setPhotoUpdated => 'Photo updated.';

  @override
  String get setSave => 'Save';

  @override
  String get setCategoriesSheetIntro =>
      'Add or edit the categories that appear in transactions and reports.';

  @override
  String get setAddCategory => 'Add a category';

  @override
  String get setExpenses => 'Expenses';

  @override
  String get setIncome => 'Income';

  @override
  String get setTransfers => 'Transfers';

  @override
  String get setEditCategory => 'Edit category';

  @override
  String get setCategoryName => 'Category name';

  @override
  String get setIncomeCategory => 'Income category';

  @override
  String get setIcon => 'Icon';

  @override
  String get setColor => 'Colour';

  @override
  String get setEnterCategoryName => 'Enter a category name.';

  @override
  String get setSaveChanges => 'Save changes';

  @override
  String get setAdd => 'Add';

  @override
  String get setDeleteCategoryQ => 'Delete this category?';

  @override
  String get setDeleteCategoryBody =>
      'Its transactions move to “Other” or “Income”, and any linked budget is deleted.';

  @override
  String get setDelete => 'Delete';

  @override
  String get setQuietHoursNote =>
      'We defer scheduled notifications during this period to the first allowed time.';

  @override
  String get setStarts => 'Starts';

  @override
  String get setEnds => 'Ends';

  @override
  String get setAboutApp => 'About the app';

  @override
  String get setAboutBody =>
      'Qirsh tracks spending from bank messages and manual entry. You can move your financial data as CSV files or a ZIP package from the data and privacy section.';

  @override
  String get setOk => 'OK';

  @override
  String get setSupportBody =>
      'For support or feedback, copy the email and send us the problem details, your device type, and the steps to reproduce it.';

  @override
  String get setCopyEmail => 'Copy email';

  @override
  String get setEraseAllQ => 'Erase all data?';

  @override
  String get setEraseAllBody =>
      'All your local data will be erased. This cannot be undone.';

  @override
  String get setErase => 'Erase';

  @override
  String get setSettingsLoadFailed =>
      'We could not load settings. Please try again shortly.';

  @override
  String get setSettings => 'Settings';

  @override
  String get setBack => 'Back';

  @override
  String get setThemeAuto => 'Auto';

  @override
  String get setThemeLight => 'Light';

  @override
  String get setThemeDark => 'Dark';

  @override
  String get setEdit => 'Edit';

  @override
  String get setAppLockFailed =>
      'We could not turn on the lock. Make sure a passcode or biometric is set up on your device.';

  @override
  String get setAppLock => 'App lock';

  @override
  String get setNoBankMessageYet => 'We have not detected a bank message yet';

  @override
  String get setCaptureEnableFailed =>
      'We could not turn on bank capture notifications';

  @override
  String get setNoBankMessagesRecently =>
      'We have not received bank messages for a while';

  @override
  String get setBankCaptureStatus => 'Bank message capture status';

  @override
  String get setCheck => 'Check';

  @override
  String get setBackupFirst => 'Take a backup first if you want to keep it.';

  @override
  String get setToday => 'Today';

  @override
  String get bdgError => 'Something went wrong';

  @override
  String get bdgTabBudgets => 'Budgets';

  @override
  String get bdgTabHistory => 'Budget history';

  @override
  String get bdgTabGoals => 'Goals';

  @override
  String get bdgEmptyBudgetsTitle => 'No budgets yet';

  @override
  String get bdgEmptyBudgetsBody =>
      'Create your first daily, weekly or monthly budget to start tracking.';

  @override
  String get bdgEmptyGoalsTitle => 'No goals yet';

  @override
  String get bdgEmptyGoalsBody =>
      'Add a savings goal so Qirsh can track your progress alongside your budgets.';

  @override
  String get bdgAddGoal => 'Add goal';

  @override
  String get bdgEmptyHistoryTitle => 'The history is empty';

  @override
  String get bdgEmptyHistoryBody =>
      'Pick a period that has budgets, or add a new budget — each day, week or month then appears here as its own record.';

  @override
  String get bdgAddBudget => 'Add budget';

  @override
  String get bdgDeleteTitle => 'Delete this budget?';

  @override
  String get bdgDeleteBody =>
      'The budget limit will be deleted. Your transactions are not affected.';

  @override
  String get bdgDeleteFailed => 'The budget could not be deleted right now.';

  @override
  String get bdgFilterAll => 'All';

  @override
  String get bdgFilterDaily => 'Daily';

  @override
  String get bdgFilterWeekly => 'Weekly';

  @override
  String get bdgFilterMonthly => 'Monthly';

  @override
  String get bdgFilterYearly => 'Yearly';

  @override
  String get bdgStatHistoryCount => 'Budgets on record';

  @override
  String get bdgStatTargetSavings => 'Total target savings';

  @override
  String get bdgStatTotalBudgeted => 'Total budgeted';

  @override
  String get bdgStatActiveGoals => 'Active goals';

  @override
  String get bdgStatProgress => 'Progress';

  @override
  String get bdgStatTotalSaved => 'Total saved';

  @override
  String get bdgStateSafeF => 'On track';

  @override
  String get bdgStateNear => 'Close to limit';

  @override
  String get bdgStateOverF => 'Over limit';

  @override
  String get bdgBudgetsWord => 'Budgets';

  @override
  String get bdgUsageRate => 'Usage';

  @override
  String get bdgActualSpend => 'Actual spend';

  @override
  String get bdgBudgetWord => 'Budget';

  @override
  String get bdgOver => 'Over';

  @override
  String get bdgSafe => 'On track';

  @override
  String get bdgAllExpenses => 'All spending';

  @override
  String get bdgCategory => 'Category';

  @override
  String get bdgSpent => 'Spent';

  @override
  String get bdgRemaining => 'Left';

  @override
  String get bdgLimit => 'Limit';

  @override
  String get bdgSaved => 'Saved';

  @override
  String get bdgPeriodCurrent => 'Current period';

  @override
  String get bdgPeriodOver => 'Period went over';

  @override
  String get bdgPeriodEnded => 'Period ended';

  @override
  String get bdgRecordLive =>
      'This record keeps updating until the period ends.';

  @override
  String get bdgRecordFinal =>
      'This record is calculated from the actual transactions in this period.';

  @override
  String get bdgEditBudget => 'Edit budget';

  @override
  String get bdgPeriodTransactions => 'Transactions in this period';

  @override
  String get bdgNoConfirmedTx =>
      'No confirmed transactions were recorded in this period.';

  @override
  String get bdgCountedOpenAll =>
      'Included in the total — open Transactions to see them all.';

  @override
  String get bdgDailyBudget => 'Daily budget';

  @override
  String get bdgWeeklyBudget => 'Weekly budget';

  @override
  String get bdgYearlyBudget => 'Yearly budget';

  @override
  String get bdgMonthlyBudget => 'Monthly budget';

  @override
  String get bdgTransactionWord => 'transaction';

  @override
  String get bdgGoalDone => 'Goal reached';

  @override
  String get bdgEnvelopeTitle => 'Split your income into envelopes';

  @override
  String get bdgEnvelopeBody =>
      'Enter your salary and split it in one tap — Qirsh works out what you can spend each day';

  @override
  String bdgMoreTxCounted(int count) {
    return '$count more transactions are included in the total — open Transactions to see them all.';
  }

  @override
  String get txnError => 'Something went wrong';

  @override
  String get txnTransactionWord => 'transaction';

  @override
  String get txnFilterPending => 'Filter: pending review';

  @override
  String get txnConfirmAll => 'Confirm all';

  @override
  String get txnTabTransactions => 'Transactions';

  @override
  String get txnTabBills => 'Bills';

  @override
  String get txnEmptyPeriodTitle => 'No transactions in this period';

  @override
  String get txnEmptyPeriodBody =>
      'Change the period, or add a new bank message with the + button.';

  @override
  String get txnConfirmAllTitle => 'Confirm every pending transaction?';

  @override
  String get txnConfirm => 'Confirm';

  @override
  String get txnPickAccount => 'Choose account';

  @override
  String get txnSearchHint =>
      'Search by merchant, category, amount or currency';

  @override
  String get txnClearSearch => 'Clear search';

  @override
  String get txnRangeToday => 'Today';

  @override
  String get txnRangeThisWeek => 'This week';

  @override
  String get txnRangeThisMonth => 'This month';

  @override
  String get txnRangeLastMonth => 'Last month';

  @override
  String get txnRange7 => 'Last 7 days';

  @override
  String get txnRange30 => 'Last 30 days';

  @override
  String get txnRange90 => 'Last 90 days';

  @override
  String get txnRangeThisYear => 'This year';

  @override
  String get txnRangeLastYear => 'Last year';

  @override
  String get txnRangeCustom => 'Custom';

  @override
  String get txnPickRange => 'Choose a period';

  @override
  String get txnFrom => 'From';

  @override
  String get txnTo => 'To';

  @override
  String get txnApplyCustomRange => 'Apply custom period';

  @override
  String get txnKindAll => 'All';

  @override
  String get txnKindExpense => 'Expenses';

  @override
  String get txnKindIncome => 'Income';

  @override
  String get txnKindTransfer => 'Transfers';

  @override
  String get txnPendingReview => 'Pending review';

  @override
  String get txnCategory => 'Category';

  @override
  String get txnFilterByCategory => 'Filter by category';

  @override
  String get txnAllCategories => 'All categories';

  @override
  String get txnBillsSubs => 'Subscriptions';

  @override
  String get txnBillsInstalments => 'Instalments';

  @override
  String get txnAddSub => 'Add subscription';

  @override
  String get txnAddInstalment => 'Add instalment';

  @override
  String get txnLearnBills => 'Learn more about bills';

  @override
  String get txnSubsEmptyTitle => 'Your subscriptions, tracked automatically';

  @override
  String get txnInstEmptyTitle => 'Your instalments, clear every month';

  @override
  String get txnSubsEmptyBody =>
      'Add a subscription yourself, or let it be detected automatically from recurring transactions.';

  @override
  String get txnInstEmptyBody =>
      'Add the instalment with its date and reminder so it appears in Bills before it is due.';

  @override
  String get txnSuggestionsTitle => 'Suggestions from recurring transactions';

  @override
  String get txnHowSubsTitle => 'How does Qirsh track subscriptions?';

  @override
  String get txnHowInstTitle => 'How does Qirsh track instalments?';

  @override
  String get txnHowSubsBody =>
      'Qirsh follows recurring patterns automatically, and you can also add a subscription yourself with its amount, renewal date and reminder.';

  @override
  String get txnHowInstBody =>
      'Add the instalment yourself with its amount, due date and reminder. Remaining balance and instalment count come later.';

  @override
  String get txnTotalMonthlySubs => 'Total monthly subscriptions';

  @override
  String get txnTotalMonthlyInst => 'Total monthly instalments';

  @override
  String get txnActive => 'Active';

  @override
  String get txnPerYear => 'per year';

  @override
  String get txnDueToday => 'Due today';

  @override
  String get txnPaused => 'Paused';

  @override
  String get txnCancelled => 'Cancelled';

  @override
  String get txnCycleWeekly => 'Weekly';

  @override
  String get txnCycleMonthly => 'Monthly';

  @override
  String get txnCycleYearly => 'Yearly';

  @override
  String get txnTotalValueLabel => 'Total value: ';

  @override
  String get txnPaidManuallyLabel => 'Paid manually: ';

  @override
  String get txnAdd => 'Add';

  @override
  String get txnBillsAndSubs => 'Bills & subscriptions';

  @override
  String get txnPeriodSpendTotal => 'Total spend this period';

  @override
  String get txnActiveMonthlySpend => 'Total active monthly spend';

  @override
  String get txnTxForPeriod => 'transactions this period';

  @override
  String get txnTotalSpent => 'Total spent';

  @override
  String get txnActiveSub => 'active subscription';

  @override
  String get txnRunningInst => 'running instalment';

  @override
  String get txnYearlyTotal => 'Yearly total';

  @override
  String get txnSmartInbox => 'Smart review inbox';

  @override
  String get txnReviewTx => 'Review transaction';

  @override
  String get txnHide => 'Hide';

  @override
  String get txnSuspectTxPlural => 'Possible duplicates';

  @override
  String get txnDismissAll => 'Dismiss all';

  @override
  String get txnNoSuspectTx => 'No possible duplicates';

  @override
  String get txnSimilarExists => 'A similar transaction already exists';

  @override
  String get txnSimilarBody =>
      'This transaction matches an existing one in amount, merchant and time.';

  @override
  String get txnTheNew => 'New';

  @override
  String get txnNoClearMerchant => 'No clear merchant';

  @override
  String get txnTheExisting => 'Existing';

  @override
  String get txnDismissDuplicate => 'Dismiss duplicate';

  @override
  String get txnSaveAsNew => 'Save as new';

  @override
  String get txnEditTx => 'Edit transaction';

  @override
  String get txnChangeCategory => 'Change category';

  @override
  String get txnTimeInSms => 'Transaction time in the SMS';

  @override
  String get txnTimeReceived => 'Time the message arrived';

  @override
  String txnDupBannerReview(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count possible duplicates',
      one: '1 possible duplicate',
    );
    return '$_temp0 — tap to review';
  }

  @override
  String get txnDismissAllDupesBody =>
      'Every duplicate alert shown here will be removed. The transactions themselves are not affected, but you will not be able to review them from here again.';

  @override
  String txnTimeSource(String source) {
    return 'Time source: $source';
  }

  @override
  String txnRecurredMonths(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Recurred for $count months',
      one: 'Recurred for 1 month',
    );
    return '$_temp0 · tap to enable';
  }

  @override
  String txnConfirmAllBody(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other:
          '$count transactions will be confirmed with their current categories.',
      one: '1 transaction will be confirmed with its current category.',
    );
    return '$_temp0';
  }

  @override
  String txnOverdueDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days overdue',
      one: '1 day overdue',
    );
    return '$_temp0';
  }

  @override
  String txnInDays(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: 'in $days days',
      one: 'in 1 day',
    );
    return '$_temp0';
  }

  @override
  String txnPerInstalment(String amount) {
    return '$amount / instalment';
  }

  @override
  String txnPaidOfTotal(int paid, int total) {
    return '$paid of $total instalments paid';
  }

  @override
  String txnRemainingInstalments(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count left',
      one: '1 left',
    );
    return '$_temp0';
  }

  @override
  String txnInterestRate(String rate) {
    return 'Interest $rate%';
  }

  @override
  String txnNextInstalment(String due) {
    return 'Next instalment: $due';
  }

  @override
  String txnEstPerMonth(String amount, String currency) {
    return '$amount $currency/mo';
  }

  @override
  String txnSmartInboxCount(int count) {
    return 'Smart review inbox · $count';
  }

  @override
  String txnDismissNAlerts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Dismiss $count alerts?',
      one: 'Dismiss 1 alert?',
    );
    return '$_temp0';
  }

  @override
  String txnDismissAllCount(int count) {
    return 'Dismiss all ($count)';
  }

  @override
  String get subsOverdue => 'Overdue';

  @override
  String get subsToday => 'Today';

  @override
  String subsTabSubs(int count) {
    return 'Subscriptions ($count)';
  }

  @override
  String subsTabInst(int count) {
    return 'Instalments ($count)';
  }

  @override
  String subsMonthlyScoped(String account) {
    return 'Monthly subscriptions · $account';
  }

  @override
  String subsPerYearApprox(String amount) {
    return '≈ $amount/yr';
  }

  @override
  String get subsTitle => 'Subscriptions & bills';

  @override
  String get subsMonthlyTotal => 'Monthly subscriptions';

  @override
  String get subsActiveSubs => 'Active subscriptions';

  @override
  String get subsRunningInst => 'Running instalments';

  @override
  String get subsMonthlyInstCommit => 'Monthly instalment commitment';

  @override
  String get subsEmptyTitle => 'All your subscriptions in one place';

  @override
  String get subsAutoDetected => 'Detected automatically';

  @override
  String get subsAddNewSub => 'Add a new subscription';

  @override
  String get subsMaybeUnused => 'You may not be using this subscription';

  @override
  String get subsInstEmptyTitle =>
      'Your instalments, clear before they fall due';

  @override
  String get subsInstEmptyBody =>
      'Add the instalment with its amount, count and due date.';

  @override
  String get subsTotalInstDebt => 'Total instalment debt';

  @override
  String get subsNearestInst => 'Next instalment due';

  @override
  String get subsAddNewInst => 'Add a new instalment';

  @override
  String rptAnomalyPrivate(String date) {
    return 'Spending on $date was higher than your usual pattern. Review it if you want to know why.';
  }

  @override
  String rptAnomalyDetail(String date, String amount, String ratio) {
    return 'On $date you spent $amount, which is above your daily average by $ratio×.';
  }

  @override
  String rptSpendLower(int percent) {
    return 'You spent $percent% less than the same period before.';
  }

  @override
  String rptSpendHigher(int percent) {
    return 'You spent $percent% more than the same period before.';
  }

  @override
  String rptHighestDayBody(String amount) {
    return 'The highest day in this period reached $amount.';
  }

  @override
  String rptTopCategoryHint(String category) {
    return 'Your biggest spend is on $category. Watch that category first.';
  }

  @override
  String rptMerchantTxCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transactions',
      one: '1 transaction',
    );
    return '$_temp0';
  }

  @override
  String rptVsLastWeek(String sign, String percent) {
    return '$sign $percent% compared with last week';
  }

  @override
  String rptTopCategoryWeek(String category) {
    return 'Top category: $category';
  }

  @override
  String rptBestSavingDay(String date, String amount) {
    return 'Best saving day: $date ($amount)';
  }

  @override
  String rptTopMerchantWeek(String name, String amount) {
    return 'Top merchant: $name ($amount)';
  }

  @override
  String get rptTabOverview => 'Overview';

  @override
  String get rptTabTrends => 'Trends';

  @override
  String get rptTabDetails => 'Details';

  @override
  String get rptUnusualSpend => 'Unusual spending';

  @override
  String get rptVsPrevPeriod => 'Compared with the same period before';

  @override
  String get rptNeedPrevPeriod =>
      'We still need an earlier period with spending in it to show the trend accurately.';

  @override
  String get rptHighestSpendDay => 'Highest spending day';

  @override
  String get rptQuickTip => 'Quick tip';

  @override
  String get rptAddMoreTx =>
      'Add a few more transactions and the suggestions get sharper.';

  @override
  String get rptSelectedPeriod => 'Selected period';

  @override
  String get rptNetPeriodSpend => 'Net spend this period';

  @override
  String get rptSelectedPeriodSpend => 'Spend in the selected period';

  @override
  String get rptTotalExpenses => 'Total expenses';

  @override
  String get rptRefunds => 'Refunds';

  @override
  String get rptNet => 'Net';

  @override
  String get rptThisWeekUsage => 'This week so far';

  @override
  String get rptAverage => 'Average';

  @override
  String get rptHighest => 'Highest';

  @override
  String get rptTotal => 'Total';

  @override
  String get rptByCategory => 'Your spending by category';

  @override
  String get rptByMerchant => 'Your spending at merchants';

  @override
  String get rptTopMerchantsSub => 'Where most of your money went this period';

  @override
  String get rptMerchantsEmpty =>
      'The merchants you spend most at appear here once you have confirmed transactions.';

  @override
  String get rptIncludesRefund => ' · includes refund ';

  @override
  String get rptInsightsTitle => 'Insights & reports';

  @override
  String get rptInsightsSub =>
      'Read your spending as daily trends, categories and merchants.';

  @override
  String get rptDailyAverage => 'Daily average';

  @override
  String get rptHighestDay => 'Highest day';

  @override
  String get rptWeekSummary => 'This week in summary';

  @override
  String bdgPeriodSubtitle(String period, String date) {
    return '$period budget · $date';
  }

  @override
  String bdgPeriodSubtitleLive(String period, String date) {
    return '$period budget · $date · running';
  }

  @override
  String bdgLatestOfTotal(int shown, int total) {
    return 'Latest $shown of $total';
  }

  @override
  String get bdgRemainingPrefix => 'Left ';

  @override
  String bdgToReachSuffix(String currency) {
    return ' $currency to go';
  }

  @override
  String setUnsyncedLedger(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count transaction changes',
      one: '1 transaction change',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedPlanning(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count changes to accounts/budgets/goals/bills',
      one: '1 change to accounts/budgets/goals/bills',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedInbox(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count items in your inbox',
      one: '1 item in your inbox',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedCards(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count cards saved on this device only',
      one: '1 card saved on this device only',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedUnproven(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count financial records not yet uploaded to the cloud',
      one: '1 financial record not yet uploaded to the cloud',
    );
    return '$_temp0';
  }

  @override
  String setUnsyncedConflicts(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count records with unresolved conflicts',
      one: '1 record with an unresolved conflict',
    );
    return '$_temp0';
  }

  @override
  String get setListSeparator => ', ';

  @override
  String setUnsyncedSignOutBody(String list) {
    return 'You have data that was never uploaded to the cloud, and signing out will delete it: $list. Take a backup first if you want to keep it.';
  }

  @override
  String setGapDays(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count days ago',
      one: '1 day ago',
    );
    return '$_temp0';
  }

  @override
  String setGapHours(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: '$count hours ago',
      one: '1 hour ago',
    );
    return '$_temp0';
  }

  @override
  String get setGapToday => 'Today';

  @override
  String setLastCapture(String gap) {
    return 'Last capture: $gap';
  }

  @override
  String setApnsFailed(String message) {
    return 'APNs registration failed: $message';
  }

  @override
  String setCheckShortcutStillOn(String subtitle) {
    return '$subtitle — check the shortcut is still enabled';
  }

  @override
  String get goalDueToday => 'Due today';

  @override
  String goalDaysLeft(int days) {
    String _temp0 = intl.Intl.pluralLogic(
      days,
      locale: localeName,
      other: '$days days left',
      one: '1 day left',
    );
    return '$_temp0';
  }

  @override
  String goalMonthsLeft(int months) {
    String _temp0 = intl.Intl.pluralLogic(
      months,
      locale: localeName,
      other: '$months months left',
      one: '1 month left',
    );
    return '$_temp0';
  }

  @override
  String goalRemainingToReach(String amount, String currency) {
    return '$amount $currency to go';
  }

  @override
  String goalSavedAmount(String amount, String currency) {
    return 'Saved $amount $currency';
  }

  @override
  String goalTargetAmount(String amount, String currency) {
    return 'Target $amount $currency';
  }

  @override
  String get goalPerMonth => '/mo';

  @override
  String get goalOverdue => 'Past its target date';

  @override
  String get goalTotalSavedAll => 'Total saved across all your goals';

  @override
  String get goalTargetLabel => 'Target';

  @override
  String get goalEmptyBody => 'Add your first goal and start filling the jar.';

  @override
  String cardLinkTxTo(String last4) {
    return 'Link a transaction to •••• $last4';
  }

  @override
  String cardTxLinkedTo(String last4) {
    return 'Transaction linked to •••• $last4';
  }

  @override
  String get cardAccountWord => 'Account';

  @override
  String get cardUnassigned => 'Unassigned';

  @override
  String get cardBack => 'Back';

  @override
  String get cardAllCards => 'All cards';

  @override
  String get cardAddCard => 'Add card';

  @override
  String get cardEmptyTitle => 'No cards yet';

  @override
  String get cardEmptyBody =>
      'Cards appear automatically from your bank messages, and you can add one of your own design.';

  @override
  String get cardAddCardCta => 'Add a card';

  @override
  String get cardEdit => 'Edit';

  @override
  String get cardIn => 'In';

  @override
  String get cardOut => 'Out';

  @override
  String get cardAddTx => 'Add transaction';

  @override
  String get cardLinkExistingTx => 'Link an existing transaction';

  @override
  String get cardSearchHint => 'Search by name or amount';

  @override
  String get cardNoTx => 'No transactions';

  @override
  String get accAddAccount => 'Add account';

  @override
  String get accTitle => 'Accounts & wallets';

  @override
  String get accSubtitle =>
      'Each account in its own currency — cash, bank, wallet or card.';

  @override
  String get accDefault => 'Default';

  @override
  String get accUnassignedCards => 'Unassigned cards';

  @override
  String get accUnassignedCardsBody =>
      'Cards that showed up in your messages but are not linked to an account yet.';
}
