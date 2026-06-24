# Claude Design Brief: Mali Onboarding Redesign

This brief is for design only. Do not implement Flutter. Preserve current onboarding logic unless a later implementation task explicitly changes it.

## 1. Context

Mali is a personal expense tracking app and AI financial assistant. It helps users understand daily spending by turning bank messages or manually pasted SMS text into categorized transactions, budgets, reports, insights, accounts/cards, and goals. The app is Arabic-first, supports English, must work in RTL and LTR, supports dark/light themes, and has privacy/backup concepts: local-first data, optional encrypted backup, auth identity, and optional AI parsing consent for unknown bank messages.

Mali is not a bank. It should not feel like a banking app that sends money or manages transfers. It is a calm money companion for daily expense tracking.

## 2. Goal Of Onboarding

The onboarding must help a new user understand:

- What Mali does: it turns spending signals into a clear money picture.
- How transactions enter the app: bank SMS sharing/capture, iOS Shortcut, and manual paste fallback.
- Why it is safe/private: processing is local-first; only shared/pasted bank messages are processed; backup is optional and encrypted.
- What setup is required: email/auth, country/base currency, capture method setup, AI consent, optional backup/restore.
- How country/currency affects the experience: base currency, flags, SMS filter keywords, and multi-currency notes.
- Android vs iOS:
  - Android/current flow explains sharing bank SMS to Mali and requests SMS/capture permissions.
  - iOS requires Apple Shortcuts Automation with currency keyword filtering; manual paste remains fallback.
- Why backup/auth matters: account identifies the user and enables sync/backup; backup is optional and protected by passphrase/recovery code.
- What happens after onboarding: the user lands in the app with capture ready, or with manual paste as a fallback, and ideally has seen the first captured transaction.

Important product preference to respect in design: use an email-first required sign-in gate as the primary flow. Do not make "continue without account" prominent or primary unless explicitly asked. If the current app still has guest logic, treat it as implementation compatibility, not the desired design direction.

## 3. Required Onboarding Screens

Design the following screens page by page. Screens can be grouped as a stepped flow, but every state must be represented clearly.

### 1. Splash / Launch

- Purpose: premium Mali brand arrival while the app loads session/catalog.
- Main headline: `مالي`
- Supporting copy: optional short line, e.g. `فلوسك أوضح، بهدوء.`
- Primary action: none.
- Secondary action: none.
- Visual asset needed: animated/static Mali mark concept, subtle loading indicator.
- Icon/illustration ideas: geometric Mali mark, calm finance-safe glow.
- States needed: dark primary; light variant optional.
- Must not invent: onboarding decisions or permissions on splash.

### 2. Language Selection

- Purpose: let the user explicitly choose Arabic or English before the rest of onboarding.
- Main headline: `اختَر لغة التجربة`
- Supporting copy: `تقدر تغيّرها لاحقاً من الإعدادات.`
- Primary action: `المتابعة بالعربية`
- Secondary action: `Continue in English`
- Visual asset needed: globe/language card with RTL/LTR hint.
- States needed: selected language, disabled/loading if needed.
- Must not invent: more languages than Arabic/English.

Current code note: no standalone language screen exists today; language comes from settings and defaults to Arabic.

### 3. Welcome / Value Proposition

- Purpose: explain Mali in one human sentence.
- Main headline: `مساعدك المالي اليومي`
- Supporting copy: `مالي يحوّل رسائل البنك والمصروفات اليومية لصورة واضحة: تصنيف، ميزانية، وتنبيه ذكي وقت الحاجة.`
- Primary action: `ابدأ`
- Secondary action: none or very subtle `اعرف كيف يعمل`.
- Visual asset needed: phone preview showing transaction becoming a clear categorized row.
- Icon/illustration ideas: receipt -> category -> insight line.
- States needed: none.
- Must not invent: bank transfer/payment features.

### 4. How Transactions Enter Mali

- Purpose: explain capture channels before asking permissions.
- Main headline: `اختَر أسهل طريقة لإضافة المصروفات`
- Supporting copy: `مشاركة رسالة بنك، اختصار iOS، أو لصق يدوي. أنت دائماً تراجع وتعدّل.`
- Primary action: `التالي`
- Secondary action: `سأضيف يدوياً لاحقاً` if required by current logic, but not visually dominant.
- Visual asset needed: three-channel diagram: SMS/share, shortcut, paste.
- Icon/illustration ideas: message bubble, phone shortcut, paste clipboard.
- States needed: Android copy, iOS copy.
- Must not invent: automatic bank account linking.

