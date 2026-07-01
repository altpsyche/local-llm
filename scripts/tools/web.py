"""Bob tool: web_search (SearXNG) and web_fetch."""
import ipaddress
import re
import socket
from urllib.parse import urlparse

import requests

_cfg: dict = {}
_searxng_url: str = ""
_allow_private_fetch: bool = False  # M9 — gate SSRF-prone fetches behind an explicit flag


def configure(config: dict) -> None:
    global _cfg, _searxng_url, _allow_private_fetch
    _cfg = config
    port = config.get("searxngPort", 8888)
    _searxng_url = f"http://localhost:{port}/search"
    _allow_private_fetch = bool(config.get("agent", {}).get("allowPrivateFetch", False))


def _is_blocked_host(host: str) -> bool:
    """True if the host resolves to a loopback/private/link-local/reserved address (SSRF risk).
    DNS failures return False so requests raises its own clean error instead of being masked."""
    if not host:
        return True
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return False
    for info in infos:
        try:
            addr = ipaddress.ip_address(info[4][0])
        except ValueError:
            continue
        if (addr.is_loopback or addr.is_private or addr.is_link_local
                or addr.is_reserved or addr.is_multicast or addr.is_unspecified):
            return True
    return False


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
    # M9 — allowlist http/https and block private/loopback targets unless explicitly opted in.
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https"):
        return f"web_fetch error: blocked scheme '{parsed.scheme or '(none)'}' (only http/https allowed)"
    if not _allow_private_fetch and _is_blocked_host(parsed.hostname or ""):
        return (
            f"web_fetch error: blocked host '{parsed.hostname}' "
            "(loopback/private address; set agent.allowPrivateFetch = $true to override)"
        )
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
