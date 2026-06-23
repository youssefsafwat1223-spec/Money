# Reference Analysis — Payvo (Digital Banking App UI/UX)

> Source: 13 attached screenshots of the Behance project "Payvo - Digital Banking Mobile App"
> (studio: Vyre Lab). Analysis is from the provided images, not the live page.
> Purpose: **extract design language, not copy.** Mali is an expense-tracking + AI assistant app,
> not a bank. See "What Mali should NOT borrow" (§G) and the anti-copy rules in `visual_direction.md`.

---

## A. Overall impression

**Premium because:**
- Deep near-black canvas (`#0F1421`) with a single confident electric-blue accent (`#5389FF`) and a
  tight tonal ladder of blues (`#86ADFF`, `#D4E6FF`, `#E2EEFE`, `#EFF5FE`) + pure white. Restraint, not
  rainbow — one hero color does all the work.
- Very large, bold balance numerals ("Your Balance $121,050.00") with a small `+10%` pill — money is the
  hero, everything else recedes.
- Generous negative space and a calm vertical rhythm; cards breathe.
- Rounded-square soft cards (~24–28px radius) with subtle 1px borders and gentle elevation — soft, modern.

**Trustworthy because:**
- High legibility: Mulish (a humanist sans) at clear sizes; strong contrast (white on near-black).
- Consistent, quiet iconography (uniform line icons in rounded tiles) — feels engineered, not decorated.
- Numbers use a tabular, aligned treatment; amounts never feel improvised.
- A balance-hide affordance (eye icon on the VISA card) signals privacy awareness.

**Modern because:**
- Floating pill bottom nav with a single prominent circular active node.
- Pill-shaped action buttons ("Send"/"Received" as white pills with a circular directional icon).
- Subtle data-viz (soft bar columns, smooth line charts) integrated into cards rather than bolted on.

**Handcrafted (not AI-generated) because:**
- A deliberate, consistent **selective-inversion** technique: in a stack of dark cards, ONE card flips
  to white (Adobe Photoshop bill, the highlighted transaction) to direct the eye — an intentional focus
  device, not random.
- Real brand-logo avatars (Figma, Spotify, Adobe, etc.) at consistent size/treatment.
- A coherent identity system page (logo construction, icon grid, type specimen, color tiles) — evidence
  of a system, not one-off screens.
- Micro-details: `+10%` change pill, "Last 7 days" caption, "1 Month" tags, currency flag selector.

---

## B. Layout analysis

- **Screen composition:** single-column, top-weighted. A tall hero (balance / page title) → primary
  action row → labeled sections → list. Page title is huge and left-aligned ("Your Balance",
  "Upcoming Bills", "Transactions", "Profile").
- **Spacing rhythm:** large outer gutter (~24px), generous gaps between sections (~20–28px), tight gaps
  within a card. Consistent 4/8 base.
- **Hierarchy:** (1) page title / hero number, (2) section label, (3) row content, (4) metadata caption.
  Size + weight + color carry the hierarchy; very few dividers.
- **Header style:** no system app bar. Each screen = small profile row (avatar + "Hello, Michael") +
  two circular icon buttons (chat/bell) at top, then a very large page title beneath. Secondary screens
  use a back arrow + title.
- **Card structure:** rounded-square, dark navy fill, subtle border, soft shadow; internal layout =
  leading brand avatar + title + meta on left, value + tag on right.
- **Bottom navigation:** floating dark pill, ~5 slots, the active item is a filled **blue circle** that
  pops above the others (clear "you are here").
- **Primary actions:** high-emphasis pill buttons (white pill "Send/Received" with a circular icon;
  blue "Sign up"; black "Pay Now" with a circular arrow). Always pill-shaped, always with an icon.
- **Secondary actions:** circular icon buttons (top-right bell/chat, "+", "...").
- **List design:** brand avatar + name + date stacked, amount right-aligned; negative amounts in
  red/white; rows are airy (no heavy separators).
- **Dashboard layout:** balance hero + change pill + currency flag → Send/Received/+ action row →
  "Transfer List" (avatar row of people) → "Financial Health" with a bar chart → floating nav.
- **Financial data presentation:** big amount + small percent-change pill; secondary "Financial Health
  $3,982.00 Last 7 days" with a soft bar chart; amounts use a smaller superscript-like cents treatment
  (`$121,050.00` with `.00` lighter/smaller).

---

## C. Visual style analysis

- **Color palette (from the spec tile):** `#5389FF` (primary electric blue), `#86ADFF` (light blue),
  `#D4E6FF` / `#E2EEFE` / `#EFF5FE` (pale blue tints), `#0F1421` (near-black ink/canvas), `#FFFFFF`.
  Essentially: near-black + one blue scaled across tints + white. No competing hues.
