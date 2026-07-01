#!/usr/bin/env python3
"""Bob agent loop — LLM reasons about what tools to call, executes them, loops until done.

Called by bob.ps1 agent case and bob-agent.ps1 scheduler.
All config is read from data/config.json (written by Get-BobConfig in _models.ps1).
"""
import hashlib
import json
import logging
import os
import re
import signal
import sys
import threading
import uuid
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO / "scripts" / "tools"))


def _estimate_tokens(text: str) -> int:
    """Rough token estimate (~4 chars/token for English + JSON). No tokenizer dependency —
    good enough for budgeting message history and tool results (M7)."""
    if not text:
        return 0
    return (len(text) + 3) // 4


def _message_tokens(m: dict) -> int:
    """Estimated token cost of a single chat message, including tool-call payloads."""
    content = m.get("content") or ""
    if not isinstance(content, str):
        content = json.dumps(content)
    total = _estimate_tokens(content) + 4  # per-message role/format overhead
    for tc in (m.get("tool_calls") or []):
        total += _estimate_tokens(json.dumps(tc))
    return total


def _is_transient(e) -> bool:
    """True for LLM errors worth exactly one retry: connection / timeout / 5xx / 429."""
    if type(e).__name__ in (
        "APIConnectionError", "APITimeoutError", "InternalServerError",
        "RateLimitError", "ConnectionError", "Timeout", "ReadTimeout",
    ):
        return True
    return getattr(e, "status_code", None) in (429, 500, 502, 503, 504)


def _parse_hermes_tool_calls(content: str) -> list | None:
    """Parse <tool_call> blocks from Hermes-format content.
    Handles both JSON-inside and XML-sub-element variants.
    Malformed JSON blocks are returned as __parse_error__ calls so the LLM
    can see the failure and self-correct, rather than being silently dropped.
    """
    blocks = re.findall(r"<tool_call>(.*?)</tool_call>", content, re.DOTALL)
    if not blocks:
        return None
    calls = []
    for i, block in enumerate(blocks):
        block = block.strip()
        if block.startswith("{"):
            try:
                d = json.loads(block)
                name = d.get("name", "")
                args = d.get("arguments", {})
            except json.JSONDecodeError as parse_err:
                print(
                    f"[warn] malformed tool call JSON in block {i}: {parse_err}",
                    file=sys.stderr,
                )
                calls.append(
                    SimpleNamespace(
                        id=f"hermes_err_{i}",
                        function=SimpleNamespace(
                            name="__parse_error__",
                            arguments=json.dumps(
                                {"error": str(parse_err), "raw": block[:200]}
                            ),
                        ),
                    )
                )
                continue
        else:
            name_m = re.search(r"<name>(.*?)</name>", block, re.DOTALL)
            if not name_m:
                continue
            name = name_m.group(1).strip()
            args_m = re.search(r"<arguments>(.*?)</arguments>", block, re.DOTALL)
            args = {}
            if args_m:
                try:
                    args = json.loads(args_m.group(1).strip())
                except json.JSONDecodeError as parse_err:
                    # M9 — mirror the JSON path: surface malformed <arguments> as a parse-error
                    # call so the LLM can self-correct, instead of silently dropping the args.
                    print(
                        f"[warn] malformed <arguments> JSON in block {i}: {parse_err}",
                        file=sys.stderr,
                    )
                    calls.append(
                        SimpleNamespace(
                            id=f"hermes_err_{i}",
                            function=SimpleNamespace(
                                name="__parse_error__",
                                arguments=json.dumps(
                                    {"error": str(parse_err), "raw": block[:200]}
                                ),
                            ),
                        )
                    )
                    continue
        if not name:
            continue
        calls.append(
            SimpleNamespace(
                id=f"hermes_{i}",
                function=SimpleNamespace(
                    name=name,
                    arguments=json.dumps(args),
                ),
            )
        )
    return calls or None


def _strip_tool_calls(content: str) -> str:
    return re.sub(r"<tool_call>.*?</tool_call>", "", content, flags=re.DOTALL).strip()


