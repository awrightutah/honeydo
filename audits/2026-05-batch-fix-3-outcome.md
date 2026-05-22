# Batch Fix 3 — Outcome (image mime + calendar + spec)

Date: 2026-05-21
Branch: `fix/batch-3-image-and-calendar-2026-05-21` (off `fix/shopping-items-insert-fix-2026-05-21`)

## Branch

`fix/batch-3-image-and-calendar-2026-05-21`

## Modified files

- `apps/mobile/lib/services/image_upload_service.dart` — added `_normalizeImageMime` helper; routed `contentType:` through it.
- `apps/mobile/lib/screens/calendar_screen.dart` — wrapped empty-state Column in `SingleChildScrollView` with `MainAxisSize.min`; wrapped `_EventCard` meta-info Row in horizontal `SingleChildScrollView`.
- `apps/mobile/lib/screens/chore_dashboard_screen.dart` — added `heroTag: 'chores-fab'` to FAB.
- `apps/mobile/lib/screens/recipe_library_screen.dart` — added `heroTag: 'recipes-fab'` to FAB.

## New files

- `supabase/migrations/0010_image_mime_aliases.sql` — DB safety net widening bucket allowlists to also accept `image/jpg`.
- `audits/2026-05-kid-profile-permissions-spec.md` — product spec captured verbatim. Not implemented.
- `audits/2026-05-batch-fix-3-outcome.md` — this report.

## Per-deliverable summary

### Deliverable 1 — image/jpg mime normalization (app + DB)

Single client-side upload site (`image_upload_service.dart:46-53`). The mime string was built as `'image/$fileExt'` where `fileExt` came from the file path's lowercased extension — iOS .jpg → `'image/jpg'` → Supabase 415.

**Diff — `apps/mobile/lib/services/image_upload_service.dart`** (top of file, helper added):

```diff
 import '../theme/app_theme.dart';

+/// Normalizes an image MIME type so Supabase Storage accepts it.
+/// iOS picks JPEGs with extension ".jpg", which produces "image/jpg" —
+/// Supabase rejects that with 415 since the canonical type is "image/jpeg".
+String _normalizeImageMime(String mime) {
+  final lower = mime.toLowerCase();
+  return lower == 'image/jpg' ? 'image/jpeg' : lower;
+}
+
 /// Service for uploading images to Supabase Storage buckets.
 class ImageUploadService {
```

**Diff — same file, upload call:**

```diff
     await _supabase.storage.from(bucketId).uploadBinary(
       filePath,
       fileBytes,
       fileOptions: FileOptions(
-        contentType: 'image/$fileExt',
+        contentType: _normalizeImageMime('image/$fileExt'),
         upsert: true,
       ),
     );
```

**New migration — `supabase/migrations/0010_image_mime_aliases.sql`:** widens the three image buckets' allowed-mime arrays to also accept `image/jpg` as a defensive measure. Full content in the SQL block at the end of this report.

### Deliverable 2 — Calendar tags add/customize UI

**Finding: the UI does not exist.** `grep -rn "calendar_tags" lib/` returns only:
- `calendar_screen.dart:71` — SELECT (read for filter chips)
- `calendar_screen.dart:101` — embedded read on events
- `household_setup_screen.dart:115` — the six default-tag inserts during household creation

