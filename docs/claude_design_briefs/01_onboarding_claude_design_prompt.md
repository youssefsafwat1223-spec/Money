# Copy-Paste Prompt For Claude Design

Design Mali onboarding only.

Use the attached/current brief as the source of truth:

- `00_onboarding_current_inventory.md`
- `01_onboarding_claude_design_brief.md`

Mali is an Arabic-first personal expense tracking app and AI financial assistant. It turns bank SMS/manual pasted messages into categorized transactions, then helps users understand spending through budgets, reports, and insights. Mali is not a bank.

Your task:

Create high-fidelity mobile UI designs for the complete Mali onboarding flow, page by page. Do not implement code. Do not design dashboard, transactions, Smart Inbox, budgets, reports, goals, settings, or app shell. Focus only on onboarding and onboarding-adjacent setup screens.

Design the onboarding screens from the current flow:

1. Splash / launch
2. Language selection
3. Welcome / value proposition
4. How transactions enter Mali
5. Country and currency selection
6. Required email/auth screen
7. OTP verification
8. Privacy and data safety explanation
9. Capture method setup
10. Android SMS/share permission explanation
11. iOS Shortcut setup explanation
12. Manual paste fallback explanation
13. Backup explanation / restore
14. AI consent explanation
15. First transaction / pending review / confirmed success
16. Completion / start using Mali

Important product direction:

- Make Arabic RTL the primary design.
- Include English/LTR notes or variants where possible.
- Treat email-first sign-in as the required primary path.
- Do not make guest/no-account entry prominent unless explicitly marked as implementation compatibility.
- Explain setup honestly: Android uses SMS/share/capture permissions; iOS requires Apple Shortcuts or manual paste.
- Show privacy and backup clearly: local-first, optional encrypted backup, recovery code/passphrase.
- Explain AI consent honestly: sanitized text may be sent for unknown-bank parsing only if the user grants consent.

Visual direction:

- Premium.
- Calm.
- Trustworthy.
- Financially clear.
- Smart but not gimmicky.
- Human-crafted.
- Arabic-first.
- Modern but not childish.
- Visually rich but practical.
- Not AI-generated-looking.
- Not a generic fintech clone.
- Not copied from Payvo.

Design system guidance:

- Use iPhone-size mobile frames.
- Dark mode should be the primary presentation.
- Include light mode notes or previews if useful.
- Use strong financial typography and tabular numbers.
- Use generous spacing and clear hierarchy.
- Use clean cards, bottom sheets, step indicators, and clear primary/secondary actions.
- Use meaningful vector icons and illustrations.
- Keep important setup steps visible.
- Use LTR islands for email, OTP, currency codes, backup recovery codes, and Shortcut keywords.
- Make all screens small-screen safe.

Visual assets to conceptualize:

- Mali abstract finance shield / safe visual.
- SMS capture visual.
- Manual paste visual.
- AI categorization visual.
- Privacy/backup visual.
- iOS Shortcut guide visual.
- Country/currency selector visual.
- First transaction success visual.
- Email OTP trust visual.
- Android permission explanation visual.

Icons needed:

- Wallet
- Receipt
- SMS/message
- AI sparkle/brain
- Lock/privacy
- Cloud backup
- Globe/language
- Currency
- Notification
- Shield
- Check
- Warning
- Phone shortcut
- Manual paste
- Mail
- Key/recovery code
- Flag/country
- Category/tag

Do not:

- Implement code.
- Invent features not in the app.
- Invent fake permissions.
- Invent fake banking or money-transfer features.
- Turn Mali into a bank.
- Copy Payvo.
- Use copyrighted logos or real bank/payment logos.
- Use real Netflix/streaming/bank/payment logos unless already present and explicitly approved.
- Use generic AI blobs.
- Overload screens with text.
- Hide required setup steps.
- Ignore RTL/LTR.
- Ignore small screens.
- Promise direct iOS SMS access without Shortcuts.
- Promise bank account linking.
- Promise exchange-rate conversion.
- Claim AI never sends data if the consented sanitized parsing path exists.

Please output:

1. Screen-by-screen high-fidelity design direction.
2. Layout explanation for each screen.
3. Component list for each screen.
4. Visual asset list.
5. Icon list and icon usage.
6. State variants:
   - loading
   - error
   - success
   - permission granted
   - permission denied
   - iOS setup incomplete
   - backup enabled/disabled
   - authenticated/unauthenticated
   - first transaction pending review
   - first transaction confirmed
7. Dark/light notes.
8. RTL/LTR notes.
9. Developer handoff notes for a future Flutter implementation.

Keep the design practical enough to implement later in Flutter without backend changes or new business logic.