def _compact_schema(fn: dict) -> dict:
    """Strip verbose descriptions from a function schema, keeping the callable contract
    (name, param names, types/enums, required). Used when the tool count is high so the
    fixed per-turn prompt overhead doesn't grow linearly with the number of tools (M7)."""
    params = fn.get("parameters", {}) or {}
    props = {}
    for pname, pspec in (params.get("properties", {}) or {}).items():
        props[pname] = {k: v for k, v in pspec.items() if k in ("type", "enum")}
    return {
        "name": fn.get("name", ""),
        "description": (fn.get("description", "") or "")[:80],
        "parameters": {
            "type": params.get("type", "object"),
            "properties": props,
            "required": params.get("required", []),
        },
    }


def _hermes_tool_system_addendum(tool_schemas: list, compact_after: int = 12) -> str:
    """Extra system prompt fragment for Hermes-format tool calling.

    Past `compact_after` tools, emit compact schemas (drop param descriptions, no indent) so
    a large plugin set doesn't silently eat a small local context window (M7)."""
    fns = [s["function"] for s in tool_schemas if s.get("type") == "function"]
    if compact_after and len(fns) > compact_after:
        tools_json = json.dumps([_compact_schema(f) for f in fns])
    else:
        tools_json = json.dumps(fns, indent=2)
    return (
        "\n\nYou have access to the following tools:\n"
        f"<tools>\n{tools_json}\n</tools>\n\n"
        "For each function call, output JSON wrapped in <tool_call></tool_call> tags:\n"
        '<tool_call>{"name": "<function-name>", "arguments": {<args>}}</tool_call>\n'
        "Call tools as needed. When you have the final answer, respond normally without tool_call tags."
    )


def parse_args():
    import argparse

    p = argparse.ArgumentParser(description="Bob agent loop")
    p.add_argument("goal", nargs="+", help="Goal or task for the agent")
    p.add_argument(
        "--role", default=None, help="Model role override (default: routing.agentRole)"
    )
    p.add_argument(
        "--agency",
        default=None,
        choices=["silent", "show", "confirm"],
        help="Override agent.agency from config",
    )
    p.add_argument(
        "--notify", action="store_true", help="Write result to logs for toast notification"
    )
    p.add_argument("--notify-title", default="Bob", help="Toast notification title")
    p.add_argument("--exit-on-tool", default=None,
                   help="Comma-separated tool names: exit with code 42 after any of them fire")
    p.add_argument("--stream", action="store_true",
                   help="Stream the final answer token-by-token to stdout (M15)")
    return p.parse_args()


def truncate_history(messages: list, max_msgs: int, max_tokens: int = 0) -> list:
    """Sliding window that keeps the system message(s) + most recent turns.

    Trims by message count first (max_msgs), then by an optional token budget (max_tokens,
    M7): drop oldest non-system messages until the estimated total fits. The system
    message is always kept. An orphaned leading tool-response (whose assistant call got
    trimmed) is dropped so the remaining sequence stays valid for the OpenAI tool format."""
    system = [m for m in messages if m.get("role") == "system"]
    rest = [m for m in messages if m.get("role") != "system"]

    # 1. Message-count window.
    if len(system) + len(rest) > max_msgs:
        keep = max(0, max_msgs - len(system))
        rest = rest[-keep:]

    # 2. Token-budget window — keep as many recent messages as fit under the budget.
    if max_tokens:
        budget = max_tokens - sum(_message_tokens(m) for m in system)
        kept: list = []
        running = 0
        for m in reversed(rest):
            t = _message_tokens(m)
            if kept and running + t > budget:
                break
            running += t
            kept.append(m)
        rest = list(reversed(kept))

    # 3. Don't leave an orphaned tool response at the front.
    while rest and rest[0].get("role") == "tool":
        rest.pop(0)

    return system + rest


def build_tool_message(tc, result: str) -> dict:
    return {
        "role": "tool",
        "tool_call_id": tc.id,
        "content": result,
    }


def build_assistant_message(msg) -> dict:
    return {
        "role": "assistant",
        "content": msg.content,
        "tool_calls": [
            {
                "id": tc.id,
                "type": "function",
                "function": {
                    "name": tc.function.name,
                    "arguments": tc.function.arguments,
                },
            }
            for tc in (msg.tool_calls or [])
        ],
    }


