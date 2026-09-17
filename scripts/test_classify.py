#!/usr/bin/env python3
"""
Standalone test of the local Ollama classifier against our real category config.
Not the final classifier (that will be Swift) - this validates the model/prompt
approach before wiring anything up. Talks only to localhost:11434 (Ollama).
Read-only with respect to Safari: these are hardcoded test cases copied from real
bookmarks, never read from or written to Bookmarks.plist.
"""
import json
import urllib.request
import sys
import os
import time

MODEL = "qwen3.5:4b"
OLLAMA_URL = "http://localhost:11434/api/chat"

PROJECT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_PATH = os.path.join(PROJECT_DIR, "Config", "categories.json")

with open(CONFIG_PATH) as f:
    config = json.load(f)

enabled = [c for c in config["categories"] if c["enabled"]]
enabled.sort(key=lambda c: c["order"])

category_lines = []
for c in enabled:
    line = f'- {c["name"]}: {c["description"]}'
    if c["examples"]:
        line += f' Examples: {", ".join(c["examples"])}.'
    if c["exclusions"]:
        line += f' Exclusions: {", ".join(c["exclusions"])}.'
    category_lines.append(line)

rules = config["classifierRules"]

system_prompt = f"""You are classifying a web browser bookmark into exactly one category, based on the user's primary INTENT for the bookmark - what it is being used FOR - not the general subject matter of the website.

Categories (choose exactly one, by name):
{chr(10).join(category_lines)}

Tie-break rule: if a bookmark could reasonably fit more than one category, especially {" vs ".join(rules["tieBreakCategories"])}, default to "{rules["tieBreakDefault"]}" and set needs_review to true.

Respond with ONLY a JSON object matching this exact shape, no other text:
{{"category": "<one of the category names above, exactly>", "confidence": <float 0 to 1>, "reason": "<one short sentence>", "needs_review": <true or false>}}
"""

# Real bookmarks from Amber's actual Safari library, copied here as static test
# cases (title/url only) - this script never opens Bookmarks.plist.
TEST_CASES = [
    {
        "title": "Change Colors in a PNG – Online PNG Maker",
        "url": "https://onlinepngtools.com/change-png-color",
        "domain": "onlinepngtools.com",
        "expected": "Solve",
        "note": "the ambiguous one - retest after tightening Create vs Solve",
    },
    {
        "title": "Watch Free Movies Online | 123movies",
        "url": "https://ww20.0123movie.net/",
        "domain": "0123movie.net",
        "expected": "Consume",
        "note": "unambiguous - watching content someone else made",
    },
    {
        "title": "Register enterthesociety.eth on ENS",
        "url": "https://app.ens.domains/enterthesociety.eth/register",
        "domain": "app.ens.domains",
        "expected": "Solve",
        "note": "revised: registration is a transactional act = Solve, not Create",
    },
    {
        "title": "Ethereum Gas Fees Today ⛽ ETH Gas Chart & Heatmap",
        "url": "https://milkroad.com/ethereum/gas/",
        "domain": "milkroad.com",
        "expected": "Solve",
        "note": "revised: a tracker/live dashboard - matches Solve's dashboards example",
    },
]

def classify(title, url, domain):
    user_prompt = f'Bookmark title: "{title}"\nURL: {url}\nDomain: {domain}'
    payload = {
        "model": MODEL,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        "format": "json",
        "stream": False,
        "think": False,
    }
    req = urllib.request.Request(
        OLLAMA_URL,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
    )
    start = time.time()
    with urllib.request.urlopen(req, timeout=180) as resp:
        result = json.loads(resp.read())
    elapsed = time.time() - start
    raw = result.get("message", {}).get("content", "")
    return raw, elapsed


results = []
for case in TEST_CASES:
    print(f"--- {case['title']} ---")
    print(f"    expected: {case['expected']}  ({case['note']})")
    try:
        raw, elapsed = classify(case["title"], case["url"], case["domain"])
    except Exception as e:
        print(f"    ERROR: {e}")
        results.append((case, None))
        print()
        continue

    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        print(f"    WARNING: not valid JSON: {raw}")
        results.append((case, None))
        print()
        continue

    got = parsed.get("category")
    conf = parsed.get("confidence")
    needs_review = parsed.get("needs_review")
    status = "MATCH" if got == case["expected"] else "MISMATCH"
    print(f"    got: {got}  (confidence {conf}, needs_review {needs_review})  [{elapsed:.1f}s]  -> {status}")
    print(f"    reason: {parsed.get('reason')}")
    results.append((case, parsed))
    print()

print("=== Summary ===")
for case, parsed in results:
    if parsed is None:
        print(f"  ERROR      {case['title']}")
    else:
        status = "MATCH   " if parsed.get("category") == case["expected"] else "MISMATCH"
        print(f"  {status}  {case['title']}  (expected {case['expected']}, got {parsed.get('category')})")
