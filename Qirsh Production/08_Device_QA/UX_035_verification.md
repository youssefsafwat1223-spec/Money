# UX-035 — Device Verification

The one Phase J finding whose original reproduction was never captured.
**This is a narrow device check, not a reopening of the Phase J audit.**

## The report

> Very large values on the cards UI collapse into a zero-like, unreadable
> result («0 0 0»). Filed HIGH, marked NEEDS REPRO.

## What shipped, and why it might be the wrong fix

The finding has two halves and only one was provably a defect.

**Exactness — real, fixed.** Every statement figure used to be formatted as
`Formatters.amount(money.toDouble())`. Past 2^53 a `double` cannot represent
consecutive integers, so the digits printed were not the digits stored. Those
surfaces now format from exact minor units (`money_format.dart`, `MoneyText`).

**Legibility — inferred, mitigated.** The hero amount sits in
`FittedBox(fit: BoxFit.scaleDown)`, which has no floor: the longer the value, the
smaller it renders, with nothing stopping it before it becomes a row of indistinct
marks — which is what "«0 0 0»" describes at a glance.
`app/lib/domain/finance/hero_amount_size.dart` now picks a size from the value's
length so a long figure starts legible.

**This is stated openly in the source file:** if the captured repro shows a
different cause, the shipped fix is the *wrong* fix rather than an incomplete
one. That is why this verification matters.

## Procedure

`[DEVICE]` — a real phone, not a simulator.

1. **Record the conditions**: device model, OS version, locale (ar and en),
   and the **text size setting**
   (iOS: Settings → Display & Brightness → Text Size, at maximum;
   Android: Settings → Display → Font size, at maximum).

2. Create an account and add transactions producing balances of increasing
   magnitude:

   | Step | Value |
   |---|---|
   | 1 | `9,999.99` |
   | 2 | `999,999.99` |
   | 3 | `99,999,999.99` |
   | 4 | `9,999,999,999.99` |

3. Visit and **screenshot each** of: **Home hero**, **Accounts** rows,
   **Budgets** card tiles, **Cards** page flow figures.

4. Repeat at maximum text size, in **both** ar and en.

5. For every screenshot record:
   - is every digit legible?
   - is any digit missing or truncated?
   - does the displayed value match what was entered?

## Reading the result

| Observation | Meaning | Action |
|---|---|---|
| Digits **wrong or missing** | a formatting defect on a path the exactness fix did not cover | report it — this is a new finding |
| Digits **correct but too small to read** | the legibility floor is too low | lower the thresholds in `hero_amount_size.dart` |
| **Cannot reproduce** at any magnitude | the fix holds | close UX-035, note the attempt in the closure matrix |

## Pass criteria

- [ ] Every digit of every value is legible at maximum text size
- [ ] Every displayed value matches the entered value exactly
- [ ] No value is truncated or ellipsised on any of the four surfaces
- [ ] Verified in both ar and en
- [ ] Screenshots attached as evidence

## Evidence to keep

Screenshots, device model, OS version, locale, text-size setting, app build
number. Without those the result is an opinion rather than a repro.
