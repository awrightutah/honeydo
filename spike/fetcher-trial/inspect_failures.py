"""
One-off: fetch Allrecipes and King Arthur via ScraperAPI again, save raw HTML
to inspect what we actually got back.

Allrecipes: returned 200 but only 17 KB. Want to see: real recipe content?
captcha? "browser not supported" interstitial? stripped page?

King Arthur: returned 404. Want to see: KA's 404 page? ScraperAPI error
message? Cloudflare interstitial?
"""

import os
import sys
import time
from pathlib import Path

import requests
from dotenv import load_dotenv

load_dotenv()
SCRAPERAPI_KEY = os.environ.get("SCRAPERAPI_KEY")
if not SCRAPERAPI_KEY or SCRAPERAPI_KEY == "your_key_here":
    print("ERROR: SCRAPERAPI_KEY not set in .env", file=sys.stderr)
    sys.exit(1)

SCRIPT_DIR = Path(__file__).resolve().parent
OUT_DIR = SCRIPT_DIR / "results" / "raw_html"
OUT_DIR.mkdir(parents=True, exist_ok=True)

TARGETS = [
    ("allrecipes", "https://www.allrecipes.com/recipe/10813/best-chocolate-chip-cookies/"),
    ("kingarthur", "https://www.kingarthurbaking.com/recipes/king-arthur-classic-white-bread-recipe"),
]

for name, url in TARGETS:
    print(f"\n=== {name} ===")
    print(f"URL: {url}")
    start = time.monotonic()
    resp = requests.get(
        "http://api.scraperapi.com/",
        params={"api_key": SCRAPERAPI_KEY, "url": url, "render": "true"},
        timeout=90,
    )
    duration = round(time.monotonic() - start, 2)
    print(f"Status: {resp.status_code}  Duration: {duration}s  Bytes: {len(resp.content):,}")

    # Save raw body
    ext = ".html" if resp.status_code == 200 else f".status{resp.status_code}.html"
    out_path = OUT_DIR / f"{name}{ext}"
    with open(out_path, "wb") as f:
        f.write(resp.content)
    print(f"Saved: {out_path.relative_to(SCRIPT_DIR)}")

    # Quick body fingerprint — first 500 chars of decoded text
    try:
        snippet = resp.text[:500]
        print(f"--- First 500 chars ---")
        print(snippet)
        print(f"--- end snippet ---")
    except Exception as e:
        print(f"Could not decode body: {e}")
