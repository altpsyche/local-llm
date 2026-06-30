"""Auto-discover and load Bob tool modules.

System tools live in scripts/tools/<name>.py.
User tools live in plugins/<name>/tool.py.

Each tool file must export:
  TOOL_DEFS  list[dict]         OpenAI function-calling schemas
  DISPATCH   dict[str,callable] name -> function
  configure(config: dict)       called once at startup with full config

Optionally:
  test() -> str   called by `bob tools test <name>`
"""
import importlib.util
import sys
from pathlib import Path

REPO = Path(__file__).parent.parent.parent


def _load_module(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(f"bob_tool_{name}", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def discover_tools(enabled_names: list, config: dict) -> tuple[list, dict, set]:
    """Load and configure all enabled tool modules. Returns (tool_schemas, dispatch, exit_voice_tools).

    exit_voice_tools: names of tool functions whose modules declare EXIT_VOICE = True.
    When any of these fire in the voice agent loop, the loop should stop listening.
    To declare a tool as voice-exiting, add EXIT_VOICE = True to its module.
    """
    enabled_set = set(enabled_names)
    search = [
        ("system", REPO / "scripts" / "tools"),
        ("plugin", REPO / "plugins"),
    ]
    all_defs: list = []
    dispatch: dict = {}
    exit_voice_tools: set = set()

    for kind, base_dir in search:
        if not base_dir.exists():
            continue
        if kind == "system":
            candidates = [
                (f.stem, f)
                for f in sorted(base_dir.glob("*.py"))
                if f.stem in enabled_set and f.stem != "tool_loader"
            ]
        else:
            candidates = [
                (d.name, d / "tool.py")
                for d in sorted(base_dir.iterdir())
                if d.is_dir() and d.name in enabled_set and (d / "tool.py").exists()
            ]

        for tool_name, path in candidates:
            if not path.exists():
                continue
            try:
                mod = _load_module(tool_name, path)
                mod.configure(config)
                tool_defs = getattr(mod, "TOOL_DEFS", [])
                all_defs.extend(tool_defs)
                dispatch.update(getattr(mod, "DISPATCH", {}))
                if getattr(mod, "EXIT_VOICE", False):
                    for td in tool_defs:
                        name = td.get("function", {}).get("name")
                        if name:
                            exit_voice_tools.add(name)
            except Exception as e:
                print(f"[warn] failed to load tool '{tool_name}': {e}", file=sys.stderr)

    return all_defs, dispatch, exit_voice_tools


def _iter_all_tools():
    """Yield (name, kind, path) for every discoverable tool file."""
    for f in sorted((REPO / "scripts" / "tools").glob("*.py")):
        if f.stem != "tool_loader":
            yield f.stem, "system", f
    plugins_dir = REPO / "plugins"
    if plugins_dir.exists():
        for d in sorted(plugins_dir.iterdir()):
            if d.is_dir() and (d / "tool.py").exists():
                yield d.name, "plugin", d / "tool.py"


if __name__ == "__main__":
    import argparse
    import json

    parser = argparse.ArgumentParser(description="Bob tool loader CLI")
    parser.add_argument("--list", action="store_true", help="List all available tools")
    parser.add_argument("--test", metavar="NAME", help="Run a tool's test() function")
    parser.add_argument("--info", metavar="NAME", help="Show tool schema")
    parser.add_argument("--enabled", default="", help="Comma-separated enabled tools (for --list)")
    args = parser.parse_args()

    # Load config for configure() calls
    _cfg: dict = {}
    try:
        sys.path.insert(0, str(REPO / "scripts"))
        from bob_core import load_config
        _cfg = load_config()
    except Exception:
        pass

    enabled_list = [t.strip() for t in args.enabled.split(",") if t.strip()]

    if args.list:
        enabled_set = set(enabled_list) if enabled_list else None
        print(f"{'Name':<20} {'Kind':<8} {'Status':<10} Description")
        print("-" * 70)
        for name, kind, path in _iter_all_tools():
            status = "enabled" if (enabled_set is None or name in enabled_set) else "disabled"
            try:
                mod = _load_module(name, path)
                first_desc = ""
                defs = getattr(mod, "TOOL_DEFS", [])
                if defs:
                    first_desc = defs[0].get("function", {}).get("description", "")[:40]
            except Exception as e:
                first_desc = f"(load error: {e})"
            print(f"{name:<20} {kind:<8} {status:<10} {first_desc}")

    elif args.test:
        name = args.test
        found = False
        for tname, kind, path in _iter_all_tools():
            if tname == name:
                found = True
                mod = _load_module(name, path)
                mod.configure(_cfg)
                if hasattr(mod, "test"):
                    result = mod.test()
                    print(result)
                else:
                    print(f"Tool '{name}' has no test() function.")
                break
        if not found:
            print(f"Tool '{name}' not found.")
            sys.exit(1)

    elif args.info:
        name = args.info
        found = False
        for tname, kind, path in _iter_all_tools():
            if tname == name:
                found = True
                mod = _load_module(name, path)
                defs = getattr(mod, "TOOL_DEFS", [])
                print(json.dumps(defs, indent=2))
                break
        if not found:
            print(f"Tool '{name}' not found.")
            sys.exit(1)
    else:
        parser.print_help()