- **Gradients:** restrained. A pale sky/white radial on the VISA card (light gradient as a "premium
  card" device); large blue 3D render gradients in marketing mockups (not app UI). In-app gradients are
  subtle, mostly flat dark surfaces.
- **Background treatment:** flat near-black in-app; the Behance *presentation* uses 3D renders and
  lifestyle photography (marketing, not product).
- **Card colors:** dark navy by default; **one card inverted to white** per stack for focus; the credit
  card uses a light gradient to feel like a physical premium card.
- **Typography feel:** Mulish (Regular/Medium/SemiBold) — humanist, friendly-but-serious, very legible;
  big headings, comfortable body, tabular numerals for money.
- **Icon style:** single-weight line icons, rounded corners, housed in rounded-square tiles; consistent
  stroke and size.
- **Image/illustration style:** brand logos as avatars; lifestyle photography + 3D product renders for
  the case study only.
- **Shadows:** soft, low-opacity, large-blur; depth is gentle, not glossy.
- **Radius:** large and consistent — cards ~24–28px, pills fully rounded, icon tiles ~14–18px.
- **Depth:** layered via subtle borders + soft shadow + the white-card pop; not skeuomorphic.
- **Contrast:** high text contrast (white on near-black); accent reserved for the single most important
  action/element on screen.

---

## D. Data visualization analysis

- **Charts:** soft bar columns (rounded, some highlighted brighter to mark "now"), smooth line charts
  with a dot marker at the latest point, and a **radial gauge** (semicircle of ticks → 93%) in the case
  study. All use the single blue scaled by intensity; gridlines are faint.
- **Balance/amount presentation:** dominant numeral; cents (`.00`) de-emphasized (smaller/lighter);
  a small `+10%` change pill beside it; currency context via a flag chip.
- **Spending/income visual treatment:** "Financial Health" mini bar chart inline in a card; transaction
  amounts color-coded (negatives red/white), date as caption.
- **Progress indicators:** the radial gauge + bar intensity convey progress/health; pill tags ("1 Month",
  "+10%") give quick status.
- **Financial summary cards:** large metric + short label ("80% Of users described the app as intuitive"),
  each metric paired with its own small chart — metric-with-evidence pattern.

---

## E. Motion ideas (inferred from the static style)

- **Card reveal:** soft fade + 8–12px rise, staggered top-to-bottom (the layered card stacks imply
  sequential entrance).
- **Number count-up:** the dominant balance begs an animated count-up on load/refresh.
- **Chart entrance:** bars grow from baseline; line draws left-to-right with the end-dot landing last;
  gauge sweeps to its value.
- **Tab transition:** the active blue nav circle morphs/slides between slots; content cross-fades.
- **Sheet transition:** spring slide-up; the "Pay Now" card suggests an expandable card → sheet.
- **Confirmation animation:** the circular-arrow buttons imply a quick rotate/check on success.

---

## F. What Mali SHOULD borrow (fits Mali)

1. **Deep, calm dark canvas + ONE confident accent + tonal ladder.** Mali already has a dark `bg` and a
   blue `cta`; adopt the *discipline* (one accent, scaled by tints) — but keep **Mali's own hue**, not
   Payvo's `#5389FF`. Fixes the audit's "4+ competing blue gradients."
2. **Money-as-hero typography:** big balance numeral with de-emphasized cents + a small change pill.
   Maps to Mali dashboard `_financialCard` and `AppTypography.amountHero`.
3. **Selective white-card focus:** invert exactly one card to draw attention — perfect for Mali's
   **Smart Inbox** "needs review" item and the next-due bill. Intentional, restrained.
4. **Brand-avatar rows:** Mali already has `BrandMark`; lean into consistent merchant logos in
   `AppTransactionRow` and bill cards.
5. **Floating pill bottom nav with a clear active node.** Mali already has a floating bar; sharpen the
   active state and (Mali-specific) consider a center capture "+".
6. **Pill action buttons with a leading circular icon** for primary actions (add transaction, confirm).
7. **Inline, soft data-viz** (rounded bars, smooth line, "current" highlighted) — upgrade Mali's
   `spending_charts.dart` look + the planned `ChartCard`.
8. **Metric-with-evidence cards** (big number + tiny chart + short label) — ideal for Reports/Insights.
9. **Privacy affordance** (hide-balance eye) — Mali already has privacy mode; make it a visible toggle.
10. **A real identity system page discipline** (logo grid, icon set, type specimen, color tiles) — Mali
    should finalize tokens the same rigorous way (this is what makes it look handcrafted, not generated).
11. **Generous spacing + few dividers** — rely on space and weight, not lines.

## G. What Mali should NOT borrow (wrong for Mali)

1. **Banking features & language.** No "Send"/"Received"/"Transfer List"/"Pay Now"/people-to-pay avatar
   rows. Mali tracks expenses and categorizes SMS — it does not move money. Do not add fake banking UI.
2. **Payvo's identity.** Do not copy the Payvo logo (the circular "sunset/ripple" mark), the name,
   wordmark, exact `#5389FF` as Mali's identity color, screen layouts, or marketing copy.
3. **Royal-blue-only palette as identity.** Mali's hue family is its own (Bahama Blue today); evolve it
   deliberately — don't recolor Mali into Payvo. One-accent *discipline* yes; Payvo's exact blue no.
4. **LTR-only composition.** Payvo is LTR English. Mali is **Arabic-first / RTL**: the profile row,
   page-title alignment, list amount alignment, nav order, and chart axes must mirror. Big left-aligned
   titles become right-aligned; leading avatars sit on the right.
5. **3D renders & lifestyle photography as product UI.** Those are Behance presentation craft, not app
   surfaces. Mali's screens stay flat, fast, and content-first.
6. **Decoration over clarity / "visual flexing."** No heavy glows, no glossy cards, no decorative
   gradients in functional screens. Mali must prioritize trust and legibility (Arabic numerals + Arabic
   text readability) over showpiece visuals.
7. **English-only numeral treatment.** The "small cents" superscript trick must be validated with
   Arabic-Indic digits and RTL amount alignment before adopting.
8. **Latin-only type (Mulish).** Do not switch Mali's type to Mulish; Mali needs an Arabic-first stack
   (current Inter + IBM Plex Sans Arabic). Borrow the *feel* (humanist, legible, tabular numerals), not
   the font.
