# Mali — Onboarding Masterplan

**The complete activation experience for an AI Financial Assistant.**

> Author role: Head of Product / Senior UX + Growth.
> Status: Design spec (forward-looking). Grounds itself in the existing Flutter
> implementation under `app/lib/features/onboarding/` and `app/lib/features/capture/`,
> and the iOS capture pipeline in `app/ios/SHORTCUT_SETUP.md`.
> Markets: 🇪🇬 EG · 🇸🇦 SA · 🇦🇪 AE · 🇰🇼 KW · 🇶🇦 QA · 🇧🇭 BH · 🇴🇲 OM · 🇯🇴 JO.
> Platforms: Android (direct SMS) · iPhone (Shortcut automation).

---

## 0. The One Sentence

> **Get the first real transaction on screen in under 2 minutes — then earn the right to ask for anything else.**

Everything in this document serves that sentence. Budgets, reports, goals, gamification,
premium — all of it is *post-activation*. If a screen does not move the user closer to
their first captured transaction, it does not belong in onboarding.

---

# Phase 1 — Research-Based Strategy

## 1.1 What top finance apps get right

| App | The move worth stealing | How Mali applies it |
|---|---|---|
| **Cash App** | One question per screen; relentless momentum. | Never two decisions on one screen. |
| **Revolut** | Asks for *goals* early, personalizes the dashboard from the answer. | We ask **country + bank**, not goals — because our value is automatic capture, not planning. |
| **YNAB** | Teaches the mental model. | We *show* the model in one animation (SMS → transaction), we don't lecture. |
| **SAY (direct competitor)** | Ruthlessly short onboarding, "zero-effort" promise, SMS auto-tracking. | We match the brevity and beat them on **trust** (no account, on-device) and **first-capture proof**. |
| **Wafeer (direct competitor)** | Saudi-tuned, automatic. | They gate reports behind a 30-day trial/paywall *early*. We never paywall onboarding. |

**The synthesis:** the winners front-load *value* and back-load *friction*. They make the
product prove itself before asking the user to invest (account, money, configuration).

## 1.2 Why onboarding fails

Industry benchmark: **~68% of fintech users drop off during onboarding.** The causes,
ranked by how often they kill Mali specifically:

1. **Permission asked cold.** Requesting SMS access on screen 1 with no rationale → instant deny → dead app. (This is the single biggest risk for an SMS-based app.)
2. **Time-to-value too long.** User does work (grants permission, sets up a Shortcut) and sees… an empty dashboard. No payoff = no reason to return.
3. **Trust gap.** "An app that reads my bank messages" is a scary sentence. If trust isn't established *before* the ask, the permission is denied on principle.
4. **Configuration overload.** Asking for country + currencies + subscriptions + categories before the user has seen a single transaction. (The current `_CountryPage` collects extra currencies *and* subscriptions up front — see §10 recommendation to defer.)
5. **Dead ends on failure.** iOS Shortcut setup is fiddly. If step 6 fails and there's no recovery path, the user is gone.
6. **No "next".** Even after success, users don't know what to do. The aha moment must point somewhere.

## 1.3 What makes users trust a finance app

Trust is **shown, not claimed**. Ranked by impact:

- **No account required.** The strongest trust signal we own. "No email, no password, no sign-up" removes the #1 fear (data harvesting). This is also our biggest wedge vs SAY/Wafeer.
- **On-device processing, stated concretely.** Not "we're secure" — but "your messages are read and parsed *on your phone*. They never leave it." Specific > vague.
- **No bank credentials, ever.** "We never ask for your bank login or password." Kills the phishing fear.
- **Show the mechanism.** A 3-second animation of `SMS → parsed transaction` demystifies the magic. Hidden magic feels like surveillance; visible magic feels like a tool.
- **Reversibility.** "You can delete everything in one tap." Control = trust.
- **Local social proof.** Real bank names the user recognizes (Al Rajhi, SNB, CIB, NBK) in the demo. "It knows my bank" → "it's built for me."

## 1.4 What creates the "Aha Moment"

> The aha moment for Mali is **not** "I installed an app."
> It is **"I did nothing, and my real Al Baik purchase appeared, correctly categorized, by itself."**

Three ingredients, all required:

