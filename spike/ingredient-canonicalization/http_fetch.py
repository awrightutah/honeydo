"""HTTP fetch with a normal browser User-Agent and BeautifulSoup-based
text cleanup. Used by the schema_org and ai runners.

`recipe-scrapers` does its own fetching internally, so it doesn't use these
helpers.
"""

from __future__ import annotations

from typing import Optional

import requests
from bs4 import BeautifulSoup

# Generic, well-known browser UA. Some sites block the default
# `python-requests/X.Y` UA outright.
_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/120.0.0.0 Safari/537.36"
)


def fetch_html(url: str, timeout: int = 20) -> str:
    """Fetch the URL and return the response body. Raises requests
    exceptions on failure; caller should wrap in try/except."""
    resp = requests.get(
        url,
        headers={
            "User-Agent": _USER_AGENT,
            "Accept": (
                "text/html,application/xhtml+xml,application/xml;q=0.9,"
                "image/avif,image/webp,*/*;q=0.8"
            ),
            "Accept-Language": "en-US,en;q=0.5",
        },
        timeout=timeout,
        allow_redirects=True,
    )
    resp.raise_for_status()
    return resp.text


def clean_text_for_ai(html: str, max_chars: int = 30_000) -> str:
    """Strip nav/footer/ads and return the rendered text content.

    Intentionally drops <script> as well — this means JSON-LD data
    embedded in <script type="application/ld+json"> is REMOVED before the
    AI sees the page. That's deliberate: the AI approach should be measured
    on its ability to extract from rendered prose (what a human reader
    sees), not on its ability to parse JSON-LD (which schema.org already
    does). If we left JSON-LD in, the AI's results would mostly mirror
    schema.org's and the comparison would collapse.
    """
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(
        ["script", "style", "nav", "footer", "header", "aside", "noscript", "form"]
    ):
        tag.decompose()
    text = soup.get_text(separator="\n", strip=True)
    if len(text) > max_chars:
        text = text[:max_chars] + "\n... [content truncated]"
    return text


def find_jsonld_recipe(html: str) -> Optional[dict]:
    """Search the page's JSON-LD blocks for a Recipe entity. Returns the
    Recipe object as a dict, or None if no recipe schema is present.

    Handles the three common shapes:
      1. A bare Recipe object (`@type: "Recipe"`)
      2. A Graph object with `@graph` array containing a Recipe entity
      3. A top-level JSON array, one item of which is a Recipe
    """
    import json

    soup = BeautifulSoup(html, "html.parser")
    for script in soup.find_all("script", attrs={"type": "application/ld+json"}):
        try:
            payload = json.loads(script.string or "")
        except (json.JSONDecodeError, TypeError):
            continue

        candidates = []
        if isinstance(payload, list):
            candidates.extend(payload)
        elif isinstance(payload, dict):
            candidates.append(payload)
            if isinstance(payload.get("@graph"), list):
                candidates.extend(payload["@graph"])

        for c in candidates:
            if not isinstance(c, dict):
                continue
            t = c.get("@type")
            if t == "Recipe" or (isinstance(t, list) and "Recipe" in t):
                return c

    return None
