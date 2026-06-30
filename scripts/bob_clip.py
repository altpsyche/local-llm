#!/usr/bin/env python3
"""bob clip — fast web clip: fetch → summarize → store in memory.

One LLM call (no agent loop). Much faster than spinning up the full agent.
"""
import re
import sys
from pathlib import Path

REPO = Path(__file__).parent.parent
sys.path.insert(0, str(REPO / "scripts"))


def main():
    import argparse

    p = argparse.ArgumentParser(description="Fetch a URL, summarize it, and store in memory")
    p.add_argument("url", help="URL to clip")
    p.add_argument("--note", default="", help="Optional note to append to the memory entry")
    args = p.parse_args()

    from bob_core import get_llm_client, load_config, memory_store

    try:
        config = load_config()
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    import requests

    print(f"Fetching {args.url} ...", file=sys.stderr)
    try:
        r = requests.get(args.url, timeout=20, headers={"User-Agent": "Mozilla/5.0"})
        r.raise_for_status()
    except Exception as e:
        print(f"Fetch error: {e}", file=sys.stderr)
        sys.exit(1)

    # Strip HTML, collapse whitespace
    text = re.sub(r"<[^>]+>", " ", r.text)
    text = re.sub(r"\s+", " ", text).strip()
    text = text[:4000]

    print("Summarizing ...", file=sys.stderr)
    client = get_llm_client(config)
    role = config.get("routing", {}).get("defaultRole", "chat")
    try:
        resp = client.chat.completions.create(
            model=role,
            messages=[
                {
                    "role": "user",
                    "content": (
                        f"Summarize the following web page content in 3-5 concise sentences. "
                        f"Focus on the key information.\n\nURL: {args.url}\n\n{text}"
                    ),
                }
            ],
            stream=False,
        )
        summary = resp.choices[0].message.content or ""
    except Exception as e:
        print(f"LLM error: {e}", file=sys.stderr)
        sys.exit(1)

    print(summary)

    # Store in memory
    entry = f"[clip] {args.url}: {summary}"
    if args.note:
        entry += f" Note: {args.note}"
    try:
        memory_store(entry, tags="clip", config=config)
        print("\n[saved to memory]", file=sys.stderr)
    except Exception as e:
        print(f"\n[memory store failed: {e}]", file=sys.stderr)


if __name__ == "__main__":
    main()
