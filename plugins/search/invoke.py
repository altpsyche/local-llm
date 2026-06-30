#!/usr/bin/env python3
"""bob search — search files in a directory and synthesise results via local LLM.

Usage:
  bob search "todo items"
  bob search "error handling" --path src/
  bob search "API endpoints" --ext .py
  bob search "config loading" --raw         show raw grep output, skip LLM
"""
import sys
import argparse
import subprocess
import shutil
from pathlib import Path

REPO = Path(__file__).parent.parent.parent
sys.path.insert(0, str(REPO / "scripts"))

from bob_core import load_config, get_llm_client, check_litellm


def run_rg(query: str, search_path: str, ext: str | None) -> str:
    """Search with ripgrep (preferred) or fall back to findstr."""
    if shutil.which("rg"):
        cmd = [
            "rg", "--max-count=5", "--with-filename", "--line-number",
            "--context=2", "--no-heading", "--color=never", "--smart-case",
        ]
        if ext:
            cmd += ["--glob", f"*{ext}"]
        cmd += [query, "."]
        cwd = search_path
    else:
        # Windows findstr fallback
        pattern = f"*.{ext.lstrip('.')}" if ext else "*.*"
        cmd = ["cmd", "/c", "findstr", "/s", "/n", "/i", query, pattern]
        cwd = search_path

    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30, cwd=cwd)
        out = r.stdout.strip()
        return out[:6000] if out else "(no matches found)"
    except subprocess.TimeoutExpired:
        return "(search timed out)"
    except FileNotFoundError:
        return "(search tool not available — install ripgrep: winget install BurntSushi.ripgrep.MSVC)"


def synthesise(query: str, matches: str, config: dict) -> str:
    """Synthesise ripgrep results via LLM. Returns analysis string."""
    role = config.get("routing", {}).get("defaultRole", "chat")
    client = get_llm_client(config)

    prompt = (
        f'Search query: "{query}"\n\n'
        f"Search results:\n```\n{matches}\n```\n\n"
        "Summarise what was found: highlight the most relevant matches, "
        "explain what the code or content is doing, and note any patterns. "
        "Be specific and concise."
    )

    resp = client.chat.completions.create(
        model=role,
        messages=[
            {
                "role": "system",
                "content": (
                    "You are Bob, a code search assistant. "
                    "Analyse search results and give a clear, actionable summary. "
                    "Reference specific file names and line numbers from the results."
                ),
            },
            {"role": "user", "content": prompt},
        ],
        stream=False,
    )
    return resp.choices[0].message.content or ""


def main():
    p = argparse.ArgumentParser(description="Search files and synthesise results via local LLM")
    p.add_argument("query", nargs="+", help="What to search for")
    p.add_argument("--path", default=".", help="Directory to search (default: current dir)")
    p.add_argument("--ext", default=None, help="File extension filter (e.g. .py, .ts, .md)")
    p.add_argument("--raw", action="store_true", help="Show raw matches only, skip LLM synthesis")
    p.add_argument("--role", default=None, help="Model role override")
    args = p.parse_args()

    query = " ".join(args.query)
    search_path = str(Path(args.path).resolve())

    print(f"\033[90mSearching '{query}' in {search_path}...\033[0m", file=sys.stderr)
    matches = run_rg(query, search_path, args.ext)

    if args.raw or matches.startswith("(no matches"):
        print(matches)
        return

    try:
        config = load_config()
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    if not check_litellm(config):
        # LLM unavailable — fall back to raw output
        print(matches)
        return

    if args.role:
        config.setdefault("routing", {})["defaultRole"] = args.role

    print(synthesise(query, matches, config))


if __name__ == "__main__":
    main()