# --- M18: registry cache, structured logging, graceful interrupt -------------

_REGISTRY_CACHE: dict = {}


def _get_or_build_registry(config: dict, disabled: set):
    """Return a cached ToolRegistry for this (config, disabled) combo, building once.

    Keyed by a hash of the resolved config + disabled set so repeated in-process run_agent
    calls skip re-importing/-configuring every tool (M18). Per-process only: the CLI/voice
    paths spawn a fresh process per call, and the server builds once at startup and passes
    the registry in — so this mainly helps anything that calls run_agent() repeatedly in one
    process."""
    from tool_registry import ToolRegistry

    key = hashlib.sha256(
        (json.dumps(config, sort_keys=True, default=str) + "|" + ",".join(sorted(disabled))).encode()
    ).hexdigest()
    reg = _REGISTRY_CACHE.get(key)
    if reg is None:
        reg = ToolRegistry.build(config, disabled)
        _REGISTRY_CACHE[key] = reg
    return reg


def _agent_logger(config: dict):
    """A 'bob.agent' logger writing structured lines to logs/bob-agent.log (per-run id lives
    in each message). Human-facing stderr previews are kept separately for interactive use (M18)."""
    log = logging.getLogger("bob.agent")
    if not log.handlers:
        log.setLevel(logging.INFO)
        rel = config.get("agent", {}).get("logFile", "logs/bob-agent.log").replace("\\", "/")
        path = REPO / rel
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            h = logging.FileHandler(path, encoding="utf-8")
            h.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
            log.addHandler(h)
            log.propagate = False
        except OSError:
            log.addHandler(logging.NullHandler())
    return log


def _install_interrupt_handler(state: dict):
    """Install a SIGINT handler that flips state['interrupted'] instead of raising, so the loop
    finishes the current step and exits cleanly rather than dying mid-write (M18). No-op off the
    main thread (a server request), where signal.signal is illegal. Returns the previous handler."""
    if threading.current_thread() is not threading.main_thread():
        return None
    try:
        prev = signal.getsignal(signal.SIGINT)

        def _handler(signum, frame):
            state["interrupted"] = True
            print("\n[bob] interrupt — finishing current step, then stopping...", file=sys.stderr)

        signal.signal(signal.SIGINT, _handler)
        return prev
    except (ValueError, OSError):
        return None


def _restore_interrupt_handler(prev):
    if prev is not None and threading.current_thread() is threading.main_thread():
        try:
            signal.signal(signal.SIGINT, prev)
        except (ValueError, OSError):
            pass


# --- M15: unified completion call with optional token streaming --------------

def _consume_stream(stream_resp):
    """Iterate a streaming chat completion. Yields ('token', text) for content deltas until a
    '<tool_call>' marker appears (after which tool markup is suppressed from the stream), and
    returns a normalized SimpleNamespace(content, tool_calls) — the same shape the loop expects
    for the non-streaming path. OpenAI-format tool_calls are reassembled from indexed deltas."""
    content_parts: list = []
    tool_acc: dict = {}
    suppressing = False
    for chunk in stream_resp:
        if not chunk.choices:
            continue
        delta = chunk.choices[0].delta
        piece = getattr(delta, "content", None)
        if piece:
            content_parts.append(piece)
            if not suppressing and "<tool_call>" in "".join(content_parts):
                suppressing = True
            if not suppressing:
                yield ("token", piece)
        for tcd in (getattr(delta, "tool_calls", None) or []):
            slot = tool_acc.setdefault(tcd.index, {"id": None, "name": "", "args": ""})
            if tcd.id:
                slot["id"] = tcd.id
            if tcd.function and tcd.function.name:
                slot["name"] += tcd.function.name
            if tcd.function and tcd.function.arguments:
                slot["args"] += tcd.function.arguments
    content = "".join(content_parts)
    tool_calls = None
    if tool_acc:
        tool_calls = [
            SimpleNamespace(
                id=(s["id"] or f"call_{i}"),
                function=SimpleNamespace(name=s["name"], arguments=s["args"]),
            )
            for i, s in sorted(tool_acc.items())
        ]
    return SimpleNamespace(content=content, tool_calls=tool_calls)