### 5. Country And Currency Selection

- Purpose: set base currency and SMS keyword context.
- Main headline: `بلدك وعملتك الأساسية`
- Supporting copy: `نستخدمها لعرض الأرقام، الأعلام، وكلمات فلترة رسائل البنك.`
- Primary action: `حفظ والمتابعة`
- Secondary action: `تغيير لاحقاً من الإعدادات`
- Visual asset needed: country list/search, flag avatar, currency chip.
- Icon/illustration ideas: globe, flag, currency mark.
- States needed: selected, search, no search results.
- Must not invent: exchange-rate conversion. Current app has per-currency logic and no universal FX promise.

### 6. Required Email/Auth

- Purpose: establish identity before setup.
- Main headline: `كمّل بالبريد الإلكتروني`
- Supporting copy: `نستخدمه لتأمين حسابك وربط إعداداتك. بياناتك المالية تظل تحت سيطرتك.`
- Primary action: `إرسال رمز الدخول`
- Secondary actions: Apple/Google can appear as alternative sign-in methods if needed; keep email first.
- Visual asset needed: secure login card, trust row.
- Icon/illustration ideas: mail, lock, shield.
- States needed: empty email, invalid email, sending/loading, provider unavailable, auth error.
- Must not invent: passwords if current auth uses OTP/provider sign-in.

Current code note: Apple, Google, email OTP, and guest paths exist. Desired design should not promote guest.

### 7. OTP Verification

- Purpose: verify email code.
- Main headline: `اكتب رمز الدخول`
- Supporting copy: `أرسلنا رمزاً من 6 أرقام إلى بريدك.`
- Primary action: `تأكيد الرمز`
- Secondary action: `إرسال الرمز مرة أخرى`
- Visual asset needed: 6-digit field component.
- Icon/illustration ideas: mail-check, secure code.
- States needed: loading, invalid code, resend timer, resend success.
- Must not invent: password reset flow.

### 8. Privacy And Data Safety

- Purpose: build trust before permissions/AI.
- Main headline: `بياناتك تبدأ على جهازك`
- Supporting copy: `مالي يعالج الرسائل التي تشاركها أو تلصقها فقط. النسخ الاحتياطي اختياري ومشفّر.`
- Primary action: `فهمت`
- Secondary action: `اقرأ التفاصيل`
- Visual asset needed: privacy shield/safe illustration.
- Icon/illustration ideas: shield, lock, phone, cloud with key.
- States needed: AI consent on/off explanation.
- Must not invent: claim that all AI processing is offline if current code can send sanitized unknown bank text after consent.

### 9. Capture Method Setup

- Purpose: choose/show platform-specific capture setup.
- Main headline: Android: `شارك رسالة البنك مع مالي`; iOS: `جهّز اختصار آبل`
- Supporting copy: explain the platform-specific limitation clearly.
- Primary action: Android `تفعيل الالتقاط`; iOS `إعداد الاختصار`
- Secondary action: `ألصق رسالة يدوياً`
- Visual asset needed: platform-aware setup card.
- Icon/illustration ideas: Android message/share, iOS shortcut automation, manual paste.
- States needed: Android, iOS, manual-only fallback.
- Must not invent: bank API connection or account login.

### 10. Android SMS Permission / Share Explanation

- Purpose: clarify what permission/share access means.
- Main headline: `نحتاج رسائل البنك فقط`
- Supporting copy: `نستخدم الرسائل البنكية لتسجيل العمليات. لا نقرأ رسائلك الشخصية، وتقدر تستخدم اللصق اليدوي بدل ذلك.`
- Primary action: `السماح والمتابعة`
- Secondary action: `استخدام اللصق اليدوي`
- Visual asset needed: permission card with allowed/not-allowed bullets.
- Icon/illustration ideas: message, shield, warning.
- States needed: permission requested, granted, denied, denied permanently, manual fallback.
- Must not invent: reading all SMS silently without user control.

### 11. iOS Shortcut Setup Explanation

