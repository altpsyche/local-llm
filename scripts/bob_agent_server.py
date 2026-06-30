#!/usr/bin/env python3
"""Bob agent HTTP server — exposes the full agent tool loop as a REST endpoint.

Start: bob agent serve  (port 8084 by default)

POST /v1/agent/completions
  Body: {"goal": "...", "agency": "silent", "role": null}
  Returns: {"result": "...", "error": null}

Wire into n8n:
  URL: http://host.docker.internal:8084/v1/agent/completions
  Body: {"goal": "{{ $json.goal }}"}
"""
import sys
from pathlib import Path

REPO = Path(__file__).parent.parent
sys.path.insert(0, str(REPO / "scripts"))
sys.path.insert(0, str(REPO / "scripts" / "tools"))

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel
from typing import Optional

app = FastAPI(title="Bob Agent API", version="1.0")


class AgentRequest(BaseModel):
    goal: str
    agency: str = "silent"
    role: Optional[str] = None


class AgentResponse(BaseModel):
    result: Optional[str]
    error: Optional[str] = None


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/v1/agent/completions", response_model=AgentResponse)
def agent_completions(req: AgentRequest):
    try:
        from bob_core import load_config
        from bob_loop import run_agent
        config = load_config()
        result, _ = run_agent(req.goal, config, role=req.role, agency=req.agency)
        return AgentResponse(result=result)
    except FileNotFoundError as e:
        raise HTTPException(status_code=503, detail=str(e))
    except Exception as e:
        return AgentResponse(result=None, error=str(e))


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8084)
