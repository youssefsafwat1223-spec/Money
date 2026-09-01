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
      'Qirsh reads bank SMS on your device only to log your transactions automatically. We don\'t read personal messages and nothing leaves your phone.';

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
}
