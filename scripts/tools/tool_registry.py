"""Bob ToolRegistry — discover, validate, and serve tool definitions.

Replaces the loose discover_tools() pattern. Build once at startup; pass the
registry to every run_agent() call so tool modules aren't re-imported per request.

Lifecycle:
  Phase 1  Import    — load module from disk; distinct error from Phase 3
  Phase 2  Contract  — TOOL_DEFS, DISPATCH, configure() present and consistent
  Phase 3  Configure — call configure(config) with full runtime config

Usage:
    registry = ToolRegistry.build(config, disabled_names={"play"})
    # pass to run_agent(goal, config, registry=registry)
    result = registry.dispatch_call("memory_recall", '{"query": "todo list"}')
"""
import importlib.util
import json
import sys
from pathlib import Path

REPO = Path(__file__).parent.parent.parent

_SKIP_STEMS = frozenset({"tool_loader", "tool_registry"})


class ToolRegistry:
    def __init__(self):
        self.tool_schemas: list = []
        self.dispatch: dict = {}
        self.exit_voice_tools: set = set()
        # (tool_name, phase, message) — phase: "import" | "contract" | "configure"
        self.errors: list[tuple[str, str, str]] = []
        self._loaded_names: set = set()
        # M7 — per-result cap (chars). Derived from agent.maxToolResultTokens in build().
        self.max_result_chars: int = 4000

    # ------------------------------------------------------------------
    # Discovery — single source shared by build() and the loader CLI (M16)
    # ------------------------------------------------------------------

    @staticmethod
    def iter_all_tools():
        """Yield (name, kind, path) for every discoverable tool file (system + plugin),
        unfiltered. Discovery lives only here so build() and tool_loader's CLI agree."""
        tools_dir = REPO / "scripts" / "tools"
        for f in sorted(tools_dir.glob("*.py")):
            if f.stem not in _SKIP_STEMS:
                yield f.stem, "system", f
        plugins_dir = REPO / "plugins"
        if plugins_dir.exists():
            for d in sorted(plugins_dir.iterdir()):
                if d.is_dir() and (d / "tool.py").exists():
                    yield d.name, "plugin", d / "tool.py"

    # ------------------------------------------------------------------
    # Factory
    # ------------------------------------------------------------------

    @classmethod
    def build(cls, config: dict, disabled_names: set = None) -> "ToolRegistry":
        """Discover all tools, validate the contract, configure them.

        disabled_names: tool directory/stem names to skip entirely.
        """
        registry = cls()
        disabled = disabled_names or set()
        # M7 — token-aware per-result cap (approx 4 chars/token) so one large tool output
        # can't blow the context budget. maxToolResultTokens defaults to keep the prior 4000-char cap.
        registry.max_result_chars = int(config.get("agent", {}).get("maxToolResultTokens", 1000)) * 4

        all_tools = list(cls.iter_all_tools())

        # Warn about disabled names that match no discoverable tool (likely a typo).
        all_discoverable = {name for name, _, _ in all_tools}
        for name in sorted(disabled - all_discoverable):
            print(
                f"[warn] '{name}' in disabledTools but no matching tool file found",
                file=sys.stderr,
            )

        # Load each non-disabled tool.
        for tool_name, _kind, path in all_tools:
            if tool_name in disabled:
                continue
            registry._load_one(tool_name, path, config)

        registry._print_startup_summary()
        return registry

    # ------------------------------------------------------------------
    # Internal loading phases
    # ------------------------------------------------------------------

    def _load_one(self, tool_name: str, path: Path, config: dict) -> None:
        # Phase 1: Import
        try:
            spec = importlib.util.spec_from_file_location(f"bob_tool_{tool_name}", path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception as e:
            self.errors.append((tool_name, "import", str(e)))
            print(f"[warn] tool '{tool_name}' failed to import: {e}", file=sys.stderr)
            return

        # Phase 2: Contract check
        tool_defs = getattr(mod, "TOOL_DEFS", None)
        mod_dispatch = getattr(mod, "DISPATCH", None)
        configure_fn = getattr(mod, "configure", None)

        if tool_defs is None:
            self.errors.append((tool_name, "contract", "missing TOOL_DEFS"))
            print(f"[warn] tool '{tool_name}' missing TOOL_DEFS", file=sys.stderr)
            return
        if mod_dispatch is None:
            self.errors.append((tool_name, "contract", "missing DISPATCH"))
            print(f"[warn] tool '{tool_name}' missing DISPATCH", file=sys.stderr)
            return
        if not callable(configure_fn):
            self.errors.append((tool_name, "contract", "missing configure()"))
            print(f"[warn] tool '{tool_name}' missing configure() function", file=sys.stderr)
            return

        # Cross-check TOOL_DEFS function names against DISPATCH keys.
        defs_names = {
            td.get("function", {}).get("name")
            for td in tool_defs
            if td.get("function", {}).get("name")
        }
        missing_in_dispatch = defs_names - set(mod_dispatch.keys())
        if missing_in_dispatch:
            # M9 — hard contract error: a TOOL_DEFS name with no DISPATCH entry would load and
            # then fail at call time with "Unknown tool". Fail loudly at load and skip the tool.
            self.errors.append(
                (tool_name, "contract",
                 f"TOOL_DEFS declares {missing_in_dispatch} with no matching DISPATCH key")
            )
            print(
                f"[warn] tool '{tool_name}': TOOL_DEFS declares {missing_in_dispatch}"
                f" but DISPATCH has no matching key — skipping tool (contract error)",
                file=sys.stderr,
            )
            return

        # Phase 3: Configure
        try:
            configure_fn(config)
        except Exception as e:
            self.errors.append((tool_name, "configure", str(e)))
            print(f"[warn] tool '{tool_name}' configure() failed: {e}", file=sys.stderr)
            return

        # All phases passed — register.
        self._loaded_names.add(tool_name)
        self.tool_schemas.extend(tool_defs)
        self.dispatch.update(mod_dispatch)

        if getattr(mod, "EXIT_VOICE", False):
            for td in tool_defs:
                fn_name = td.get("function", {}).get("name")
                if fn_name:
                    self.exit_voice_tools.add(fn_name)

    def _print_startup_summary(self) -> None:
        names = sorted(self._loaded_names)
        if names:
            print(f"[bob] tools: {' '.join(names)} ({len(names)})", file=sys.stderr)
        else:
            print("[bob] tools: none loaded", file=sys.stderr)
        if self.errors:
            print(
                f"[bob] {len(self.errors)} tool(s) had load errors — see warnings above",
                file=sys.stderr,
            )

    # ------------------------------------------------------------------
    # Runtime dispatch
    # ------------------------------------------------------------------

    def dispatch_call(self, tool_name: str, arguments_json: str) -> str:
        """Execute a named tool call. Always returns a string (the format agents expect).

        Handles the __parse_error__ pseudo-name injected by _parse_hermes_tool_calls
        when the LLM emits invalid JSON inside a <tool_call> block.
        """
        if tool_name == "__parse_error__":
            try:
                info = json.loads(arguments_json)
                return (
                    f"Your previous tool call contained malformed JSON "
                    f"({info.get('error', 'parse error')}). "
                    f"Please fix the JSON syntax and retry."
                )
            except Exception:
                return "Your previous tool call contained malformed JSON. Please retry with valid JSON."

        fn = self.dispatch.get(tool_name)
        if fn is None:
            return f"Unknown tool: {tool_name}"
        try:
            out = str(fn(**json.loads(arguments_json)))
            if len(out) > self.max_result_chars:
                out = out[: self.max_result_chars] + "\n[...truncated]"
            return out
        except json.JSONDecodeError as e:
            return f"Bad arguments JSON for {tool_name}: {e}"
        except Exception as e:
            return f"Tool error ({tool_name}): {e}"
