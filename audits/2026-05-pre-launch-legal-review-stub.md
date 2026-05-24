# Pre-Launch Legal Review — Workstream Stub

**Status:** Placeholder. Not yet started. Required before any public launch (any users outside the developer's own household).

## Why this exists

Honeydo collects and stores data about children under 13 (sub_profiles representing kids). Children's privacy is heavily regulated globally. Before the app is used by households outside the developer's own family, a real legal review is required to ensure compliance with:

- **COPPA** (Children's Online Privacy Protection Act — US federal)
- **GDPR** (if any users in EU/UK)
- **State-level laws** (California CCPA/CPRA, Age-Appropriate Design Code; Colorado, Virginia, etc.)
- **CSAM reporting obligations** (federal — NCMEC reporting if inappropriate content is uploaded)

This stub captures the known items so the work isn't forgotten. Implementation is its own multi-phase workstream, not a single batch.

## Origin

Surfaced during Pass 3 Batch 4a (kid chore-photo flow) on 2026-05-24. User asked whether storing kid-generated photos in Supabase Storage created legal exposure. Investigation found that the photo-specific question is just one part of a larger compliance gap: the entire kid-data model needs review before public launch.

## What needs to happen before public launch

### Legal consultation

- Find a privacy attorney specializing in COPPA and (if needed) GDPR
- Initial consultation cost estimate: $2,000-5,000
- Output: a compliance assessment + recommended action items

### Privacy infrastructure

- **Privacy policy** — drafted by or reviewed by attorney. Public-facing.
- **Terms of service** — same. Includes household-account model and parental consent language.
- **Cookie / tracking disclosures** if any client-side analytics are used (current state: none yet).

### Verifiable parental consent flow

COPPA requires "verifiable parental consent" before collecting personal info from kids under 13. Current Honeydo sign-up does not verify this. Options to add:

- Email-plus-credit-card-charge ($0.01 then refunded)
- Government ID upload + verification
- Knowledge-based authentication
- Signed consent form

Pick one based on attorney advice. Implementation likely an Edge Function + new sign-up step.

### Data export and deletion tools

Both COPPA and GDPR require parents to be able to:
- Export all data about their child
- Delete all data about their child (including from backups, within reasonable timeframe)

Currently neither flow exists. Implementation needed:
- "Export my data" admin action → JSON or CSV bundle of all household records
- "Delete my account" admin action → cascading delete across all tables + Storage objects
- Retention enforcement (the deferred pg_cron 30-day photo cleanup is part of this)

### Photo / content safety

Already partially designed (admin can delete photos per Batch 4b plan). Additional considerations:

- **Inappropriate content reporting** — if a photo containing CSAM is ever uploaded, the platform has a legal obligation to report to NCMEC. Currently no detection or reporting mechanism.
- **Optional: AI moderation** — Google Cloud Vision SafeSearch, AWS Rekognition, or similar pre-upload or post-upload content classification.
- **Storage encryption at rest** — Supabase provides this by default; confirm in production.

### Data residency

GDPR has strict rules about cross-border data transfer. Currently:
- Supabase project region: confirm. May need EU-region project for EU users.
- May need Standard Contractual Clauses or equivalent.

### Reporting and audit

- Annual COPPA compliance review
- Data breach response plan
- Audit log of admin actions (some already exists; document what's where)

## Estimated cost (rough)

- Legal consultation: $2K-5K initial; $1K-3K/year ongoing
- Privacy infrastructure development: 2-4 weeks of work
- Verifiable parental consent: 1-2 weeks (depending on chosen mechanism)
- Data export/deletion: 1-2 weeks
- Content moderation (if adopted): 1 week + ongoing API costs ($1-2 per 1000 images for AI moderation)

Total: probably $5K-10K and 6-10 weeks of dev work before launch-ready.

## What's already in place

- Adult-owned household model (parent is the account holder)
- Sub_profiles for kids — no kid accounts, no kid sign-ups
- Row-level security isolates household data
- Supabase Storage encryption at rest (default)
- 30-day photo retention designed (pg_cron deferred, but the design is documented)
- Admin can delete photos (Batch 4b planned)
- PIN-protected kid profile switching (Pass 2)

## What's explicitly out of scope of this workstream

- App store compliance (Apple's App Review and Google Play store have separate rules; tracked separately)
- Marketing / advertising regulations (handled if/when marketing starts)
- Payment processing compliance (handled separately if subscription model launches)

## Triggers for starting this workstream

Start the legal review when ANY of these are true:

1. The developer plans to share the app with users outside their own household (beta testers, family friends, etc.)
2. The app is being prepared for App Store submission
3. The product is being shown to anyone in a product/business context (potential investors, partners)
4. Any external user has been given access to the app

For purely personal use by the developer's own family: this workstream stays deferred.

## Next steps when triggered

1. Find a privacy attorney (referrals or directories like IAPP)
2. Initial consultation; get a compliance assessment
3. Prioritize the action items above based on attorney advice
4. Decide on parental consent mechanism
5. Build the privacy infrastructure (TOS, privacy policy, consent flow, export/deletion)
6. Implement content safety measures
7. Test compliance flows end-to-end
8. Launch only after attorney signs off

End of stub.