1. **It's real.** Their actual transaction, their actual bank, their actual amount — not a demo.
2. **It was effortless.** They didn't type it. The app did the work. This is the emotional core: *relief*.
3. **It was correct.** Right amount, right merchant, sensible category. Competence = trust = retention.

The entire onboarding is a delivery mechanism for this one moment. Optimize for **time-to-first-real-transaction**, not time-to-finish-onboarding.

## 1.5 Mali's onboarding philosophy

1. **Earn each ask.** Show value → then request. Never request → then promise.
2. **One job per screen.** One decision, one action. (Cash App rule.)
3. **The first transaction is the product.** Treat reaching it as the only KPI of onboarding.
4. **Trust is a feature, displayed early and repeatedly** — because our whole pitch is "let a stranger's app read your bank messages."
5. **Defer everything deferrable.** Extra currencies, subscriptions, categories, goals, account/backup → *after* first capture, contextually.
6. **No dead ends.** Every failure state has a recovery path and a human-toned explanation.
7. **Platform honesty.** Android and iOS are genuinely different. Don't pretend otherwise — design each natively.

---

# Phase 2 — Complete User Journey

```
                          ┌─────────────────────┐
                          │   INSTALL (store)   │
                          └──────────┬──────────┘
                                     ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  ACT 1 — TRUST & VALUE  (no permissions, ~30s, skippable)      │
   │  S1 Welcome  →  S2 How it works  →  S3 Privacy promise         │
   └──────────────────────────────┬───────────────────────────────┘
                                  ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  ACT 2 — LOCALIZE  (1 decision)                                │
   │  S4 Country & bank pick  (currency auto-derived)               │
   └──────────────────────────────┬───────────────────────────────┘
                                  ▼
                       ┌──────────platform──────────┐
                       ▼                             ▼
   ┌────────────────────────────┐   ┌────────────────────────────────┐
   │  ACT 3a — ANDROID          │   │  ACT 3b — iPHONE                │
   │  S5a Rationale             │   │  S5b Why no auto-read           │
   │  S6a System SMS permission │   │  S6b Shortcut wizard (guided)   │
   │  S7a Live listening state  │   │  S7b Verification ("send test") │
   └─────────────┬──────────────┘   └────────────────┬───────────────┘
                 └────────────────┬───────────────────┘
                                  ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  ★ THE AHA MOMENT  ★                                           │
   │  S8 First Captured Transaction  (celebration + trust + next)   │
   └──────────────────────────────┬───────────────────────────────┘
                                  ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  ACT 4 — REVIEW & LAND                                          │
   │  S9 Smart Inbox intro (if any uncertain)  →  S10 Dashboard      │
   └────────────────────────────────────────────────────────────────┘

   Cross-cutting (event-driven, not linear):
   • Bank Discovery sheet  — fires when AI sees an unrecognized sender
   • Account/Backup nudge  — fires AFTER 3–5 captures, never in onboarding
```

**Screen count to first value:** Android = 8 taps to aha; iPhone = ~10 (Shortcut adds steps).
**Target wall-clock to aha:** Android < 90s, iPhone < 150s.

---

# Phase 3 — Screen-by-Screen Design

> Copy is given **AR (primary, RTL)** then *EN*. AR is the default locale; the app is
> Arabic-first. Existing l10n keys are referenced where they already exist
> (e.g. `welcomeTitle`, `noTyping`, `dataStaysOnDevice`).

---

### S1 — Welcome
- **Objective:** Establish identity + the core promise in 5 seconds. Zero friction.
- **Headline (AR):** «فلوسك بتتسجّل لوحدها.» — *EN:* "Your money tracks itself."
- **Subheadline (AR):** «مساعدك المالي الذكي — يقرأ رسائل بنكك ويسجّل كل عملية تلقائياً.» — *EN:* "Your AI financial assistant — reads your bank's SMS and logs every transaction automatically."
- **Primary CTA:** «يلّا نبدأ» / "Get started"
- **Secondary CTA:** «عندي حساب / استعادة نسخة» / "Restore a backup" (tiny, bottom)
- **Illustration:** Mali logo (existing `MaliLogo`) with a soft animated coin/receipt drifting into a card. Premium, no emoji (per brand).
- **Trust chip (persistent):** «بالكامل على جهازك · بدون حساب» / "On-device · No account" (reuse `secureOnDevice`).
- **Empty / Success / Failure:** N/A (static). If returning user with backup detected → route to S-Restore instead.

