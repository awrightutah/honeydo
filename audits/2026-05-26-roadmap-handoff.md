# Honeydo — Open Items & Roadmap (as of 2026-05-26, end of Day 5)

## Project state

**Branch state:** `main` is at commit 2aa5381 (Smart Shopping Q2+Q5 decisions). Tags: `v0.5.0-membership-migration-complete`, `v0.6.0-ui-polish-complete`. About to add `v0.6.1-recipe-scraping-spike` once the spike merges.

**Active branches:**
- `main` — production line
- `feat/meals-batch-6c-2026-05-25` — parked, push notifications, blocked on app name decision
- `spike/ingredient-canonicalization-2026-05-26` — about to merge

**Active household:** Wrights, 3 members (Andrew admin_owner, Randi sub_profile, Sonny sub_profile). Sonny was discovered during Batch 7b-i so multi-kid UX hasn't been fully thought through yet.

---

## Immediate decisions blocking other work

### App name decision (BLOCKS 6c)
Push notifications batch is parked until we have a name. Apple Developer Portal needs the final name to register the bundle ID, certificates, push capabilities, etc. Until then we can't ship 6c.

**Guidance:** This is a creative decision, not a technical one. Don't let Claude pick it. Decide based on what you want the app to feel like long-term. "Honeydo" is the working name but never committed to. Ask yourself: would you be okay saying this name out loud to other parents? Is it greppable (won't collide with other apps in the App Store)?

### Fetcher strategy for Recipe aggregation Phase 1
Spike concluded fetcher is the bottleneck. Two options:
- **Playwright** — full browser, beats Cloudflare, free, but heavy dependency and slower per-request
- **ScraperAPI / Scrapfly trial** — paid service ($), handles anti-bot for you, simple HTTP call

**Guidance:** Start with a 1-day trial of ScraperAPI's free tier on the 5 URLs that failed (Allrecipes, Food Network, Serious Eats, King Arthur, Damn Delicious). If it solves them, the paid service is worth it for a family-app scale. If it doesn't, Playwright. Don't try to build a fetcher from scratch — that's a rabbit hole.

### Smart Shopping Q3 (category architecture)
Q2 and Q5 are locked. Q3 — how categories work across recipes/pantry/shopping/stores — is still open. This blocks the Categorization phase (week 3-4 of Sequence A).

**Guidance:** Defer this decision until Recipe aggregation Phase 1 is real. You'll learn things from actually importing recipes (what categories show up, how messy they are, whether you need a hierarchy) that will make Q3 obvious. Don't pre-optimize.

---

## Pending implementation work (ordered roughly by priority)

### Recipe aggregation Phase 1 (NEXT MAJOR WORK)
4-6 weeks. Foundation of Smart Shopping Sequence A. Blocked on fetcher decision above.

**Guidance:** Start with a stub doc like the Batch 9 stub. Break it into sub-batches (importing one URL, importing many, error UX, ingredient editing post-import, etc). Don't write it all at once.

### Batch 9 — Kid redemption requests
Architecture stub is committed at `audits/2026-05-batch-9-kid-redemption-requests-stub.md`. ~700 LOC across 5 phases. Mirrors the wishlist + meal_requests pattern.

**Guidance:** Don't build this until you actually have kid users (Randi or Sonny) trying to redeem rewards and hitting the RLS error. Building it for hypothetical users wastes effort. The current behavior (kid sees error message) is acceptable because of 7a-i's note.

### 6c-i — Apple Developer Portal walkthrough
Push notifications setup. Blocked on app name. When unblocked: walk through Apple Developer Portal step-by-step, register bundle ID, create push cert, etc.

**Guidance:** This is the kind of thing where Claude can write the prompt for Claude Code but you'll be clicking through Apple's UI yourself. Don't try to automate — Apple's portal changes too often.

### Pre-launch legal review stub
Need to write a stub doc covering: privacy policy (we collect kid data, requires COPPA compliance review), terms of service, EULA for App Store, data retention policy.

**Guidance:** This is a serious item before any public launch. Even for family-only beta. Write the stub now while you remember what data you collect; do the actual legal review before TestFlight goes wide.