- Purpose: make the hardest setup flow understandable and reassuring.
- Main headline: `اختصار iOS مرة واحدة`
- Supporting copy: `Apple لا تسمح بقراءة رسائل البنك مباشرة، لذلك نستخدم Shortcuts لإرسال الرسائل المطابقة لمالي.`
- Primary action: `افتح Shortcuts`
- Secondary action: `ألصق رسالة يدوياً`
- Visual asset needed: guided step cards, keyword chip, progress.
- Icon/illustration ideas: shortcut tile, message contains keyword, run immediately, send to Mali.
- States needed: not started, in progress, copied keyword, setup complete, verify waiting, failed/incomplete.
- Must not invent: deep links that are not currently supported unless marked conceptual.

### 12. Manual Paste Fallback

- Purpose: assure users they can start without automation.
- Main headline: `ابدأ بلصق رسالة واحدة`
- Supporting copy: `انسخ رسالة البنك والصقها هنا. مالي يحللها ويعرضها للمراجعة.`
- Primary action: `تحليل الرسالة`
- Secondary action: `سأفعل لاحقاً`
- Visual asset needed: SMS text area mock with parsed preview.
- Icon/illustration ideas: paste clipboard, receipt, category chip.
- States needed: empty, parsing/loading, parse failed, parsed success.
- Must not invent: importing full bank statements.

### 13. Backup Explanation / Restore

- Purpose: explain optional encrypted backup and restore if backup exists.
- Main headline: `نسخة مشفّرة لا يقرأها أحد غيرك`
- Supporting copy: `اختَر كلمة مرور للنسخ الاحتياطي. لو فقدتها وفقدت رمز الاسترداد، لا يمكننا استعادة البيانات.`
- Primary action: `تفعيل النسخ الاحتياطي` or `استعادة النسخة`
- Secondary action: `ابدأ بدون نسخ احتياطي`
- Visual asset needed: encrypted cloud + key/recovery code.
- Icon/illustration ideas: cloud lock, key, recovery card.
- States needed: guest gate, enabled, disabled, loading, error, recovery code generated, restore password error.
- Must not invent: server-readable backups.

### 14. AI Consent

- Purpose: explain optional AI suggestions honestly.
- Main headline: `اقتراحات أذكى للبنوك غير المعروفة`
- Supporting copy: `عند موافقتك، قد نرسل نصاً معقّماً بدون أرقام بطاقات أو أسماء شخصية لتحسين التحليل.`
- Primary action: `تفعيل الاقتراحات`
- Secondary action: `ليس الآن`
- Visual asset needed: sanitized message before/after visual.
- Icon/illustration ideas: sparkle, mask/redaction, category suggestion.
- States needed: consent off, consent on, learn-more expanded.
- Must not invent: AI advisor features outside categorization/parsing support.

### 15. First Transaction / Success

- Purpose: show the app worked and teach review/edit.
- Main headline confirmed: `أول عملية اتسجّلت`
- Main headline pending: `محتاجة تأكيد سريع`
- Supporting copy: `راجع التصنيف والمبلغ مرة واحدة. بعدها هتلاقي مصروفاتك أوضح.`
- Primary action: confirmed `ادخل مالي`; pending `راجع العملية`
- Secondary action: `غيّر التصنيف`
- Visual asset needed: polished transaction card with amount/category/source.
- Icon/illustration ideas: receipt, check, category avatar.
- States needed: loading, pending review, confirmed, error fallback.
- Must not invent: automatic correctness guarantee.

### 16. Completion / Start Using Mali

- Purpose: close onboarding and orient user to the app.
- Main headline: `جاهز تبدأ`
- Supporting copy: `تقدر تضيف يدوياً، تراجع الرسائل، وتشوف ميزانيتك من الرئيسية.`
- Primary action: `ادخل مالي`
- Secondary action: `راجع الإعداد`
- Visual asset needed: calm success/start illustration.
- States needed: with capture complete, with manual-only setup, with skipped backup.
- Must not invent: dashboard details beyond existing app concepts.

## 4. Visual Direction

Mali onboarding should feel:

- Premium, calm, trustworthy.
- Financially clear: numbers are readable and tabular.
- Smart, but not loud about AI.
- Human-crafted, not template-generated.
- Arabic-first and RTL-native.
- Modern but not childish.
- Rich with purposeful visuals, not decorative blobs.
- Distinct from Payvo and generic fintech clones.

Use a dark-mode-first foundation with elegant depth, strong typography, restrained accent color, and enough whitespace to make setup feel manageable.