### S2 — How It Works (the mechanism)
- **Objective:** Demystify the "magic" → convert fear into understanding. This *is* the trust builder.
- **Headline (AR):** «من رسالة… لعملية.» — *EN:* "From a message… to a transaction." (reuse `smsToTx`)
- **Subheadline (AR):** «بنك يبعتلك SMS، مالي يقرأها ويطلّعلك العملية مصنّفة — وانت مش بتعمل حاجة.» — *EN:* "Your bank sends an SMS, Mali reads it and turns it into a categorized transaction — hands-free."
- **Illustration:** The existing animated `_MessageBubble → _FlowConnector → _ClassifiedTransactionCard` sequence. Keep it; it's excellent and on-message.
- **Primary CTA:** «التالي» / "Next"
- **Secondary CTA:** «تخطّي» / "Skip"
- **Note row:** local-processing + privacy-first chips (reuse `localProcessing`, `privacyFirst`).

### S3 — Privacy Promise
- **Objective:** Convert the "scary" into the "selling point." Make the wedge explicit.
- **Headline (AR):** «بياناتك متطلعش من جهازك.» — *EN:* "Your data never leaves your phone." (reuse `dataStaysOnDevice`)
- **Three tiles (reuse `privacyRule1/2/3`):**
  - «بنقرأ الرسالة على جهازك بس — متتخزّنش ولا تتبعت.» / "Read on-device only — never stored or sent."
  - «عمرنا ما نطلب باسوورد البنك.» / "We never ask for your bank password."
  - «امسح كل حاجة في ضغطة واحدة.» / "Delete everything in one tap."
- **Primary CTA:** «تمام، كمّل» / "Got it, continue"
- **Secondary CTA:** «سياسة الخصوصية» / "Privacy policy" (link)

> **Cut from Act 1:** the current `_VaultPage` (savings gamification). It's a great screen
> — but it sells a *future* feature before the user has a single transaction. Move it to a
> post-activation tour (§10). Onboarding's job is capture, not motivation-yet.

### S4 — Country & Bank
- **Objective:** The single configuration decision. Currency is *derived*, not asked.
- **Headline (AR):** «انت فين، وبتتعامل مع أنهي بنك؟» — *EN:* "Where are you, and which bank?"
- **Subheadline (AR):** «عشان نفهم رسائل بنكك ونعرف عملتك تلقائياً.» — *EN:* "So we can read your bank's messages and set your currency automatically."
- **Interaction:** Country picker (existing `_showCountryPicker`, 8 markets) → then a bank multi-select seeded by country (e.g. SA → Al Rajhi, SNB, Alinma…; EG → CIB, NBE, QNB…).
- **Currency:** auto-set from country. Multi-currency users handled later (see iOS §5, and defer extra-currency picker to post-onboarding).
- **Primary CTA:** «كمّل» / "Continue"
- **Empty state:** no bank selected → CTA disabled with hint «اختار بنك واحد على الأقل» / "Pick at least one bank."
- **Success:** selected banks become the **sender allowlist** the parser/discovery uses.
- **Failure:** bank not listed → inline «مش لاقي بنكك؟ كمّل، وهنكتشفه أول ما توصلك رسالة.» / "Bank not listed? Continue — we'll discover it from your first message." (hooks into Phase 8.)

> **Deferred from S4:** the current screen also collects *additional currencies* and
> *active subscriptions*. Both are pre-transaction configuration with no payoff yet → move
> to post-activation (§10).

### S5 / S6 / S7 — platform-specific (see Phase 4 Android, Phase 5 iPhone).

### S8 — First Captured Transaction (see Phase 6 — the most important screen).

### S9 — Smart Inbox intro (see Phase 7).

### S10 — Dashboard landing
- **Objective:** Orient, don't overwhelm. Show the one transaction + one clear next action.
- **Headline (AR):** «أهلاً بيك في مالي 👛» (no emoji per brand → use icon) / "Welcome to Mali."
- **State:** the captured transaction(s) sit at the top; everything else is calm/empty with gentle prompts.
- **Primary next action (contextual, ONE only):** "أضف بنك تاني" *or* "فعّل النسخ الاحتياطي" *or* "اعمل أول هدف ادخار" — chosen by what's most valuable for that user, shown as a single dismissible card.

---

# Phase 4 — Android Flow (direct SMS capture)