### Pass 4 today dashboard spec
Mentioned earlier but never written. Today dashboard is the home screen kids see — needs design pass for clarity, age-appropriate UI, what shows when there's nothing to do.

**Guidance:** Spec before building. Write a doc describing each variant (no chores today, all done, some pending, overdue, etc.) and what the screen should show in each state. Then build to spec.

### Multi-kid UX inventory
Sonny exists now (member_id `d9598799-e300-469a-9517-266b0e43a68f`). Need a sweep of every screen to ask "does this work with 2+ kids?" Approvals list, points display, today dashboard, photo capture flow, etc.

**Guidance:** Write a checklist. Walk through the app as Andrew (admin) and check every screen that shows kid info. Note what's broken or confusing. Then prioritize fixes. Don't try to fix as you find — separate discovery from implementation.

### Active member indicator NetworkImage error fallback
Batch 7b-iii shipped without graceful handling of failed avatar loads. If the network image fails, the indicator breaks visually.

**Guidance:** Small fix. Add an `errorBuilder` to the NetworkImage that falls back to initials in a colored circle. Single-file change, can be a polish batch later.

### settings_screen nameController dispose
Future polish item — minor lifecycle issue where the controller isn't disposed properly in an edge case. Not crashing, just leaking.

**Guidance:** Catch this when you're already touching `settings_screen` for another reason. Don't make a dedicated batch.

---

## Standing patterns to remind the next Claude about

These are the patterns we've established and should keep using:

1. **5-step MembershipHelper migration** — proven across 17 screens in Batches 7a-i, ii, iii. If you find another screen using the old membership pattern, follow the same 5 steps.
2. **StatefulWidget for dialogs with TextEditingController** — never use the controller-in-StatelessWidget anti-pattern. Caused bugs we had to fix.
3. **Closure-capture for sheet handlers** — fixes the race where the sheet's handler reads stale state. Settings edit-profile sheet had this.
4. **ValueKey on list children that can shrink** — Flutter widget identity issue. Required when a list can both grow and shrink.
5. **Pass 2 error pattern** — `try { ... } catch (e) { debugPrint('...'); ScaffoldMessenger... SnackBar(content: Text('Error: $e'))... }`. Non-const SnackBar with the exception interpolated. Used everywhere now.
6. **Full restart (not hot reload) for State class changes or Info.plist changes.** Hot reload silently doesn't pick these up and wastes debugging time.
7. **Sub-batch splitting when scope exceeds single-session safety** — when a batch touches more than ~5 files or more than ~150 LOC, split into i/ii/iii sub-batches and merge each independently. Proven on 7a (17 screens → 3 sub-batches) and 7b (138 callsites → 3 sub-batches).
8. **Spike directories at `/spike/<name>/`** with their own venv + .env + .gitignore. Don't pollute the Flutter project with Python deps.
9. **Investigation before implementation when scope unclear** — we did this for recipe scraping (re-framed mid-spike from canonicalization to URL scraping). Better to spike for 1-2 days than to build the wrong thing for a week.

---

## How I work (the 3-step rule)

I'm Andrew, non-developer. Claude writes prompts → I paste into Claude Code in terminal → I paste terminal output back. Always **one step at a time**. Don't write a prompt that does A then B then C — I lose visibility. Small steps, paste, confirm, next.

**Verify state before assuming.** Show me `git status`, `git log`, `flutter analyze` output to prove things worked. We've caught real bugs (the kid-debiting-admin one, the privacy leak in `point_history`) because of this rigor.

**When something breaks, stop and diagnose.** Don't pile on changes.

---

## Reference files in the repo

- `audits/2026-05-batch-9-kid-redemption-requests-stub.md` — Batch 9 architecture
- `audits/2026-05-smart-shopping-pantry-vision-stub.md` — Smart Shopping vision (Q2+Q5 locked, Q3 open)
- `spike/ingredient-canonicalization/results/results.md` — spike recommendation
- `spike/ingredient-canonicalization/results/hallucination_audit.md` — AI accuracy verification
- `spike/ingredient-canonicalization/results/haiku_comparison.md` — Sonnet vs Haiku decision
- `/mnt/transcripts/journal.txt` — catalogue of all session transcripts
