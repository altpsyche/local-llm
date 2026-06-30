#!/usr/bin/env python3
"""Bob agent loop — LLM reasons about what tools to call, executes them, loops until done.

Called by bob.ps1 agent case and bob-agent.ps1 scheduler.
All config is read from data/config.json (written by Get-BobConfig in _models.ps1).
"""
import json
import re
import sys
from pathlib import Path
from types import SimpleNamespace

REPO = Path(__file__).parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO / "scripts" / "tools"))


def _parse_hermes_tool_calls(content: str) -> list | None:
    """Parse <tool_call> blocks from Hermes-format content.
    Handles both JSON-inside and XML-sub-element variants."""
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
            except json.JSONDecodeError:
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
                except json.JSONDecodeError:
                    pass
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


def _hermes_tool_system_addendum(tool_schemas: list) -> str:
    """Extra system prompt fragment for Hermes-format tool calling."""
    tools_json = json.dumps(
        [s["function"] for s in tool_schemas if s.get("type") == "function"], indent=2
    )
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
    return p.parse_args()


def truncate_history(messages: list, max_msgs: int) -> list:
    """Sliding window: keep system message + most recent N non-system messages."""
    system = [m for m in messages if m.get("role") == "system"]
    rest = [m for m in messages if m.get("role") != "system"]
    if len(messages) <= max_msgs:
        return messages
    keep = max_msgs - len(system)
    return system + rest[-keep:]


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


def run_agent(
    goal: str,
    config: dict,
    role: str = None,
    agency: str = None,
    exit_on_tools: set = None,
) -> tuple[str | None, bool]:
    from bob_core import check_litellm, get_llm_client
    from tool_loader import discover_tools

    # Resolve settings
    agent_cfg = config.get("agent", {})
    effective_role = role or config.get("routing", {}).get("agentRole", "chat")
    effective_agency = agency or agent_cfg.get("agency", "show")
    max_steps = int(agent_cfg.get("maxSteps", 10))
    max_hist = int(agent_cfg.get("maxHistoryMsgs", 40))

    enabled_raw = agent_cfg.get("tools", ["memory", "web", "git", "file"])
    if isinstance(enabled_raw, str):
        enabled = [t.strip() for t in enabled_raw.split(",") if t.strip()]
    else:
        enabled = list(enabled_raw)

    # Pre-flight check
    if not check_litellm(config):
        port = config.get("litellmPort", 8081)
        print(
            f"Error: LiteLLM proxy not reachable at localhost:{port}",
            file=sys.stderr,
        )
        print("Run: bob up", file=sys.stderr)
        sys.exit(1)

    # Load tools
    tool_schemas, dispatch, discovered_exit_voice = discover_tools(enabled, config)
    exit_on_tools = exit_on_tools if exit_on_tools is not None else discovered_exit_voice

    # Build initial messages
    system_prompt = config.get("persona", {}).get(
        "systemPrompt", "You are Bob, a helpful AI assistant."
    )
    tool_fmt = agent_cfg.get("toolFormat", "hermes").lower()
    hermes_mode = tool_fmt == "hermes"

    base_system = (
        system_prompt + _hermes_tool_system_addendum(tool_schemas)
        if hermes_mode and tool_schemas
        else system_prompt
    )
    messages = [
        {"role": "system", "content": base_system},
        {"role": "user", "content": goal},
    ]

    client = get_llm_client(config)
    exit_on_tools = exit_on_tools or set()
    exit_requested = False

    for step in range(max_steps):
        messages = truncate_history(messages, max_hist)

        resp = client.chat.completions.create(
            model=effective_role,
            messages=messages,
            tools=tool_schemas if tool_schemas and not hermes_mode else None,
            stream=False,
        )
        msg = resp.choices[0].message
        content = msg.content or ""

        # Resolve tool calls — OpenAI format OR Hermes XML
        tool_calls = msg.tool_calls
        if not tool_calls and "<tool_call>" in content:
            tool_calls = _parse_hermes_tool_calls(content)

        # No tool calls — we're done
        if not tool_calls:
            final = _strip_tool_calls(content) if hermes_mode else content
            print(final)
            return final, exit_requested

        # Show tool calls to user
        if effective_agency != "silent":
            for tc in tool_calls:
                preview = tc.function.arguments[:120].replace("\n", " ")
                print(
                    f"\033[36m  → {tc.function.name}({preview})\033[0m",
                    file=sys.stderr,
                )

        # Confirm if needed
        if effective_agency == "confirm":
            try:
                ok = input("Execute tool calls? [y/N] ").strip().lower()
            except (EOFError, KeyboardInterrupt):
                ok = "n"
            if ok != "y":
                print("Aborted.")
                return None

        if hermes_mode:
            # Hermes conversation format: assistant content + user tool_response block
            messages.append({"role": "assistant", "content": content})
            tool_results = []
            for tc in tool_calls:
                if tc.function.name in exit_on_tools:
                    exit_requested = True
                fn = dispatch.get(tc.function.name)
                if fn is None:
                    result = f"Unknown tool: {tc.function.name}"
                else:
                    try:
                        result = str(fn(**json.loads(tc.function.arguments)))[:4000]
                    except json.JSONDecodeError as e:
                        result = f"Bad arguments JSON for {tc.function.name}: {e}"
                    except Exception as e:
                        result = f"Tool error ({tc.function.name}): {e}"
                if effective_agency != "silent":
                    preview = result[:100] + ("..." if len(result) > 100 else "")
                    print(f"\033[90m    {preview}\033[0m", file=sys.stderr)
                tool_results.append(
                    f'<tool_response>{{"name": "{tc.function.name}", "content": {json.dumps(result)}}}</tool_response>'
                )
            messages.append({"role": "user", "content": "\n".join(tool_results)})
        else:
            # OpenAI format
            messages.append(build_assistant_message(msg))
            for tc in tool_calls:
                if tc.function.name in exit_on_tools:
                    exit_requested = True
                fn = dispatch.get(tc.function.name)
                if fn is None:
                    result = f"Unknown tool: {tc.function.name}"
                else:
                    try:
                        result = str(fn(**json.loads(tc.function.arguments)))[:4000]
                    except json.JSONDecodeError as e:
                        result = f"Bad arguments JSON for {tc.function.name}: {e}"
                    except Exception as e:
                        result = f"Tool error ({tc.function.name}): {e}"
                if effective_agency != "silent":
                    preview = result[:100] + ("..." if len(result) > 100 else "")
                    print(f"\033[90m    {preview}\033[0m", file=sys.stderr)
                messages.append(build_tool_message(tc, result))

    print(
        f"Agent stopped after {max_steps} steps without a final answer.",
        file=sys.stderr,
    )
    return None, exit_requested


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
    )

    if args.notify and result:
        logs_dir = REPO / "logs"
        logs_dir.mkdir(exist_ok=True)
        (logs_dir / ".last-agent-result.txt").write_text(
            result[: config.get("agent", {}).get("maxResultChars", 500)],
            encoding="utf-8",
        )

    if exit_requested:
        sys.exit(42)


if __name__ == "__main__":
    main()
