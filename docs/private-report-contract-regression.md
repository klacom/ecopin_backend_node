# Restored private report contract after a permissive-policy regression

Verified 12 October 2026. The live anonymous API returned all 49 reports, including
identity columns and four non-approved reports, through both `reports` and the
invoker `reports_view`. `Allow anon read reports` granted SELECT USING true to
both anonymous and authenticated roles. Permissive policies combine with OR,
so the existing scoped policy could not constrain it. Anonymous table SELECT
grants also remained on both objects. The responsible write is not attributed
to an agent without execution provenance.

Migration `20261012034152_restore_private_report_contract_after_unrestricted_policy`
drops that unrestricted policy, revokes anonymous table and column SELECT on
both detail objects, and retains anonymous/authenticated SELECT on `public_reports`.
It changes permissions only. The executed statement MD5 and source MD5 after
normalizing line endings/removing the final file newline both equal
`46e2b6ccf4da36b6c2e66150302746b2`.

On the real local Supabase stack, 35 HTTP checks passed with an actual Auth JWT:
allowed profile edits, protected profile fields, notifications, token privacy,
forecast write denial against existing rows, planning RPC denial, legitimate
report creation, owner/officer/admin detail, nonowner assigned crew detail,
assignment revocation, unrelated crew denial, and the anonymous public map.
Rollback reproduced the exposure locally; reapplication closed it. No unsafe
rollback was applied to the hosted project.

After deployment, live anonymous detail requests return HTTP 401/42501 with no
rows, while `public_reports` remains HTTP 200 with the same 45 approved reports.
Live report/profile/Auth/token/settings fingerprints are identical before and
after deployment. This does not revoke already published Storage or Cloudinary
image URLs, and does not certify every client journey.

The rollback restores the captured unsafe access for isolated recovery tests.
Do not deploy it to live as an operational recovery action. Retain the safe
projection and fix callers instead of reopening private base-table access.
