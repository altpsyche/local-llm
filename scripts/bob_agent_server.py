#!/usr/bin/env python3
"""Bob agent HTTP server — exposes the agent tool loop as a REST + SSE endpoint.

Start: bob agent serve  (loopback :8084 by default; set agent.serveHost = '0.0.0.0' to expose)

Auth (M5/M12): every endpoint requires  Authorization: Bearer <token>  where <token> is the
litellm key or any entry in agent.apiTokens.

Endpoints:
  POST /v1/agent/completions          {"goal","agency","role","session_id"} -> {"result","session_id","error"}
  POST /v1/agent/completions/stream   same body -> text/event-stream of {type,...} events (M15)
  POST /v1/sessions                   -> {"session_id"} (M12; optional body {"token_budget"})
  GET  /v1/sessions/{sid}             -> session (history, budget, spend)
  DELETE /v1/sessions/{sid}           -> {"deleted": bool}
  GET  /health                        -> tool counts (no auth)

Wire into n8n:
  URL: http://host.docker.internal:8084/v1/agent/completions
  Header: Authorization: Bearer <litellm key>
  Body: {"goal": "{{ $json.goal }}"}
"""
import json
import sys
from pathlib import Path
from typing import Optional

REPO = Path(__file__).parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO / "scripts" / "tools"))

from fastapi import FastAPI, Header, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

app = FastAPI(title="Bob Agent API", version="1.1")


class AgentRequest(BaseModel):
    goal: str
    agency: str = "silent"
    role: Optional[str] = None
    session_id: Optional[str] = None  # M12 — continue a persisted conversation


class AgentResponse(BaseModel):
    result: Optional[str]
    session_id: Optional[str] = None
    error: Optional[str] = None


class SessionCreate(BaseModel):
    token_budget: int = 0  # 0 = unlimited; else reject once tokens_spent reaches it


# ---------------------------------------------------------------------------
# Startup — build the tool registry + session store once, share across requests.
# ---------------------------------------------------------------------------

_config: dict = {}
_registry = None          # ToolRegistry | None
_sessions = None          # SessionStore | None
_accepted_tokens: set = set()  # M12 — litellm key + agent.apiTokens


@app.on_event("startup")
def _startup():
    global _config, _registry, _sessions, _accepted_tokens
    from bob_core import load_config
    from tool_registry import ToolRegistry
    from bob_session import SessionStore

    _config = load_config()
    agent = _config.get("agent", {})

    # Auth abstraction (M12): accept the litellm key plus any configured per-client tokens.
    _accepted_tokens = {_config.get("litellmKey", "sk-local")}
    _accepted_tokens.update(t for t in agent.get("apiTokens", []) if t)

    disabled_raw = agent.get("disabledTools", [])
    disabled = set(disabled_raw) if isinstance(disabled_raw, list) else {
        t.strip() for t in disabled_raw.split(",") if t.strip()
    }
    _registry = ToolRegistry.build(_config, disabled)

    session_db = REPO / agent.get("sessionDbPath", "data/sessions.db").replace("\\", "/")
    _sessions = SessionStore(session_db)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _require_auth(authorization: str) -> None:
    token = authorization[7:] if authorization.startswith("Bearer ") else ""
    if token not in _accepted_tokens:
        raise HTTPException(status_code=401, detail="Unauthorized")


def _session_max_tokens() -> int:
    return int(_config.get("agent", {}).get("maxSessionTokens", 0))


def _load_session_or_404(session_id: Optional[str]):
    """Return (session dict|None, history list). Raises 404 for an unknown id, 402 over budget."""
    if not session_id:
        return None, None
    session = _sessions.get(session_id) if _sessions else None
    if session is None:
        raise HTTPException(status_code=404, detail=f"Unknown session_id: {session_id}")
    if _sessions.over_budget(session_id):
        raise HTTPException(status_code=402, detail="Session token budget exhausted")
    return session, session["history"]