Android is our **best-case path**: we can read SMS directly via the `RECEIVE_SMS` /
`READ_SMS` permission (`android_sms_capture_service.dart`, `sms_background_handler.dart`).
The whole game is **not blowing the permission request.**

### Timing — the golden rule
**Never** request the SMS permission on first launch. Request it **only** at S6a, *after*
S2 (mechanism) and S3 (privacy) have done their job. Pre-permission rationale lifts grant
rates dramatically vs a cold system dialog.

### S5a — Permission rationale (pre-prompt)
- **Headline (AR):** «محتاجين إذن نقرأ رسائل البنك بس.» — *EN:* "We just need permission to read bank messages."
- **Body:** «مالي بيقرأ رسائل البنك على جهازك عشان يسجّل عملياتك تلقائياً. مش بنقرأ رسائلك الشخصية، ومفيش حاجة بتطلع برّه الجهاز.» / "Mali reads bank SMS on your device to log transactions automatically. We don't read your personal messages, and nothing leaves your phone."
- **Visual:** a single SMS morphing into a transaction card (echo of S2 — consistency reinforces understanding).
- **Primary CTA:** «اسمح بالوصول» / "Allow access" → triggers the **system** dialog.
- **Secondary CTA:** «ليه محتاجين الإذن ده؟» / "Why this permission?" → expandable, not a new screen.