def _create_once(client, model, messages, tools, timeout):
    """Non-streaming completion → SimpleNamespace(content, tool_calls) or None on empty choices."""
    resp = client.chat.completions.create(
        model=model, messages=messages, tools=tools, stream=False, timeout=timeout
    )
    if not resp.choices:
        return None
    m = resp.choices[0].message
    return SimpleNamespace(content=m.content or "", tool_calls=m.tool_calls)


def run_agent_events(
    goal: str,
    config: dict,
    role: str = None,
    agency: str = None,
    exit_on_tools: set = None,
    registry=None,
    stream: bool = False,
    history: list = None,
):
    """Generator core of the agent loop (M15). Yields event dicts:
        {"type": "token",       "text": str}                       # final-answer deltas (stream=True)
        {"type": "tool_call",   "name": str, "arguments": str}
        {"type": "tool_result", "name": str, "result": str}
        {"type": "final",       "result": str|None, "exit_requested": bool, "reason": str}
        {"type": "error",       "message": str}
    A terminal 'final' or 'error' is always the last event. run_agent() is the blocking
    wrapper used by the CLI; the server's SSE endpoint consumes these events directly."""
    from bob_core import _port, check_litellm, get_llm_client, memory_recall

    agent_cfg = config.get("agent", {})
    effective_role = role or config.get("routing", {}).get("agentRole", "chat")
    effective_agency = agency or agent_cfg.get("agency", "show")
    max_steps = int(agent_cfg.get("maxSteps", 10))
    max_hist = int(agent_cfg.get("maxHistoryMsgs", 40))
    # M7 — token-aware context: cap history to a token budget (0 = count-only) and shrink
    # the injected tool schemas once the tool count crosses compactSchemasAfter.
    max_context_tokens = int(agent_cfg.get("maxContextTokens", 6000))
    compact_after = int(agent_cfg.get("compactSchemasAfter", 12))
    # Client-side timeout must be >= the proxy's request_timeout (600s): thinking models
    # (planner/R1) can run >2 min before first output. A low value would cut them off.
    request_timeout = int(agent_cfg.get("requestTimeout", 600))

    rid = uuid.uuid4().hex[:8]
    log = _agent_logger(config)

    # Build or reuse a cached registry (M18).
    if registry is None:
        disabled_raw = agent_cfg.get("disabledTools", [])
        if isinstance(disabled_raw, str):
            disabled = {t.strip() for t in disabled_raw.split(",") if t.strip()}
        else:
            disabled = set(disabled_raw)
        registry = _get_or_build_registry(config, disabled)

    tool_schemas = registry.tool_schemas
    exit_on_tools = exit_on_tools if exit_on_tools is not None else registry.exit_voice_tools
    exit_on_tools = exit_on_tools or set()

    # Pre-flight check
    if not check_litellm(config):
        port = _port(config, "litellmPort")
        msg = f"LiteLLM proxy not reachable at localhost:{port}. Run: bob up"
        log.error(f"[{rid}] preflight failed: {msg}")
        yield {"type": "error", "message": msg}
        return

    system_prompt = config.get("persona", {}).get(
        "systemPrompt", "You are Bob, a helpful AI assistant."
    )

    # M14 — inject relevant memories into the agent's system context (gated on memory.enabled).
    # Fulfils the persona's "memories provided in context" claim for the agent path. Best-effort:
    # a memory/embed failure is logged and skipped, never fatal to the run.
    mem_cfg = config.get("memory", {})
    if mem_cfg.get("enabled"):
        try:
            recalled = memory_recall(goal, k=int(mem_cfg.get("recallK", 5)), config=config)
            if recalled and recalled.strip() and recalled != "(no results)":
                system_prompt += "\n\nRelevant memories from past sessions:\n" + recalled
                log.info(f"[{rid}] injected memories ({len(recalled)}c)")
        except Exception as e:
            log.warning(f"[{rid}] memory recall skipped: {e}")
            print(f"[warn] memory recall skipped: {e}", file=sys.stderr)

    tool_fmt = agent_cfg.get("toolFormat", "hermes").lower()
    hermes_mode = tool_fmt == "hermes"
    base_system = (
        system_prompt + _hermes_tool_system_addendum(tool_schemas, compact_after)
        if hermes_mode and tool_schemas
        else system_prompt
    )
    # Prior session turns (M12) are seeded between the system prompt and the new goal;
    # truncate_history keeps the whole thing within the token budget.
    messages = [{"role": "system", "content": base_system}]
    if history:
        messages.extend(history)
    messages.append({"role": "user", "content": goal})

    client = get_llm_client(config)
    exit_requested = False
    last_content = None

    log.info(
        f"[{rid}] start role={effective_role} agency={effective_agency} "
        f"tools={len(tool_schemas)} stream={stream} goal={goal[:200]!r}"
    )

    run_state = {"interrupted": False}
    prev_sigint = _install_interrupt_handler(run_state)
    try:
        for step in range(max_steps):
            if run_state["interrupted"]:
                log.info(f"[{rid}] interrupted before step {step + 1}")
                yield {"type": "final", "result": last_content,
                       "exit_requested": exit_requested, "reason": "interrupted"}
                return

            messages = truncate_history(messages, max_hist, max_context_tokens)
            tools = tool_schemas if tool_schemas and not hermes_mode else None

            msg = None
            if stream:
                # One attempt when streaming — retrying mid-stream would re-emit tokens.
                try:
                    gen = _consume_stream(
                        client.chat.completions.create(
                            model=effective_role, messages=messages, tools=tools,
                            stream=True, timeout=request_timeout,
                        )
                    )
                    while True:
                        try:
                            _kind, text = next(gen)
                            yield {"type": "token", "text": text}
                        except StopIteration as stop:
                            msg = stop.value
                            break
                except Exception as e:
                    log.error(f"[{rid}] LLM stream error step {step + 1}: {e}")
                    yield {"type": "error", "message": f"LLM error at step {step + 1}: {e}"}
                    return
            else:
                for attempt in range(2):
                    try:
                        msg = _create_once(client, effective_role, messages, tools, request_timeout)
                        break
                    except Exception as e:
                        if attempt == 0 and _is_transient(e):
                            log.warning(f"[{rid}] transient LLM error step {step + 1}: {e}")
                            print(f"[retry] transient LLM error at step {step + 1}: {e}", file=sys.stderr)
                            continue
                        log.error(f"[{rid}] LLM error step {step + 1}: {e}")
                        yield {"type": "error", "message": f"LLM error at step {step + 1}: {e}"}
                        return

            if msg is None:
                log.error(f"[{rid}] no choices step {step + 1}")
                yield {"type": "error", "message": f"LLM returned no choices at step {step + 1}"}
                return

            content = msg.content or ""
            last_content = content
            tool_calls = msg.tool_calls
            if not tool_calls and "<tool_call>" in content:
                tool_calls = _parse_hermes_tool_calls(content)

            log.info(f"[{rid}] step {step + 1} content_len={len(content)} tool_calls={len(tool_calls or [])}")

            # No tool calls — final answer.
            if not tool_calls:
                final = _strip_tool_calls(content) if hermes_mode else content
                log.info(f"[{rid}] final len={len(final)}")
                yield {"type": "final", "result": final,
                       "exit_requested": exit_requested, "reason": "answer"}
                return

            for tc in tool_calls:
                yield {"type": "tool_call", "name": tc.function.name, "arguments": tc.function.arguments}

            # Confirmation (interactive only; server passes silent/show agency).
            if effective_agency == "confirm":
                try:
                    ok = input("Execute tool calls? [y/N] ").strip().lower()
                except (EOFError, KeyboardInterrupt):
                    ok = "n"
                if ok != "y":
                    log.info(f"[{rid}] aborted at confirm")
                    yield {"type": "final", "result": None,
                           "exit_requested": exit_requested, "reason": "aborted"}
                    return

            if hermes_mode:
                messages.append({"role": "assistant", "content": content})
                tool_results = []
                for tc in tool_calls:
                    if tc.function.name in exit_on_tools:
                        exit_requested = True
                    result = registry.dispatch_call(tc.function.name, tc.function.arguments)
                    log.info(f"[{rid}] tool {tc.function.name} -> {len(result)}c")
                    yield {"type": "tool_result", "name": tc.function.name, "result": result}
                    tool_results.append(
                        f'<tool_response>{{"name": "{tc.function.name}", "content": {json.dumps(result)}}}</tool_response>'
                    )
                messages.append({"role": "user", "content": "\n".join(tool_results)})
            else:
                messages.append(build_assistant_message(msg))
                for tc in tool_calls:
                    if tc.function.name in exit_on_tools:
                        exit_requested = True
                    result = registry.dispatch_call(tc.function.name, tc.function.arguments)
                    log.info(f"[{rid}] tool {tc.function.name} -> {len(result)}c")
                    yield {"type": "tool_result", "name": tc.function.name, "result": result}
                    messages.append(build_tool_message(tc, result))

        log.warning(f"[{rid}] stopped after {max_steps} steps without a final answer")
        print(f"Agent stopped after {max_steps} steps without a final answer.", file=sys.stderr)
        yield {"type": "final", "result": None, "exit_requested": exit_requested, "reason": "max_steps"}
    finally:
        _restore_interrupt_handler(prev_sigint)


