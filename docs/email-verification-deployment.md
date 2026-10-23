# Registration email verification

Production requires both `20261012110000_bind_verification_email_and_atomic_profile_healing.sql`
and `20261012143000_make_email_verification_atomic.sql`. Apply them in order before
deploying the bound-token backend. Issuance must never fall back to an unbound token.
The database enforces a 60-second issuance cooldown and atomic Auth/profile/token
completion. The RPCs remain service-role only.

Set `APP_BASE_URL=https://d3hd0su6zl9vb.cloudfront.net` on EC2. Production email
generation rejects HTTP. Existing unbound links remain invalid: request a fresh
email in the app after 60 seconds, then open the newest email. Do not backfill old
tokens from current account emails or mark a real account verified manually.

The verification email and result page follow the native DESIGN.md account
palette: civic blue primary actions, Outfit with email-safe Arial fallback,
24px cards, readable text, and light/dark result pages. Email clients may replace
fonts or colors. Verification pages use an explicit Open Ecopin deep link after
success; scripts and automatic navigation are unnecessary.

Resend keeps the same response for unknown/verified accounts and delivery failures
to avoid account enumeration. Check server failure logs and SMTP authentication
when diagnosing delivery. Never log verification URLs or SMTP error objects.

Validation: 194 backend tests; rollback-only database checks for bound issuance,
cooldown, email changes, expiry, atomic completion, replay, and RPC grants. SMTP
authentication was checked without sending real mail. Inbox delivery and Android
deep-link behavior require a user resend and device check.