### S6a — System permission dialog
- The OS dialog itself. Because S5a primed it, the user arrives expecting it.
- **If granted →** go straight to S7a.
- **If denied (first time) →** soft recovery screen: «من غير الإذن ده مش هنقدر نسجّل تلقائياً. تقدر تسمح دلوقتي، أو تستخدم اللصق اليدوي.» / "Without this we can't auto-capture. Allow now, or use manual paste." Two CTAs: **Try again** / **Manual paste** (`manual_paste_screen.dart`).
- **If denied permanently (don't-ask-again) →** deep-link to system Settings with a 3-step illustrated guide.

### S7a — Live listening / "arm the trap"
- **Objective:** Bridge the gap between *permission granted* and *first transaction* so the empty wait doesn't feel broken.
- **Headline (AR):** «جاهزين. اعمل أي عملية بكارت بنكك.» — *EN:* "We're armed. Make any card purchase."
- **State:** an animated "listening" pulse + «بنستنى أول رسالة من بنكك…» / "Waiting for your first bank message…"
- **Accelerator (critical):** «معندكش عملية جديدة دلوقتي؟ هات آخر رسالة بنك من رسائلك.» / "No new purchase right now? Pull your latest bank SMS." → with permission we can **backfill the most recent bank SMS already in the inbox** and parse it immediately. *This is how Android hits the 2-minute target even if the user isn't shopping.*
- **Testing flow:** offer a "demo message" button only as a last resort (clearly labeled as a sample) so the user sees the pipeline work even with zero bank SMS.
- **On capture →** push S8 immediately with celebration.

### Android first-transaction experience
Because capture is automatic and backgrounded, the ideal path is: user grants permission →
we instantly parse the **latest existing bank SMS** → S8 fires within seconds. The user
"did nothing" and sees a real transaction. That's the aha, delivered in well under 2 minutes.

---

# Phase 5 — iPhone Flow (Shortcut automation)

iOS **cannot read SMS** — there is no API. Pretending otherwise breaks trust. We turn the
limitation into a guided, almost-automatic setup using the **"Post Bank Status"** App Intent
that already ships in `ios/BankMessageShortcuts/BankMessageShortcuts.swift`, backed by the
App Group FIFO queue (`group.com.example.money_companion.shared`).

### S5b — Why iPhone is different (honesty screen)
- **Headline (AR):** «على الآيفون، بنعمل إعداد بسيط مرة واحدة.» — *EN:* "On iPhone, a quick one-time setup."
- **Body:** «آبل مبتسمحش لأي تطبيق يقرأ الرسائل تلقائياً (وده كويس لخصوصيتك). بدل كده، هنعمل اختصار يبعت رسايل البنك لمالي لوحدها.» / "Apple doesn't let any app read messages automatically (good for your privacy). Instead, we'll set up a Shortcut that forwards bank messages to Mali by itself."
- **Reframe:** position the limitation as *Apple protecting you*, and our Shortcut as the clever workaround. The user feels safe, not shortchanged.
- **Primary CTA:** «نعمل الاختصار» / "Set up the Shortcut"
- **Secondary CTA:** «هعمله بعدين (لصق يدوي دلوقتي)» / "Later (manual paste for now)"

### S6b — Shortcut Wizard (guided, country-aware)
Reuse and elevate the existing `IosShortcutScreen` 8-step guide. Improvements:

- **One step per screen** with a screenshot/GIF of the actual iOS Shortcuts UI for each step (not all 8 in a list — that's a wall).
- **Country/currency-specific filter keyword** auto-filled. The Shortcut filters Messages by **currency code or amount keyword**, and we inject the right one from S4:
  - SA → `SAR` / «ريال» · AE → `AED` / «درهم» · EG → `EGP` / «جنيه» · KW → `KWD` / «دينار» · QA → `QAR` / «ريال» · BH → `BHD` / «دينار» · OM → `OMR` / «ريال» · JO → `JOD` / «دينار».
- **Multi-currency users:** allow adding more than one filter keyword (e.g. an expat in UAE who also gets EGP messages). Wizard step: «بتستلم رسايل بعملات تانية؟ زوّد كلمة كمان.» / "Get messages in other currencies? Add another keyword."
- **Copy-to-clipboard** for the keyword so the user just pastes into the Shortcuts app.
- **"Open Shortcuts app" deep link** so the handoff is one tap.

Wizard step copy (condensed, mirrors `_getSteps`):
1. «احذف أي أتمتة قديمة للتطبيق.» / "Delete any old automation."
2. «أتمتة جديدة (+) → Message.» / "New Automation (+) → Message."
3. «فلتر: محتوى الرسالة يحتوي **SAR**.» / "Filter: message contains **SAR**." *(injected per country)*
4. «فعّل Run Immediately.» / "Enable Run Immediately."
5. «New Blank Automation.» 
6. «أضف إجراء **Post Bank Status** ومرّر متغيّر Shortcut Input.» / "Add **Post Bank Status**, pass Shortcut Input."
7. «اقفل Show When Run (يشتغل في الخلفية).» / "Disable Show When Run."
8. «احفظ.» / "Save."

### S7b — Verification step (don't trust, verify)
- **Objective:** Prove the Shortcut actually works *before* declaring success. iOS setup silently fails constantly — this step is non-negotiable.
- **Headline (AR):** «نتأكد إنه شغّال.» — *EN:* "Let's confirm it works."
- **Flow:** «ابعت لنفسك رسالة فيها كلمة SAR (أو هات آخر رسالة بنك)، وارجع للتطبيق.» / "Send yourself a message containing SAR (or grab your latest bank SMS), then come back."
- **Live state:** the screen polls the App Group queue (`consumePendingSharedMessages`) and shows «بنستنى أول رسالة…» → flips to ✓ the instant one arrives.
- **Success →** S8 aha moment.

### iOS failure recovery
- **No message arrived after ~30s:** «لسه مفيش رسالة وصلت. يمكن خطوة في الاختصار محتاجة تظبيط.» / "Nothing arrived yet — a Shortcut step may need fixing." → CTA **"راجع الإعداد"** (re-open wizard at the suspect step) + **"الصق رسالة يدوي"** (`manual_paste_screen.dart`) as guaranteed fallback.
- **Wrong/no parse:** route into Smart Inbox (Phase 7) rather than discarding — the message is still captured, just needs review.
- **Always-available escape hatch:** manual paste means an iPhone user is *never* fully blocked, even if the Shortcut never works.

---

# Phase 6 — First Transaction Experience (the moment everything serves)

When the first parsed transaction lands — example:

```
        SAR 45.00
        Al Baik
        🍔 Food  ·  Today 8:42 PM
```

### Design principles for this screen
1. **Celebrate, proportionally.** This is a genuine win — mark it. But premium-calm, not confetti-circus (brand = Apple Wallet vibe, no emoji spam).
2. **Make the "it's real" obvious.** Show it's *their* bank, *their* amount.
3. **Build trust by inviting correction.** Letting the user fix the category teaches them the AI is theirs to shape — and that they're in control.
4. **Point to exactly one next step.**

### The screen
- **Headline (AR):** «أول عملية اتسجّلت لوحدها! 🎉** → (icon, not emoji): «أول عملية اتسجّلت لوحدها!» — *EN:* "Your first transaction — captured automatically!"
- **Hero card:** the transaction, rendered in the premium `_ClassifiedTransactionCard` style (gradient, merchant icon, amount in tabular figures).
- **Micro-celebration:** a single soft glow/scale animation on the card + light haptic. One beat, then settle.
- **Trust line (AR):** «انت معملتش حاجة — مالي قرأ رسالة بنكك وسجّلها.» / "You did nothing — Mali read your bank's SMS and logged it."
- **Inline correction (the trust-builder):** category chip is tappable → «مش الفئة الصح؟ غيّرها.» / "Wrong category? Change it." Correcting it teaches the categorizer and signals user control.
- **Primary CTA:** «تمام، كمّل» / "Perfect, continue" → S9/S10.
- **Secondary CTA:** «شوف إزاي اتقرأت» / "See how it was read" → shows the raw SMS → parsed fields mapping (radical transparency; deepens trust).

### Success / Empty / Failure for this moment
- **Success:** as above — the default and the goal.
- **"Empty" (no transaction yet):** never show this screen empty. While waiting, the user is on S7a/S7b (the listening/verify state), not here. This screen only ever appears *with* a real transaction.
- **Failure (parsed but low confidence):** the card appears with a soft "needs a quick check" badge and routes to Smart Inbox — we still celebrate the *capture*, then ask for the *confirmation*. Never hide a captured message.

---

# Phase 7 — Smart Inbox (the review experience)

The Smart Inbox is where Mali earns long-term trust: it's honest about uncertainty instead
of silently guessing wrong. (No UI exists yet — this is the spec.)

### Confidence model → UX mapping

| AI state | What the user sees | Action required |
|---|---|---|
| **Confident** (known bank, clean parse, known merchant) | Auto-added to transactions. **No inbox stop.** Optional gentle "we added this" toast. | None. |
| **Uncertain category** (parsed amount/merchant, fuzzy category) | Inbox item: amount + merchant correct, **category as a question**. | One tap to confirm/swap category. |
| **Needs review** (parsed amount, missing/odd field) | Inbox item with the unsure field highlighted + the raw SMS shown. | Confirm or edit the field. |
| **Unknown merchant** (parsed fine, merchant not in map) | Inbox item: "What is this?" with category suggestions. | Pick a category → optionally remember merchant. |
| **Unknown bank/sender** (sender not recognized) | → escalates to **Bank Discovery** (Phase 8), not a normal inbox item. | Confirm it's a bank. |

### Inbox item UX
- **Layout:** merchant + amount big and certain on top; the *uncertain* part rendered as an interactive question below. Certainty and uncertainty are visually separated so the user knows exactly what we're asking.
- **One-tap resolution:** every item resolvable in a single tap where possible (suggested category pre-highlighted).
- **Batch-friendly:** swipe to accept-as-suggested; items collapse as resolved with a satisfying progress sense.
- **Empty state (AR):** «الوارد فاضي ✦ كل عملياتك متصنّفة.» / "Inbox zero — everything's sorted."
- **Copy for an uncertain item (AR):** «صرفت **120 ريال** عند **متجر مش متعرّف**. ده إيه؟» / "You spent **SAR 120** at an **unrecognized store**. What was it?"

### Onboarding tie-in (S9)
If the first captured transaction was confident → **skip the inbox in onboarding** and go to
dashboard. If it was uncertain → S9 introduces the inbox with a single item: «دي أول عملية
محتاجة تأكيد منك — جرّب تأكّدها.» / "Here's one that needs your confirmation — try it." Teaching the inbox via a real item beats a tutorial.

---

# Phase 8 — Bank Discovery (AI detects an unknown bank)

When the AI sees a sender that isn't in the user's bank allowlist (S4) but the message
*looks* like a bank transaction (amount + currency + transactional language), Mali proposes
adding it. This is how coverage grows organically across 8 markets without us pre-listing
every bank. *(Forward-looking; not yet implemented.)*

### Trigger
Unrecognized sender ID + transaction-shaped content (confidence above a threshold from the
parser/AI). Below threshold → ignore silently (avoid spamming the user with non-bank SMS).

### Suggestion sheet (bottom sheet, non-blocking)
- **Headline (AR):** «يبدو إن ده بنك جديد.» — *EN:* "Looks like a new bank."
- **Body (AR):** «وصلتك رسالة من **{SENDER}** شكلها عملية بنكية. تحب نضيفه كبنك ونسجّل عملياته تلقائياً؟» / "We got a message from **{SENDER}** that looks like a bank transaction. Add it as a bank and auto-log its transactions?"
- **Preview:** shows the parsed transaction it *would* create, so the decision is concrete.

### Actions + exact copy

| Action | Button (AR / EN) | Behavior |
|---|---|---|
| **Confirm** | «أيوة، ضيفه» / "Yes, add it" | Adds `{SENDER}` to the allowlist; this + future messages auto-captured; the previewed transaction is saved. Toast: «تمام، ضفنا {SENDER}. عملياته هتتسجّل لوحدها من دلوقتي.» / "Added {SENDER}. Its transactions will log automatically now." |
| **Reject** | «لأ، ده مش بنك» / "No, not a bank" | Adds `{SENDER}` to an ignore list; we won't ask again about this sender. The message is discarded. |
| **Ask later** | «بعدين» / "Later" | Dismisses the sheet; the parsed transaction goes to **Smart Inbox** as "needs review" so nothing is lost; we may re-suggest after another message from the same sender. |

### Guardrails
- Never auto-add a bank without confirmation (false positives erode trust fast).
- Cap discovery prompts (e.g. max 1 per sender, throttled) so the inbox/sheet never feels spammy.
- Learn globally-but-privately: a confirmed sender improves *that user's* allowlist on-device; aggregate learning only if/when a backend exists and consent is given.

---

# Phase 9 — Psychological Triggers

### Trust triggers
- **No account** (loss-aversion removed: nothing to lose, nothing harvested).
- **On-device, shown** (the "See how it was read" reveal in S8 = radical transparency).
- **Familiar bank names** (in-group signal: "built for me").
- **User-in-control** (one-tap delete; inline correction; reject-a-bank).
- **Honest about iOS limits** (admitting a constraint paradoxically *increases* trust).

### Motivation triggers
- **Effort/reward inversion:** the aha moment proves *zero effort → real result*. The brain encodes "this app pays off without work."
- **Competence cues:** correct first parse = "this thing is smart."
- **Progress sense:** Smart Inbox resolving to zero is a satisfying completion loop.

### Habit-building mechanisms
- **Automatic capture = passive habit.** Unlike manual trackers (which die when the user forgets), Mali works while the user does nothing → the habit is *checking results*, not *doing data entry*. This is the structural retention advantage over manual apps.
- **Notification on capture (opt-in, gentle):** "Mali logged SAR 45 at Al Baik" → reopens the app at the moment of relevance.
- **Inbox-zero loop:** small, frequent, completable.
- **Streak / vault (post-activation):** the deferred `_VaultPage` gamification belongs *here* — introduced once the user has data to feel motivated about.

### Retention loops & why users come back
1. **Spend → SMS → auto-capture → notification → open app → "it just works" → trust deepens.** (Core loop, runs daily without user effort.)
2. **Open app → inbox has 2 items → resolve → inbox zero → satisfaction.** (Micro-engagement loop.)
3. **Weekly: "here's where your money went" insight → curiosity → open.** (Post-activation value loop — *not* in onboarding.)

The deepest moat: **the longer they use it, the more merchants/banks it learns → the more
accurate it gets → the higher the switching cost.** Accuracy compounds. Make that visible
over time ("Mali now knows 47 of your merchants").

---

# Phase 10 — Production Recommendation (what I'd ship tomorrow)

Optimizing strictly for **Activation → Trust → Simplicity → Capture reliability** (in that
order), not feature count.

### The shipping flow

**Act 1 — Trust & Value (skippable, ~30s, zero permissions)**
1. **S1 Welcome** — promise + trust chip.
2. **S2 How it works** — the SMS→transaction animation (keep existing).
3. **S3 Privacy promise** — three tiles (keep existing).

**Act 2 — One decision**
4. **S4 Country & Bank** — currency auto-derived. *(Cut extra-currencies + subscriptions pickers from here.)*

**Act 3 — Platform setup (request permission only now)**
- Android: **S5a rationale → S6a system dialog → S7a listening + backfill latest SMS.**
- iPhone: **S5b honesty → S6b one-step-per-screen Shortcut wizard (currency keyword injected) → S7b verification.**

**★ S8 First Captured Transaction** — celebration + "it's real" + inline correction + "see how it was read."

**Act 4 — Land**
- **S9 Smart Inbox** — only if the first capture was uncertain; otherwise skip.
- **S10 Dashboard** — one transaction + one contextual next-step card.

### Explicitly deferred out of onboarding (do later, contextually)
- Account creation / cloud backup → nudge **after 3–5 captures** (`restore_prompt_screen`/backup flow already exists; just move the *timing*).
- Extra currencies → settings, or auto-offered when a foreign-currency SMS is seen.
- Subscriptions picker → after subscriptions are *detected* from real data.
- Vault / goals / gamification (`_VaultPage`) → post-activation tour.
- Budgets, reports, analytics, premium → never in onboarding.

### Why this order wins
- **Activation:** permission asked warm (post-trust) + Android backfill + iOS verification = highest realistic grant + first-capture rate.
- **Trust:** privacy shown before the ask; transparency at the aha moment; user-in-control everywhere.
- **Simplicity:** one decision (S4) before platform setup; everything else deferred.
- **Capture reliability:** verification step on iOS + manual-paste fallback on both = no dead ends.

---

## Appendix A — Success & Activation Metrics

### North-star (onboarding)
- **TTFT — Time To First Transaction:** target Android < 90s, iPhone < 150s (from first open).
- **Activation rate:** % of installs that reach **S8 with a real transaction** within 24h. Target ≥ 55% Android, ≥ 35% iPhone (iOS is structurally harder).

### Funnel metrics (instrument every step)
| Stage | Metric | Watch for |
|---|---|---|
| S1→S4 | Intro completion % | Too low → intro too long; too high skip → trust not landing |
| S5a→S6a (Android) | **Permission grant rate** | The #1 lever. < 70% → fix rationale copy |
| S6b (iOS) | Shortcut wizard completion % | Drop-off step = the confusing step |
| S7b (iOS) | **Verification success %** | Low → Shortcut instructions wrong for some iOS version |
| → S8 | **First-capture rate** | The activation gate |
| S8 | Inline category correction rate | High → categorizer needs work (but trust-positive that they engaged) |
| Inbox | Items resolved / created | Resolution rate = trust in the AI |
| Discovery | Confirm vs reject vs later | Low confirm → false-positive detection too aggressive |

### Trust / retention proxies
- D1 / D7 / D30 retention.
- % users who **don't** delete the app within 48h of granting SMS permission (the "regret" signal).
- Backup/account adoption *after* the deferred nudge (validates the defer decision).
- Merchants learned per user over time (compounding-moat metric).

---

## Appendix B — Recommended Implementation Order

> Sequenced by activation impact per unit of effort. Maps to existing files.

1. **Reorder + trim the existing intro** (`onboarding_screen.dart`): keep Welcome/HowItWorks/Privacy; **move** `_VaultPage` out; **cut** extra-currencies + subscriptions from `_CountryPage`. *(Low effort, high clarity gain.)*
2. **Add the Android pre-permission rationale (S5a)** before the system request in `android_sms_capture_service.dart` flow. *(Highest activation lever.)*
3. **Add Android S7a "listening + backfill latest SMS"** — parse the most recent existing bank SMS on grant. *(Hits the 2-min target.)*
4. **Build S8 First-Captured-Transaction celebration screen** + "see how it was read" reveal. *(The aha — do not skip.)*
5. **iOS: split `IosShortcutScreen` into one-step-per-screen** with screenshots + inject the country currency keyword from S4.
6. **iOS: add S7b verification** polling the App Group queue (`consumePendingSharedMessages`). *(Kills silent iOS failures.)*
7. **Build the Smart Inbox** (confidence model → item UX). New `features/inbox/`.
8. **Build Bank Discovery sheet** + allowlist/ignore-list persistence. Wire to the parser's sender filter (`bank_sender_filter.dart`).
9. **Move account/backup nudge to post-activation** (reuse `restore_prompt_screen.dart`; change trigger timing).
10. **Post-activation tour** for Vault/goals (the relocated `_VaultPage`).
11. **Instrument the funnel** (Appendix A) before/while shipping so you can prove each change.

---

*End of masterplan. The whole document reduces to one instruction: **make the first real
transaction appear, by itself, in under two minutes — and make the user trust it the moment it does.***
