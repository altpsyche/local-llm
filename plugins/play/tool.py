"""Bob tool: music_play — open music in Spotify or YouTube Music.

Voice-safe: fire-and-forget, no confirmation prompt, no blocking.

YouTube path: searches SearXNG for a direct youtube.com/watch URL and opens
it — video starts playing immediately. Falls back to YouTube Music search page
if SearXNG is unavailable.

Spotify path: opens spotify:search: URI (Spotify handles playback).
"""
import os
import sys
import urllib.parse
from pathlib import Path

_cfg: dict = {}


def configure(config: dict) -> None:
    global _cfg
    _cfg = config


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

def _spotify_installed() -> bool:
    appdata = os.environ.get("APPDATA", "")
    localappdata = os.environ.get("LOCALAPPDATA", "")
    candidates = [
        Path(appdata) / "Spotify" / "Spotify.exe",
        Path(localappdata) / "Microsoft" / "WindowsApps" / "Spotify.exe",
    ]
    return any(p.exists() for p in candidates)


def _find_youtube_url(query: str) -> str | None:
    """Ask SearXNG for the first youtube.com/watch result for query."""
    try:
        import requests
        port = _cfg.get("searxngPort", 8888)
        r = requests.get(
            f"http://localhost:{port}/search",
            params={"q": f"{query} site:youtube.com", "format": "json", "pageno": 1},
            timeout=5,
        )
        r.raise_for_status()
        for result in r.json().get("results", []):
            url = result.get("url", "")
            if "youtube.com/watch" in url:
                return url
    except Exception as e:
        # M16 — SearXNG lookup is best-effort (caller falls back to the search page),
        # but log the swallow so a persistently-broken SearXNG isn't invisible.
        print(f"[play] youtube lookup via SearXNG failed: {e}", file=sys.stderr)
    return None


def _open(uri: str) -> None:
    os.startfile(uri)


# ---------------------------------------------------------------------------
# Tool function
# ---------------------------------------------------------------------------

def _music_play(query: str, platform: str = "auto") -> str:
    query = query.strip()
    if not query:
        return "No query provided."

    platform = platform.lower()

    try:
        if platform == "spotify":
            _open(f"spotify:search:{urllib.parse.quote(query)}")
            return f"Opening Spotify: {query}"

        if platform in ("youtube", "auto") and not (platform == "auto" and _spotify_installed()):
            # Try to find a direct watch URL so the video plays immediately
            url = _find_youtube_url(query)
            if url:
                _open(url)
                return f"Playing on YouTube: {query}"
            # SearXNG unavailable — fall back to search page
            _open(f"https://music.youtube.com/search?q={urllib.parse.quote(query)}")
            return f"Opening YouTube Music search: {query} (SearXNG unavailable — click to play)"

        # auto + Spotify installed
        _open(f"spotify:search:{urllib.parse.quote(query)}")
        return f"Opening Spotify: {query}"

    except OSError as e:
        return f"music_play error: {e}"


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------

def test() -> str:
    url = _find_youtube_url("Arctic Monkeys")
    searxng_status = f"SearXNG found: {url}" if url else "SearXNG unavailable (fallback active)"
    platform = "Spotify" if _spotify_installed() else "YouTube"
    return f"music_play: OK — default platform: {platform} | {searxng_status}"


# ---------------------------------------------------------------------------
# Schema + dispatch
# ---------------------------------------------------------------------------

TOOL_DEFS = [
    {
        "type": "function",
        "function": {
            "name": "music_play",
            "description": (
                "Open music in Spotify or YouTube. "
                "Use when the user asks to play a song, artist, album, or playlist. "
                "Finds a direct YouTube video URL so music starts playing immediately. "
                "Prefers Spotify if installed. "
                "Pass platform='youtube' if the user says 'on YouTube'."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {
                        "type": "string",
                        "description": (
                            "Artist, song, album, or playlist to search for. "
                            "Examples: 'Arctic Monkeys', 'Bohemian Rhapsody', "
                            "'lofi hip hop', 'dark side of the moon'."
                        ),
                    },
                    "platform": {
                        "type": "string",
                        "enum": ["auto", "spotify", "youtube"],
                        "description": (
                            "'auto' tries Spotify first, falls back to YouTube. "
                            "'spotify' forces Spotify. 'youtube' forces YouTube."
                        ),
                    },
                },
                "required": ["query"],
            },
        },
    }
]

DISPATCH = {"music_play": _music_play}

EXIT_VOICE = True