def run_agent(
    goal: str,
    config: dict,
    role: str = None,
    agency: str = None,
    exit_on_tools: set = None,
    registry=None,
    stream: bool = False,
    history: list = None,
) -> tuple[str | None, bool]:
    """Blocking wrapper over run_agent_events for the CLI: prints tool previews to stderr,
    streams/echoes the final answer to stdout, and returns (result, exit_requested)."""
    effective_agency = agency or config.get("agent", {}).get("agency", "show")
    result = None
    exit_requested = False
    streamed_any = False
    for ev in run_agent_events(
        goal, config, role=role, agency=agency,
        exit_on_tools=exit_on_tools, registry=registry, stream=stream, history=history,
    ):
        t = ev["type"]
        if t == "token":
            sys.stdout.write(ev["text"])
            sys.stdout.flush()
            streamed_any = True
        elif t == "tool_call":
            if effective_agency != "silent":
                preview = ev["arguments"][:120].replace("\n", " ")
                print(f"\033[36m  → {ev['name']}({preview})\033[0m", file=sys.stderr)
        elif t == "tool_result":
            if effective_agency != "silent":
                preview = ev["result"][:100] + ("..." if len(ev["result"]) > 100 else "")
                print(f"\033[90m    {preview}\033[0m", file=sys.stderr)
        elif t == "final":
            result = ev["result"]
            exit_requested = ev.get("exit_requested", False)
            if streamed_any:
                print()  # newline after streamed tokens
            elif result is not None:
                print(result)
        elif t == "error":
            print(ev["message"], file=sys.stderr)
            return None, exit_requested
    return result, exit_requested


def main():
    args = parse_args()
    from bob_core import load_config

    try:
        config = load_config()
    except FileNotFoundError as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

    goal = " ".join(args.goal)
    exit_on_tools = set(t.strip() for t in args.exit_on_tool.split(",") if t.strip()) if args.exit_on_tool else None
    result, exit_requested = run_agent(
        goal,
        config,
        role=args.role,
        agency=args.agency,
        exit_on_tools=exit_on_tools,
        stream=args.stream,
    )

    if args.notify and result:
        logs_dir = REPO / "logs"
        logs_dir.mkdir(exist_ok=True)
        # M16 — temp + atomic replace (same pattern as config.json) so a concurrent toast
        # reader never observes a half-written result file.
        dst = logs_dir / ".last-agent-result.txt"
        tmp = logs_dir / f".last-agent-result.{os.getpid()}.tmp"
        tmp.write_text(
            result[: config.get("agent", {}).get("maxResultChars", 500)],
            encoding="utf-8",
        )
        os.replace(tmp, dst)

    if exit_requested:
        sys.exit(42)


if __name__ == "__main__":
    main()