## 5. Design System Notes

- Design mobile-first using iPhone-size frames.
- Start with Arabic RTL screens; add English/LTR notes or variants where possible.
- Dark mode primary; light mode optional preview.
- Use generous spacing, strong headline hierarchy, compact support copy.
- Use clear cards, bottom sheets, step indicators, and tactile buttons.
- Use meaningful icons and simple vector illustrations.
- Use stable touch targets and small-screen safe layouts.
- Use LTR islands for email, OTP, currency codes, recovery codes, and keywords.
- Do not use external copyrighted logos.
- Do not use fake app features.

## 6. Visual Assets Needed

- Mali abstract finance shield / safe visual.
- SMS capture visual.
- Manual paste visual.
- AI categorization visual.
- Budget/report teaser visual, only as future value context.
- Privacy/backup visual.
- iOS Shortcut guide visual.
- Country/currency selector visual.
- First transaction success/start visual.
- Email OTP trust visual.
- Permission explanation visual.

## 7. Icons Needed

- Wallet.
- Receipt.
- SMS/message.
- AI sparkle/brain.
- Lock/privacy.
- Cloud backup.
- Globe/language.
- Currency.
- Notification.
- Shield.
- Check.
- Warning.
- Phone shortcut.
- Manual paste.
- Mail.
- Key/recovery code.
- Flag/country.
- Category/tag.

## 8. Content Requirements

Arabic should be natural, warm, and simple. Use Egyptian-friendly Modern Arabic without sounding robotic. Avoid overpromising automation.

Suggested Arabic copy:

- `مساعدك المالي اليومي`
- `حوّل رسائل البنك لمصروفات واضحة في ثواني.`
- `بياناتك تبدأ على جهازك.`
- `نستخدم الرسائل التي تشاركها أو تلصقها فقط.`
- `كمّل بالبريد الإلكتروني`
- `أرسلنا رمز دخول آمن لبريدك.`
- `اختَر بلدك وعملتك الأساسية`
- `العملة تساعدنا نضبط الأرقام وكلمات فلترة الرسائل.`
- `اختصار iOS مرة واحدة`
- `Apple لا تسمح بقراءة الرسائل مباشرة، لذلك نستخدم Shortcuts بطريقة آمنة وواضحة.`
- `ألصق رسالة بنك بدلاً من ذلك`
- `أول عملية اتسجّلت`
- `راجعها بسرعة، وبعدها ادخل مالي.`

Suggested English copy:

- `Your daily money companion`
- `Turn bank messages into clear expenses in seconds.`
- `Your data starts on your device.`
- `We only process messages you share or paste.`
- `Continue with email`
- `We sent a secure login code to your email.`
- `Choose your country and base currency`
- `Currency helps Mali format numbers and filter bank messages.`
- `One-time iOS Shortcut setup`
- `Apple does not allow direct SMS access, so Mali uses Shortcuts clearly and securely.`
- `Paste a bank message instead`
- `Your first transaction is ready`
- `Review it once, then start using Mali.`

## 9. Constraints

Claude Design must not:

- Invent features not in the app.
- Invent fake permissions.
- Invent fake banking features.
- Turn Mali into a bank.
- Copy Payvo.
- Use real Netflix/bank/payment logos unless assets already exist and use is explicitly approved.
- Use copyrighted brand logos.
- Use generic AI blobs.
- Overload screens with text.
- Hide important setup steps.
- Ignore RTL.
- Ignore small screens.
- Claim backup is readable by Mali.
- Claim AI never sends data if AI consent can send sanitized unknown-bank text.
- Promise automatic capture on iOS without Shortcut setup.
- Promise FX conversion or bank account linking.

## 10. Implementation Notes For Later

- This is design only.
- Final Flutter implementation will happen later.
- Design should preserve the current route/session contracts unless a later implementation task explicitly changes them.
- Do not require backend changes.
- Do not require new packages unless marked optional.
- Keep auth providers, OTP flow, backup crypto, capture bridge, parser, repositories, database, Supabase functions, and business logic unchanged.
- If designing an email-first required gate, document that it is a product direction that may require later Flutter logic cleanup because current code still has guest paths.
- The setup flow may be visually split into clearer steps, but must map back to current concepts: country/currency, auth/OTP, capture method, AI consent, backup/restore, verify/listening, first transaction.
