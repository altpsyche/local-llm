"""Bob tool: web_search (SearXNG) and web_fetch."""
import re
import sys

import requests

_cfg: dict = {}
_searxng_url: str = ""


def configure(config: dict) -> None:
    global _cfg, _searxng_url
    _cfg = config
    port = config.get("searxngPort", 8888)
    _searxng_url = f"http://localhost:{port}/search"


def _web_search(query: str, num_results: int = 5) -> str:
    if not _searxng_url:
        return "web_search not configured (SearXNG URL missing)"
    try:
        r = requests.get(
            _searxng_url,
            params={"q": query, "format": "json", "pageno": 1},
            timeout=10,
        )
        r.raise_for_status()
        results = r.json().get("results", [])[:num_results]
    except Exception as e:
        return f"web_search error: {e}\nIs SearXNG running? Try: bob services start"
    if not results:
        return "(no results)"
    return "\n\n".join(
        f"- {x['title']}\n  {x['url']}\n  {x.get('content', '')[:200]}"
        for x in results
    )


def _web_fetch(url: str) -> str:
    try:
        r = requests.get(url, timeout=15, headers={"User-Agent": "Mozilla/5.0"})
        r.raise_for_status()
        text = re.sub(r"<[^>]+>", " ", r.text)
        text = re.sub(r"\s+", " ", text).strip()
        return text[:4000]
    except Exception as e:
        return f"web_fetch error: {e}"


def test() -> str:
    return _web_search("local LLM news 2025", num_results=2)


TOOL_DEFS = [
    {
        "type": "function",
        "function": {
            "name": "web_search",
            "description": "Search the web via SearXNG (private, local search engine)",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "Search query"},
                    "num_results": {
                        "type": "integer",
                        "description": "Number of results to return (default 5)",
                    },
                },
                "required": ["query"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "web_fetch",
            "description": "Fetch and read the text content of a URL (HTML stripped)",
            "parameters": {
                "type": "object",
                "properties": {
                    "url": {"type": "string", "description": "URL to fetch"},
                },
                "required": ["url"],
            },
        },
    },
]

DISPATCH = {
    "web_search": _web_search,
    "web_fetch": _web_fetch,
}
