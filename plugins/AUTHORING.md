# Plugin and Tool Authoring Guide

## Three-Layer Model

```
Layer 1  scripts/tools/<name>.py        infrastructure / pure plumbing
Layer 2  plugins/<name>/tool.py         agent-facing interface for a CLI plugin
Layer 3  plugins/<name>/invoke.py       human-facing CLI wrapper
```

**Layer 1 — Infrastructure tools** (`scripts/tools/`)
Pure agent-internal capabilities with no meaningful standalone CLI. Examples: `git`, `file`, `memory`, `web`, `shell`. Rule: if a human would never type `bob <name>` directly, it lives here.

**Layer 2 — Plugin tool** (`plugins/<name>/tool.py`)
The agent interface for a plugin that also has a CLI command. Imports and calls the same core function as the CLI — no duplicated logic. Rule: if `bob <name>` exists AND the agent should be able to call it too, create this file.

**Layer 3 — Plugin CLI** (`plugins/<name>/invoke.py` or `invoke.ps1`)
The human-facing entry point. Handles argparse, stdin, flags, output formatting. Calls the shared core function. Contains no core logic itself.

### Decision Rule

```
New capability?
├── No meaningful `bob <name>` CLI?
│   └── scripts/tools/<name>.py   (Layer 1)
├── Has a `bob <name>` CLI?
│   ├── Agent should call it too?
│   │   └── plugins/<name>/invoke.py + plugins/<name>/tool.py   (Layers 2+3)
│   └── CLI-only, agent use unlikely?
│       └── plugins/<name>/invoke.py only   (Layer 3 only)
```

---

## Core Logic Rule

Every plugin that has both a CLI and a tool MUST extract its core logic into a shared function in `invoke.py`. The tool imports and calls it. The CLI calls it too. Logic lives in exactly one place.

```
plugins/<name>/
  invoke.py       # CLI: argparse → calls _core_fn() → formats output
  tool.py         # Agent: TOOL_DEFS + DISPATCH → calls _core_fn()
  description.txt
```

Example from `summarise`:
```python
# invoke.py
def summarise(content: str, length: str = "medium", config: dict = None) -> str:
    """Core logic. Returns the summary string."""
    ...

def main():
    args = parse()
    config = load_config()
    content = read_input(args)
    print(summarise(content, args.length, config))
```

```python
# tool.py
from plugins.summarise.invoke import summarise
_cfg = {}
def configure(config): global _cfg; _cfg = config
TOOL_DEFS = [...]
DISPATCH = {"summarise_text": lambda content, length="medium": summarise(content, length, _cfg)}
```

---

## Required Exports

Every tool file (Layer 1 or Layer 2) must export:

```python
TOOL_DEFS   # list[dict]  — OpenAI function-calling schemas
DISPATCH    # dict[str, callable]  — tool_name → function
configure(config: dict)  # called once at startup with full config
```

Optionally:
```python
test() -> str  # called by `bob tools test <name>`; return a status string
```

### TOOL_DEFS format

```python
TOOL_DEFS = [
    {
        "type": "function",
        "function": {
            "name": "tool_name",
            "description": "What this does. When to call it.",
            "parameters": {
                "type": "object",
                "properties": {
                    "param": {"type": "string", "description": "..."},
                },
                "required": ["param"],
            },
        },
    }
]
```

---

## Registration Rule

Every Layer 1 or Layer 2 tool must be added to `agent.tools` in `config/bob.psd1`:

```powershell
agent = @{
    tools = @('memory', 'web', 'git', 'file', 'shell', 'fabric', 'play', 'summarise', 'draft', 'search')
}
```

The loader silently skips names not in this list. **This is the only manual step.**

For plugin tools (Layer 2), use the **directory name** (`play`, not `music`). The tool name exposed to the agent (e.g. `music_play`) is set inside `TOOL_DEFS` — it's independent of the directory name.

---

## Testing

```powershell
# List all discoverable tools and their status
bob tools list

# Run a tool's test() function
bob tools test play
bob tools test summarise

# Quick schema inspection
python scripts/tools/tool_loader.py --info summarise
```

---

## Anti-patterns

| Anti-pattern | Fix |
|---|---|
| Core logic only in `invoke.py`'s `main()` | Extract to a named function, import from tool.py |
| Logic copied into both `invoke.py` and `tool.py` | One function, two callers |
| New plugin tool not in `agent.tools` | Add to bob.psd1 — loader won't find it otherwise |
| Layer 2 capability placed in `scripts/tools/` | Use decision rule: does `bob <name>` exist? |
