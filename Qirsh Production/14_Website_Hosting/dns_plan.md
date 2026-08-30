# DNS Plan — `qirsh.site`

**Documented only. Nothing has been executed and Hostinger has not been contacted.**

Domain and business email are both at Hostinger, which makes this riskier than a
normal DNS change: **the same zone that will point at the VPS is the zone that
delivers `business@qirsh.site`.** A careless edit takes the email down, and mail
failures are quiet — you find out when someone says they wrote and got nothing.

---

## ⛔ Records that MUST NOT be altered

Before touching anything, **export the current zone** (Hostinger → DNS Zone →
export, or screenshot every record) and keep it outside the repo.

These record types exist to make `business@qirsh.site` work. Do **not** delete,
replace, or "tidy" them:

| Type | Name | Purpose | Rule |
|---|---|---|---|
| **MX** | `@` | routes inbound mail to Hostinger | **never touch** — deleting these stops all mail instantly |
| **TXT (SPF)** | `@` | `v=spf1 …` — declares who may send as @qirsh.site | **never replace.** Only one SPF record may exist; if a sender is added later, *extend* the existing one, never add a second |
| **TXT (DKIM)** | e.g. `hostingermail._domainkey` | signing key | **never touch** |
| **TXT (DMARC)** | `_dmarc` | handling policy | **never touch** |
| **CNAME** | autodiscover / autoconfig / mail (if present) | client auto-setup | leave as-is |
| **TXT** | domain verification | Hostinger ownership | leave as-is |

The exact hostnames and values are whatever Hostinger already put in your zone.
**Read them from the zone — do not copy values from this document or anywhere
else.** This file deliberately does not quote specific MX or DKIM values,
because a wrong value pasted from a guide is exactly how mail breaks.

### The one rule that matters most

The website needs **A** records. Email needs **MX/TXT** records. They are
different record types on the same name and they do not conflict. Adding an
`A` record on `@` does **not** disturb `MX` on `@`.

The danger is not the addition — it is a "replace all records" flow, or deleting
a row that looks unfamiliar. Add rows; delete nothing.

---

## ✅ Records to ADD

Replace `VPS_IPV4` with the address Hostinger assigns. It is not recorded in this
repository, and no IP is hardcoded anywhere in the site.

| Type | Name | Value | TTL | Purpose |
|---|---|---|---|---|
| A | `@` | `VPS_IPV4` | 300 → 3600 | `qirsh.site` |
| A | `www` | `VPS_IPV4` | 300 → 3600 | `www.qirsh.site` |
| A | `admin` | `VPS_IPV4` | 300 → 3600 | `admin.qirsh.site` |

If the VPS has IPv6, add matching `AAAA` records on the same three names.
Otherwise add none — a dangling `AAAA` makes the site unreachable for IPv6-first
clients while looking fine to you.

**Use a low TTL (300s) while setting up**, then raise it to 3600 once verified.
A 24-hour TTL on a wrong address is a long wait.

`www` is a separate `A` record rather than a `CNAME`, because a `CNAME` on `www`
is fine but an `A` keeps all three names uniform, and Nginx redirects `www` →
apex anyway.

### Optional, later

| Type | Name | Value | Purpose |
|---|---|---|---|
| CAA | `@` | `0 issue "letsencrypt.org"` | restricts which CA may issue for the domain |

Add this only after certbot has succeeded. A CAA record that omits your actual
issuer blocks certificate renewal.

---

## Verification before doing anything else

```bash
dig +short qirsh.site A
dig +short www.qirsh.site A
dig +short admin.qirsh.site A

# email records must be UNCHANGED — compare against the export taken first
dig +short qirsh.site MX
dig +short qirsh.site TXT
dig +short _dmarc.qirsh.site TXT
```

**Send a test email to `business@qirsh.site` after the change and confirm it
arrives.** DNS resolving correctly for the website says nothing about whether
mail still routes. This is the check people skip.

---

## Order

1. Export the current zone. Keep it somewhere you can restore from.
2. Provision the VPS, note its IP.
3. Add the three `A` records at TTL 300. **Delete nothing.**
4. `dig` all three; confirm they resolve to the VPS.
5. `dig` MX/SPF/DKIM/DMARC; confirm byte-identical to the export.
6. **Send and receive a test email.**
7. Run certbot for all three names.
8. Raise TTL to 3600.

Steps 5 and 6 are the ones that protect the business email. Do not treat them as
optional because the website looks fine.