No INSERT/UPDATE/DELETE site on `calendar_tags` exists outside `household_setup_screen.dart`. Searched for any "Add tag", "Manage tags", or tag-management screen — none. The "tag filter" row at `calendar_screen.dart:177-210` only filters by existing tags (it's read-only with no `+` chip or edit affordance). `shopping_category_screen.dart` exists for shopping-item categories but doesn't manage `calendar_tags`.

**This is a feature task, not a fix task.** Building it requires:
1. A new "Manage Calendar Tags" screen (likely accessible from the calendar's app bar or settings).
2. An "Add Tag" sheet with fields for `name`, `emoji`, and `color`. Insert into `calendar_tags` with `household_id` from the current household state (same pattern as shopping_items now uses).
3. An "Edit Tag" / "Delete Tag" affordance on each existing tag chip (long-press menu or trailing icon on a tag row in the manage screen).
4. Confirmation on delete because deleting a tag will cascade-set `tag_id = null` on related calendar_events (the schema FK is `on delete set null`).

No code changes made for this deliverable. **No fix applied.**

### Deliverable 3 — Calendar layout overflows + Hero tag clash

**Overflow at line 372 (empty-state Column).** The `_buildDayEvents()` empty branch returned `Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, ...))`. The Column inherited the parent `Expanded`'s constraints and `mainAxisSize: max` made it try to fill — when content height + Center's own min constraints exceeded available height (small phones, narrow layouts), Flutter logged the 12-pixel overflow.

**Diff — `apps/mobile/lib/screens/calendar_screen.dart` (empty-state):**

```diff
     if (dayEvents.isEmpty) {
       return Center(
-        child: Column(
-          mainAxisAlignment: MainAxisAlignment.center,
-          children: [
-            const Text('📋', style: TextStyle(fontSize: 48)),
-            const SizedBox(height: 12),
-            Text('No events', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
-            const SizedBox(height: 4),
-            Text('Tap + to add an event for this day.', style: Theme.of(context).textTheme.bodyMedium),
-          ],
+        child: SingleChildScrollView(
+          padding: const EdgeInsets.symmetric(vertical: 16),
+          child: Column(
+            mainAxisSize: MainAxisSize.min,
+            mainAxisAlignment: MainAxisAlignment.center,
+            children: [
+              const Text('📋', style: TextStyle(fontSize: 48)),
+              const SizedBox(height: 12),
+              Text('No events', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
+              const SizedBox(height: 4),
+              Text('Tap + to add an event for this day.', style: Theme.of(context).textTheme.bodyMedium),
+            ],
+          ),
         ),
       );
     }
```

**The 51-pixel overflow.** The most likely source given the visible code in this screen is the `_EventCard` meta-info `Row` (formerly at lines 500-522). When `startsAt` + `tagName` + `reminder` are all populated on a narrow card, the icons + spacing + text together exceed the Row width — no `Flexible`/`Expanded` wrapping, no `Wrap`, no ellipsis. Wrapped the entire Row in horizontal `SingleChildScrollView` so the content can scroll on narrow screens without overflow logging or visual clipping.

**Diff — same file, _EventCard meta Row:**

```diff
               const SizedBox(height: 8),
-              Row(
-                children: [
-                  if (startsAt != null && !allDay) ...[
-                    Icon(Icons.schedule_rounded, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
-                    const SizedBox(width: 4),
-                    Text(
-                      _formatTime(startsAt, endsAt),
-                      style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
-                    ),
-                    const SizedBox(width: 12),
-                  ],
-                  if (tagName != null) ...[
-                    if (tagEmoji != null) Text(tagEmoji, style: const TextStyle(fontSize: 12)),
-                    const SizedBox(width: 4),
-                    Text(tagName, style: TextStyle(fontSize: 12, color: tagColor, fontWeight: FontWeight.w600)),
-                    const SizedBox(width: 12),
-                  ],
-                  if (reminder != null) ...[
-                    Icon(Icons.notifications_active_rounded, size: 14, color: AppColors.honeyGold),
-                    const SizedBox(width: 4),
-                    Text('${reminder}m before', style: const TextStyle(fontSize: 12, color: AppColors.honeyGold)),
-                  ],
-                ],
+              SingleChildScrollView(
+                scrollDirection: Axis.horizontal,
+                child: Row(
+                  children: [
+                    if (startsAt != null && !allDay) ...[
+                      Icon(Icons.schedule_rounded, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
+                      const SizedBox(width: 4),
+                      Text(
+                        _formatTime(startsAt, endsAt),
+                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
+                      ),
+                      const SizedBox(width: 12),
+                    ],
+                    if (tagName != null) ...[
+                      if (tagEmoji != null) Text(tagEmoji, style: const TextStyle(fontSize: 12)),
+                      const SizedBox(width: 4),
+                      Text(tagName, style: TextStyle(fontSize: 12, color: tagColor, fontWeight: FontWeight.w600)),
+                      const SizedBox(width: 12),
+                    ],
+                    if (reminder != null) ...[
+                      Icon(Icons.notifications_active_rounded, size: 14, color: AppColors.honeyGold),
+                      const SizedBox(width: 4),
+                      Text('${reminder}m before', style: const TextStyle(fontSize: 12, color: AppColors.honeyGold)),
+                    ],
+                  ],
+                ),
               ),
```

**Hero tag clash.** `calendar_screen.dart` has zero Hero widgets. The duplicate-hero-tag error comes from the home shell's `IndexedStack` keeping all five feature screens alive at once. Of those five, two have `FloatingActionButton`s (`chore_dashboard_screen.dart` and `recipe_library_screen.dart`) and neither set a `heroTag`. Two FABs alive in the tree, both using Flutter's default `_DefaultHeroTag()`, → duplicate.

Added unique `heroTag` to each:

**Diff — `apps/mobile/lib/screens/chore_dashboard_screen.dart:366`:**

```diff
       floatingActionButton: _household != null
           ? FloatingActionButton.extended(
+              heroTag: 'chores-fab',
               onPressed: _showAddChoreSheet,
               icon: const Icon(Icons.add_rounded),
               label: const Text('Add Chore'),
             )
           : null,
```

**Diff — `apps/mobile/lib/screens/recipe_library_screen.dart:1084`:**

```diff
       floatingActionButton: FloatingActionButton.extended(
+        heroTag: 'recipes-fab',
         onPressed: () {
           showModalBottomSheet(
             context: context,
             builder: (context) => SafeArea(
               child: Column(
```

### Deliverable 4 — Kid profile permissions spec

Saved verbatim to `audits/2026-05-kid-profile-permissions-spec.md`. **Not implemented.** That work is a separate multi-week batch per the spec's roadmap note.

## Followups

Spotted while doing this work; intentionally not fixed:

1. **Calendar tag management UI does not exist** (Deliverable 2). The feature task: add an "Edit tags" entry point from the calendar app bar that navigates to a new `CalendarTagsScreen` allowing CRUD. Schema is ready (`calendar_tags.emoji` was added by 0008). Out of scope this batch.

2. **Other FABs not in the IndexedStack** (`rewards_screen.dart`, `chore_templates_screen.dart`, `invite_management_screen.dart`, `recipe_detail_screen.dart`) all use the default `heroTag`. They don't currently clash because they're pushed via `Navigator` and only one is on-screen at a time — but if any future change keeps two alive simultaneously (e.g., a tabbed admin screen), the same duplicate-hero error would resurface. Worth giving each a unique `heroTag` proactively. Not done here.

3. **The `_EventCard` meta-info Row is now horizontally scrollable.** That handles overflow but a user with three populated fields needs to scroll. A nicer fix is a `Wrap` widget so overflow wraps to a second line. Both options preserve information; horizontal scroll was the smaller diff and was applied. Worth revisiting.

4. **`recipe_library_screen.dart` infos for `withOpacity` deprecations etc.** still surface in the analyzer (205 infos total). Out of scope this batch; addressed by a future "deprecation cleanup" pass.

5. **`image_upload_service.dart` upload of HEIC files** — iOS may produce `.heic` files for camera captures. The `chore-photos` bucket now accepts `image/heic` (via 0010 + the pre-existing 0003 entry), but `avatars` and `recipe-images` do NOT accept `image/heic`. If a user picks an HEIC photo for those buckets, Supabase will 415. The Flutter `image_picker` package usually converts HEIC to JPEG when reading bytes, so this is unlikely to fire — but worth a test. Not handled here.

6. **`image_upload_service.dart` lookup of mime from path extension is fragile.** If an iOS user picks an image but the path lacks an extension (rare; sometimes happens with shared assets), the resulting mime is `image/path` or similar nonsense. A safer pattern is to use the `mime` package (`lookupMimeType(image.path)`) or inspect the first bytes for magic numbers. Out of scope; the current fix only addresses the dominant case.

7. **Multiple `FloatingActionButton.small` in `recipe_detail_screen.dart`** (lines 508, 515) already set unique `heroTag: 'cart'` and `heroTag: 'meal'`. Confirmed correct; no change.

## Analyzer deltas

| | Total | Errors | Warnings | Infos |
|---|---|---|---|---|
| Before | 327 | 44 | 78 | 205 |
| After  | 327 | 44 | 78 | 205 |
| Delta  | 0 | 0 | 0 | 0 |

No new diagnostics introduced.

## SQL to apply

Apply migration 0010 in the Supabase SQL Editor. Idempotent (each `UPDATE` simply overwrites the array; safe to re-run).

```sql
-- 0010_image_mime_aliases.sql
--
-- Safety net for the "image/jpg" mime type that iOS produces when a user
-- picks a .jpg file. Supabase Storage rejects unrecognized MIME types with
-- HTTP 415; the canonical type is "image/jpeg" but clients sometimes send
-- "image/jpg" (no "e"). The app now normalizes this at upload time in
-- ImageUploadService, but we widen the bucket allowlists to be defensive.
--
-- Idempotent: re-running the file just rewrites the array.

update storage.buckets
set allowed_mime_types = ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/gif']
where id = 'avatars';

update storage.buckets
set allowed_mime_types = ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/gif']
where id = 'recipe-images';

update storage.buckets
set allowed_mime_types = ARRAY['image/jpeg', 'image/jpg', 'image/png', 'image/webp', 'image/heic']
where id = 'chore-photos';
```