def _record_turn(session_id: Optional[str], goal: str, result: Optional[str]) -> None:
    if not session_id or _sessions is None:
        return
    from bob_loop import _estimate_tokens
    used = _estimate_tokens(goal) + _estimate_tokens(result or "")
    _sessions.append_turn(session_id, goal, result, tokens_used=used)


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.get("/health")
def health():
    loaded = len(_registry._loaded_names) if _registry else 0
    errors = len(_registry.errors) if _registry else 0
    return {"status": "ok", "tools_loaded": loaded, "tools_failed": errors}


@app.post("/v1/sessions")
def create_session(req: SessionCreate = SessionCreate(), authorization: str = Header(default="")):
    _require_auth(authorization)
    if _sessions is None:
        raise HTTPException(status_code=503, detail="Server not yet initialized")
    budget = req.token_budget or _session_max_tokens()
    session = _sessions.create(token_budget=budget)
    return {"session_id": session["id"], "token_budget": session["token_budget"]}


@app.get("/v1/sessions/{sid}")
def get_session(sid: str, authorization: str = Header(default="")):
    _require_auth(authorization)
    session = _sessions.get(sid) if _sessions else None
    if session is None:
        raise HTTPException(status_code=404, detail="Unknown session_id")
    return session


@app.delete("/v1/sessions/{sid}")
def delete_session(sid: str, authorization: str = Header(default="")):
    _require_auth(authorization)
    return {"deleted": bool(_sessions and _sessions.delete(sid))}


@app.post("/v1/agent/completions", response_model=AgentResponse)
def agent_completions(req: AgentRequest, authorization: str = Header(default="")):
    from bob_loop import run_agent

    _require_auth(authorization)
    if _registry is None:
        raise HTTPException(status_code=503, detail="Server not yet initialized")

    _, history = _load_session_or_404(req.session_id)
    try:
        result, _ = run_agent(
            req.goal, _config, role=req.role, agency=req.agency,
            registry=_registry, history=history,
        )
    except FileNotFoundError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

    _record_turn(req.session_id, req.goal, result)
    if result is None:
        raise HTTPException(
            status_code=422,
            detail="Agent reached max steps without producing a final answer",
        )
    return AgentResponse(result=result, session_id=req.session_id)


@app.post("/v1/agent/completions/stream")
def agent_completions_stream(req: AgentRequest, authorization: str = Header(default="")):
    """M15 — Server-Sent Events: stream tool_call / tool_result / token / final events as the
    agent works. Each SSE line is `data: {json}`; the terminal event has type 'final' or 'error'."""
    from bob_loop import run_agent_events

    _require_auth(authorization)
    if _registry is None:
        raise HTTPException(status_code=503, detail="Server not yet initialized")

    _, history = _load_session_or_404(req.session_id)

    def _sse():
        final_result = None
        try:
            for ev in run_agent_events(
                req.goal, _config, role=req.role, agency=req.agency,
                registry=_registry, stream=True, history=history,
            ):
                if ev["type"] == "final":
                    final_result = ev.get("result")
                    if req.session_id:
                        ev["session_id"] = req.session_id
                yield f"data: {json.dumps(ev)}\n\n"
        except Exception as e:  # never leak a raw traceback into the stream
            yield f"data: {json.dumps({'type': 'error', 'message': str(e)})}\n\n"
        finally:
            _record_turn(req.session_id, req.goal, final_result)

    return StreamingResponse(_sse(), media_type="text/event-stream")


if __name__ == "__main__":
    import uvicorn
    from bob_core import _port, load_config

    _agent = load_config().get("agent", {})
    # Default to loopback. Set agent.serveHost = '0.0.0.0' in bob.psd1 to expose on the LAN
    # (also harden web_fetch — see MODULE-M / M9 — before doing so).
    uvicorn.run(
        app,
        host=_agent.get("serveHost", "127.0.0.1"),
        port=_port(_agent, "agentPort"),
    )
