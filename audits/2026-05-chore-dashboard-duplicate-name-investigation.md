# Chore Dashboard — Duplicate "Wrights" Display (Investigation)

Date: 2026-05-26
Branch: `feat/ui-hardening-batch-7a-i-2026-05-26`
Status: **READ-ONLY investigation** — no code changes

## TL;DR

Two stacked Scaffolds, two AppBars, both rendering `[household.emoji] [household.name]`. `chore_dashboard_screen.dart:302` breaks a clear app-wide convention used by all 4 sibling tab screens (Shopping List 🛒 / Meal Planner 🍽️ / Recipe Library 📚 / Family Calendar 📅) — those use a constant screen-name title. Chore dashboard alone shows `'${household.name} 🐝'`. The Batch 7a-i smoke surfaced this because pre-7a-i the household name didn't render at all for kid sessions in some places (the `.eq('auth_user_id')` bug masked some flows), but the chore_dashboard inner AppBar was always visible and always duplicated home_shell's outer AppBar.

**Recommended fix: shape A in the brief — 1 LOC.** Replace the household-name title in `chore_dashboard_screen.dart:302` with a constant screen-name title (matching sibling tabs). No behavior change beyond the title text.

## Phase 1 — Both display sites

### Site 1 — outer `home_shell_screen.dart:278-296` (persistent AppBar)

```dart
appBar: _isLoading
    ? null
    : AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_household?['emoji'] != null && (_household!['emoji'] as String).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  _household!['emoji'],         // → '🐝'
                  style: const TextStyle(fontSize: 22),
                ),
              ),
            Flexible(
              child: Text(
                _household?['name'] ?? 'Honeydo',   // → 'Wrights'
                style: const TextStyle(fontWeight: FontWeight.w800),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        actions: [
          // Points badge, Approvals inbox (admin only), popup menu, etc.
        ],
      ),
```

Renders as: **🐝 Wrights**. This is the top-of-screen AppBar that's visible on every tab (Chores / Meals / Shop / Recipes / Calendar). It carries the global actions (points badge, Approvals icon for admin, profile-switch popup).

### Site 2 — inner `chore_dashboard_screen.dart:302` (tab-specific AppBar)

```dart
return Scaffold(
  appBar: AppBar(
    title: Text(_household?['name'] != null ? '${_household!['name']} 🐝' : 'Today\'s Chores 🐝'),
    actions: [
      if (_household != null)
        IconButton(
          icon: const Icon(Icons.add_circle_outline_rounded),
          onPressed: _showAddChoreSheet,
          tooltip: 'Add chore',
        ),
      IconButton(
        icon: const Icon(Icons.refresh_rounded),
        onPressed: _loadData,
        tooltip: 'Refresh',
      ),
    ],
  ),
  body: Stack(...),
  ...
);
```

Renders as: **Wrights 🐝** when household loaded; falls back to **Today's Chores 🐝** when household is null.

`chore_dashboard_screen.dart` is rendered inside `home_shell_screen.dart`'s tab body. Because each is a `Scaffold` with its own `appBar:`, both AppBars draw — outer is the persistent home_shell AppBar; inner is the chore_dashboard AppBar that sits beneath it. So the visible stack on the Chores tab is:

```
+--------------------------------+
| 🐝 Wrights  ★50  📥3  ⋯       |   ← home_shell AppBar (outer)
+--------------------------------+
| Wrights 🐝       ➕  ↻         |   ← chore_dashboard AppBar (inner)
+--------------------------------+
| [body...]                      |
+--------------------------------+
```

Two displays of the same household identity, just with the emoji on opposite sides.

## Phase 2 — Intent

### Sibling tab convention

Every other tab in the app uses a **constant screen-name title** for its inner AppBar:

| File | Inner AppBar title |
|---|---|
| `shopping_list_screen.dart:466` | `const Text('Shopping List 🛒')` |
| `meal_planner_screen.dart:198` | `const Text('Meal Planner 🍽️')` |
| `recipe_library_screen.dart:1063` | `const Text('Recipe Library 📚')` |
| `calendar_screen.dart:174` | `const Text('Family Calendar 📅')` |

None of them shows the household name. The household name is **only** in the outer home_shell AppBar.

### What chore_dashboard's title was *originally*

Line 302 has the fallback `'Today\'s Chores 🐝'`. That's the value when `_household` is null. The conditional `_household?['name'] != null ? '${_household!['name']} 🐝' : 'Today\'s Chores 🐝'` strongly suggests the **original** title was `'Today's Chores 🐝'` — matching the sibling convention — and someone later added the household-name override branch without realizing it duplicated the outer AppBar.

There's no comment explaining the household-name branch. No similar pattern anywhere else.

### Why this only surfaced now

Pre-Batch-7a-i, `chore_dashboard_screen.dart:67-70` used the legacy `.eq('auth_user_id', user.id)` pattern (now migrated). For kid sessions, this still returned the parent admin's row, which carried the household join, so `_household['name']` was populated either way. The double-render has been there the whole time.

The user noticed it during Batch 7a-i smoke because the migration drew attention to header-area rendering. **The duplication is not caused by Batch 7a-i** — it was always there. Batch 7a-i just made the user look at this area of the screen.

## Phase 3 — Recommended fix

**Shape A — match the sibling convention.** Change line 302 from:

```dart
title: Text(_household?['name'] != null ? '${_household!['name']} 🐝' : 'Today\'s Chores 🐝'),
```

to:

```dart
title: const Text("Today's Chores 🐝"),
```

Behavior change: the inner AppBar of the Chores tab will always read **Today's Chores 🐝** regardless of household state. The outer AppBar keeps showing **🐝 Wrights** (or whatever the household is called). No more duplication.

Sibling tabs already do this; chore_dashboard becomes consistent with them.

### Why not shape B (remove the inner AppBar entirely)?

The inner AppBar carries the Add Chore (`➕`) and Refresh (`↻`) icon actions. Removing it would force those actions elsewhere — most likely into the existing extended FAB or duplicated in the outer AppBar. That's a bigger refactor with more behavior implications (e.g., the Refresh button is screen-specific; lifting it to home_shell would imply it refreshes all tabs). Not worth the scope expansion.

### Why not shape C (no change)?

Two AppBars showing the same string is visually noisy and breaks the otherwise-consistent app convention. The user noticed it on first iPhone smoke — that's the signal it's worth fixing.

## Phase 4 — Scope

**1 LOC change** on `chore_dashboard_screen.dart:302`. Plus the `const` keyword now becomes possible since the string is no longer conditional. No imports change. No state change. No analyzer impact expected.

5 minutes including iPhone smoke verification.

## What this investigation deliberately did NOT do

- Did not modify any file.
- Did not commit anything.
- Did not investigate whether other screens have a similar "show household name in inner AppBar" pattern (none surfaced from the grep across 4 sibling tabs; if any do, they'd be additional cleanup targets).

## Recommended next step

Single-line fix at `chore_dashboard_screen.dart:302`. Folds cleanly into the 7a-i changes as a polish nit, or as a separate "fix(ui): drop duplicate household name on chore_dashboard" commit.
