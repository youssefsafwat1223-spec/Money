# Play RECEIVE_SMS submission package — readiness

**2026-09-03. NOTHING HAS BEEN SUBMITTED.** No Play Console form was opened,
filled, or sent. Submission requires explicit owner authorization.

This is the single entry point for the Play track. It supersedes scattered
claims in older documents.

---

## 1. What this track found

Four statements about SMS were false. Every one is now corrected in source.

| # | Where | Said | Reality |
|---|---|---|---|
| 1 | **Code** — AI egress gate | — | **The two-consent gate was not enforced.** `ConsentAuthority.decide(aiProcessing)` requires `cloud && aiConsentGranted`, but production passed `aiConsentGranted` **alone** at four call sites and `ai_parser_client` never consulted `ConsentAuthority`. With cloud OFF and AI ON, sanitized bank-SMS text was still transmitted. |
| 2 | **Live privacy policy**, opening line | "reads bank SMS **and notification messages**" | Qirsh has **never** had notification access. No `NotificationListenerService`, no `BIND_NOTIFICATION_LISTENER_SERVICE`; a test asserts their absence. |
| 3 | **Play declaration draft** §2/§3 | "parsing happens entirely on the device. No message text is sent to any AI provider" — presented as the shipped disclosure | The app ships an optional, consented, sanitized cloud/AI path. §3 quoted text the app no longer ships. |
| 4 | **Shipped string** `smsPermissionRationaleBody` | "nothing leaves your phone" | Absolute claim contradicted by the optional path. |
| 5 | **Shipped AI toggle** subtitle | AI is for "unfamiliar messages" | The code is **AI-first**: with both consents on, **every** captured message is sent. |
| 6 | **Store metadata** | "bank SMS **and notifications**"; "notification access is the app's core function" | Same non-existent capability as #2. |

**#1 is the serious one.** It made a published legal document false: the policy
promises that with cloud off, "no financial data leaves your device — this is
enforced at every network call, not only in the settings UI." It was not.

Fixed by routing every AI consent site through `ConsentAuthority`, pinned by
`test/architecture/ai_egress_consent_test.dart` (proven non-vacuous), with 474
privacy/capture/architecture tests passing.

---

## 2. Reviewer consensus

Both reviewers were given the same brief and the same source.

**Agreed:**
- Play policy restricts **purpose, not location** — it does not require
  on-device-only processing. Parsing a financial SMS into the user's own record
  is the declared core purpose, so a sanitized, consented transfer to a
  *service provider* is not automatically outside the exception.
- **Disclose the AI path explicitly.** A declaration contradicting the privacy
  policy attached to the same submission reads as misrepresentation — a removal
  risk — whereas an honestly described architecture that draws questions is a
  rejection you can answer.
- **Remove every absolute claim** ("nothing leaves your phone", "entirely
  on-device") wherever an optional transfer exists.
- Do **not** ship the path "disabled and undeclared". A dormant-then-activated
  undisclosed transfer is the worst discovery scenario.

**Differed only on readiness, and the gap is now closed:** one said declarable
after correcting the text; the other said *not* declarable as-is because the AI
path "is not demonstrably dual-gated". That gate is now enforced and tested.

**Both raised one item that remains open — §4.1 below.**

---

## 3. Package status

| Artefact | State |
|---|---|
| `play_declaration_draft.md` | **REWRITTEN** — §2/§3 corrected; §3 is now the verbatim shipped disclosure; 12-step reviewer video script |
| `data_safety_draft.md` | Honest; egress-count claim corrected 2026-09-02 |
| Prominent disclosure (shipped) | Correct, and structurally enforced before the system dialog |
| Privacy policy **source** | Corrected |
| Privacy policy **live site** | ⚠️ **STALE — still contains "and notification messages"** |
| Store listing copy | Corrected |
| Review video | **NOT RECORDED** — needs RB-5 hardware |
| Play declaration form | **NOT SUBMITTED** |
| Data Safety form | **NOT SUBMITTED** |

---

## 4. Blocking the submission

### 4.1 AI provider terms — decide before `GEMINI_API_KEY` is ever set

Both reviewers independently made this the pivot. The exception permits transfer
to a **service provider**; it does not permit a provider using the data for its
own purposes.

The Gemini API **free tier permits Google to use submitted content to improve
its products.** That is an independent purpose. It would break "may not be
extended for any other purpose", flip Data Safety to *Shared: YES*, and void the
exception claim.

**Action:** commit to a no-training tier (paid Gemini API or Vertex AI), verify
the data-governance terms **at enablement**, and record the terms version and
date next to the Data Safety row. `GEMINI_API_KEY` is currently unset in
production, so this decision is still ahead of you — keep it that way until the
tier is pinned.

### 4.2 Redeploy the legal site

The source is corrected; the **live** page is not. The declaration attaches the
policy URL, so a reviewer would read the stale copy.

Regenerate with `tools/build_legal_site.py` and redeploy `/privacy` and
`/en/privacy`. **Deployment is an owner action** — not performed here.

### 4.3 Record the reviewer video — needs RB-5 hardware

Script is §5 of the declaration. Steps 4, 8 and 10 are what reviewers check.

---

## 5. Exact Play Console actions — owner only

None of this was done. In order:

1. **Play Console → App content → Data safety.** Answer from
   `data_safety_draft.md`. SMS/MMS = **Collected**, *optional*; purpose = app
   functionality only; **not** shared — but only after §4.1 is settled, because
   the answer depends on the provider's terms.
2. **App content → Sensitive app permissions → SMS & Call Log.** Select
   exception **"SMS-based money management"**. Paste §1–§4 of the declaration.
   Attach the video and the policy URL.
3. **Store listing.** Must present automatic bank-SMS capture as core
   functionality (the policy requires the listing to support the claim), and
   must **not** mention notification access.
4. **Submit for review**, then wait. Do not publish to any track — including
   internal/closed testing — before approval: the declaration requirement
   applies to test tracks too.

**Evidence to send back after each step:** a screenshot of the submitted
declaration, the Data Safety summary page, and the review-status email.

---

## 6. Recommended, not blocking

**Gate the AI attempt on local-parse failure or low confidence**, rather than
sending every captured message. Today it is AI-first. That is now disclosed
accurately, so it is defensible — but "only when the local rules cannot read the
message" is a materially stronger *necessity* argument under
"limited to what is necessary", and it matches what users expect from a toggle
about AI assistance. It changes money-path behaviour, so it needs its own QA and
is deliberately **not** bundled into a documentation-reconciliation change.
