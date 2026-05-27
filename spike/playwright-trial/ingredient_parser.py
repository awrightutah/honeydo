"""Shared helpers for the spike runners.

`parse_ingredient_line(line)` turns a free-text ingredient string into the
app's structured shape `{name, unit, quantity, category}`. Used by the
schema_org and recipe_scrapers runners which both produce free-text
ingredient strings; the AI runner returns structured shapes directly from
the model so it skips this.

Parsing is intentionally simple — a regex covering the common patterns
("2 cups flour", "1/2 tsp salt", "1 1/2 lbs chicken", "3 eggs"). When the
heuristic can't extract a quantity/unit, the whole input ends up in `name`
and `unit` defaults to "count" with `quantity = "1"`. The downstream
comparison reports how often each approach yields a clean parse vs a
"name dump" parse so we can judge fidelity.

Category guessing isn't done here — the structured format requires a
category and neither schema.org nor recipe-scrapers expose one, so callers
default to "Other" and the AI approach provides the category itself.
"""

from __future__ import annotations

import re
from typing import Optional

# Common units, normalised to short forms. Anything not in this map is left
# as-is. Order matters: longer aliases first so 'tablespoon' matches before
# 'tbsp' would (it wouldn't, but the principle stands for ambiguous cases).
_UNIT_ALIASES = {
    "tablespoons": "tbsp",
    "tablespoon": "tbsp",
    "tbsps": "tbsp",
    "tbsp": "tbsp",
    "tbs": "tbsp",
    "teaspoons": "tsp",
    "teaspoon": "tsp",
    "tsps": "tsp",
    "tsp": "tsp",
    "cups": "cup",
    "cup": "cup",
    "ounces": "oz",
    "ounce": "oz",
    "oz": "oz",
    "pounds": "lb",
    "pound": "lb",
    "lbs": "lb",
    "lb": "lb",
    "grams": "g",
    "gram": "g",
    "g": "g",
    "kilograms": "kg",
    "kilogram": "kg",
    "kg": "kg",
    "milliliters": "ml",
    "millilitres": "ml",
    "ml": "ml",
    "liters": "l",
    "litres": "l",
    "l": "l",
    "cloves": "cloves",
    "clove": "cloves",
    "heads": "head",
    "head": "head",
    "bunches": "bunch",
    "bunch": "bunch",
    "sprigs": "sprig",
    "sprig": "sprig",
    "slices": "slice",
    "slice": "slice",
    "pinch": "pinch",
    "dash": "dash",
}

# Regex parts
_NUMBER = r"\d+(?:\.\d+)?"  # 2 or 2.5
_FRACTION = r"\d+/\d+"  # 1/2
_MIXED = rf"{_NUMBER}\s+{_FRACTION}"  # 1 1/2
_QUANTITY_PATTERN = rf"({_MIXED}|{_FRACTION}|{_NUMBER})"

# Unicode fractions Allrecipes and others sometimes emit
_UNICODE_FRACTIONS = {
    "½": "0.5",
    "⅓": "0.333",
    "⅔": "0.667",
    "¼": "0.25",
    "¾": "0.75",
    "⅕": "0.2",
    "⅖": "0.4",
    "⅗": "0.6",
    "⅘": "0.8",
    "⅙": "0.167",
    "⅚": "0.833",
    "⅛": "0.125",
    "⅜": "0.375",
    "⅝": "0.625",
    "⅞": "0.875",
}


def _fraction_to_decimal(s: str) -> str:
    """'1/2' -> '0.5'. '1 1/2' -> '1.5'. Plain numbers pass through."""
    s = s.strip()
    if " " in s:  # mixed fraction
        whole, frac = s.split(" ", 1)
        return str(float(whole) + _fraction_to_decimal_float(frac))
    if "/" in s:
        return str(_fraction_to_decimal_float(s))
    return s


def _fraction_to_decimal_float(s: str) -> float:
    num, den = s.split("/")
    return float(num) / float(den)


def _normalize_unicode_fractions(line: str) -> str:
    for uni, dec in _UNICODE_FRACTIONS.items():
        # Insert a space before the fraction so '1½' becomes '1 0.5' (then
        # mixed-fraction handling does the rest), and bare '½' becomes ' 0.5'.
        line = line.replace(uni, f" {dec}")
    return line.strip()


def parse_ingredient_line(line: str, default_category: str = "Other") -> dict:
    """Parse one free-text ingredient line into the app's structured shape.

    Returns a dict with keys: name, unit, quantity, category. When parsing
    can't recover a quantity/unit, the whole input lands in `name` and unit
    defaults to 'count' with quantity '1' — matching how the app treats
    whole-item ingredients like '4 eggs'.
    """
    original = (line or "").strip()
    if not original:
        return {
            "name": "",
            "unit": "count",
            "quantity": "1",
            "category": default_category,
            "_parse_quality": "empty",
        }

    cleaned = _normalize_unicode_fractions(original)

    # Try: <quantity> <unit?> <name>
    m = re.match(
        rf"^\s*{_QUANTITY_PATTERN}\s+([a-zA-Z]+)\s+(.+)$",
        cleaned,
    )
    if m:
        qty_raw = m.group(1)
        possible_unit = m.group(2).lower().rstrip(".,")
        rest = m.group(3).strip()
        if possible_unit in _UNIT_ALIASES:
            return {
                "name": rest,
                "unit": _UNIT_ALIASES[possible_unit],
                "quantity": _fraction_to_decimal(qty_raw),
                "category": default_category,
                "_parse_quality": "full",
            }
        # quantity + word that isn't a unit -> treat word as part of name,
        # unit defaults to count
        return {
            "name": f"{possible_unit} {rest}".strip(),
            "unit": "count",
            "quantity": _fraction_to_decimal(qty_raw),
            "category": default_category,
            "_parse_quality": "qty_only",
        }

    # Try: <quantity> <name> (no unit, e.g. "3 eggs")
    m = re.match(rf"^\s*{_QUANTITY_PATTERN}\s+(.+)$", cleaned)
    if m:
        return {
            "name": m.group(2).strip(),
            "unit": "count",
            "quantity": _fraction_to_decimal(m.group(1)),
            "category": default_category,
            "_parse_quality": "qty_only",
        }

    # Fall through: no quantity at all. Put everything in name.
    return {
        "name": original,
        "unit": "count",
        "quantity": "1",
        "category": default_category,
        "_parse_quality": "name_only",
    }
