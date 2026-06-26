# A Day with local-llm

This is a hands-on tour of every feature in the stack, structured as a typical working session. Follow it end-to-end the first time to see everything in action. After that, jump to any section as a quick reference.

**Prerequisites:** `install_prereqs.bat` and `setup.bat` have been run and completed successfully. You have an open terminal.

---

## Contents

- [Morning: Starting Up](#morning-starting-up)
- [Feature 1: Open WebUI (Browser Chat)](#feature-1-open-webui-browser-chat)
- [Feature 2: Continue.dev (VS Code Autocomplete and Chat)](#feature-2-continuedev-vs-code-autocomplete-and-chat)
- [Feature 3: Cline (VS Code Agentic Edits)](#feature-3-cline-vs-code-agentic-edits)
- [Feature 4: Aider (Terminal Plan-then-Edit)](#feature-4-aider-terminal-plan-then-edit)
- [Feature 5: Fabric (Shell Pattern Pipes)](#feature-5-fabric-shell-pattern-pipes)
- [Feature 6: SearXNG (Private Web Search)](#feature-6-searxng-private-web-search)
- [Feature 7: n8n (Workflow Automation)](#feature-7-n8n-workflow-automation)
- [Feature 8: Langfuse (LLM Observability)](#feature-8-langfuse-llm-observability)
- [Command Reference](#command-reference-everything-at-a-glance)
- [Evening: Wrapping Up](#evening-wrapping-up)
- [What to Try First](#what-to-try-first)

---

## Morning: Starting Up

### Start the stack

Open a terminal and run:

```powershell
llm up
```

This starts two things silently in the background:
- The **inference endpoint** at `http://localhost:8080/v1`: all your AI tools point here
- **Open WebUI** at `http://localhost:3000`: a browser chat interface

Your browser opens automatically. If you'd rather it didn't:
```powershell
llm up -NoOpen
```

Check that everything is running:
```powershell
llm status
```

You should see five models listed: `planner`, `coder`, `chat`, `fim`, `embed`. None are loaded into VRAM yet; they load on first use and stay there until idle. `fim` (autocomplete) and `embed` (search indexing) are pinned and never unload.

> **Tip:** To start everything (including Docker services) automatically at every login, create a Task Scheduler task set to "At log on" running:
> `pwsh -File C:\local-llm\scripts\up.ps1 -NoOpen`

### Start Docker services

The optional services (Langfuse, SearXNG, n8n) run in Docker. Make sure Docker Desktop is open (whale icon in the system tray), then:

```powershell
llm services start
llm services status
```

You should see four containers, all `Up`:
```
compose-langfuse-postgres-1   Up
compose-langfuse-1            Up
compose-searxng-1             Up
compose-n8n-1                 Up
```

The services are now available at:
- Langfuse: http://localhost:3001
- SearXNG: http://localhost:8888
- n8n: http://localhost:5678

---

## Feature 1: Open WebUI (Browser Chat)

**What it is:** A full-featured chat interface in your browser, like ChatGPT but running locally.

Open http://localhost:3000. On first visit, create a local account (username and password stored locally, with no signup email or server involved).

Try a first message:
```
Explain what a hash map is in simple terms.
```

The `chat` model is used by default. You'll notice a brief pause before the first word appears; the model is loading into VRAM. Subsequent messages in the same session are much faster.

### Switching models

At the top of the chat, click the model name dropdown and switch to `planner`. This is the larger reasoning model, better for complex questions, architecture discussions, or anything where you want it to think carefully before answering.

Switch back to `coder` for programming questions. It's faster and more precise on code tasks.

### Thinking mode and /no_think

The `planner` and `chat` models use a reasoning scratchpad by default. Before writing a response they think through the problem silently. This produces better answers for hard questions, but adds latency.

For quick questions where you don't need deep reasoning:
```
What's the keyboard shortcut to close a tab in Chrome? /no_think
```

Adding `/no_think` at the end of your message skips the scratchpad. Use it for simple lookups. Leave it off for planning, debugging, or architecture questions.

### Document chat (RAG)

Open the sidebar and find **Workspace → Knowledge**. Upload any PDF, text file, or document. Once indexed, start a new chat and click the `+` icon to attach it as context. Ask questions about it:
```
What are the main conclusions in this document?
```

The `embed` model indexes the document locally. Nothing leaves your machine.

---

## Feature 2: Continue.dev (VS Code Autocomplete and Chat)

**What it is:** Two things inside VS Code: as-you-type autocomplete and a chat panel with access to your codebase.

Open VS Code. The Continue panel is in the left sidebar (the Continue icon, or press `Ctrl+L` to open the chat tab).

### Autocomplete

Open any source file and start typing a function. After a second or two, ghost text appears suggesting how to continue. Press `Tab` to accept, or keep typing to dismiss. This is the `fim` model: small, fast, and pinned in VRAM so it never causes a reload delay.

Try typing in a Python file:
```python
def calculate_fibonacci(n):
```
Ghost text will suggest the body. Tab to accept.

### Chat panel

Press `Ctrl+L` to open or focus the Continue chat. Type a question about your code:
```
How does this function handle edge cases?
```

To include a specific file as context, type `@` in the chat box:
```
@filesystem C:\my-project\src\parser.py what does the parse_line function do?
```

To include the current file automatically, select some code before pressing `Ctrl+L` and it's included as context.

### Web search in chat

With SearXNG running, type `@web` to pull in live search results:
```
@web latest Python async best practices 2025
```

Continue sends the query to your local SearXNG, gets the top results, and gives them to the model as context before answering. Your search never goes to Google directly.

### Inline edit

Select a block of code in your editor and press `Ctrl+I`. A text box appears; type an instruction:
```
add input validation: raise ValueError if the string is empty
```

A diff appears inline. Press `Ctrl+Enter` (or click Accept) to apply it, or `Ctrl+Del` to reject and try again.

### Switching between coder and planner

At the bottom of the Continue chat panel, there's a model dropdown. Use `coder` for everyday edits and quick questions. Switch to `planner` when you want to discuss architecture or get deeper reasoning. Switching models causes a brief VRAM swap (a few seconds).

---

## Feature 3: Cline (VS Code Agentic Edits)

**What it is:** An AI agent inside VS Code that reads files, writes files, runs commands, and works across many turns without you guiding each step.

Open the Cline panel (C icon in the sidebar). If you haven't configured it yet:
- Click the settings gear
- API Provider: `OpenAI Compatible`
- Base URL: `http://localhost:8080/v1`
- API Key: `sk-local` (anything non-empty)
- Model ID: `coder`
- Context window: `16384`

### Your first Cline task

Give it a specific, contained task. Cline works best when the goal is clear:
```
Add a --verbose flag to the CLI that prints each step to stderr as it runs.
Look at src/cli.py to understand the current structure first.
```

Cline will:
1. Read the relevant files
2. Show you what it plans to do
3. Wait for your approval before writing anything
4. Make the edits, then ask if you want to continue

Review what it's about to do before clicking **Approve**. If the plan looks wrong, type a correction.

### Plan mode vs Act mode

In Cline settings, enable **"Use different models for Plan and Act"**:
- Plan model: `planner`
- Act model: `coder`

With this on, Cline uses `planner` (the larger reasoning model) to figure out the approach, then switches to `coder` to write the actual code. This costs a VRAM swap between models, but the plans are significantly better for complex tasks.

> **Tip:** Keep Cline tasks focused. If the conversation history gets long, start a new task. Long histories consume context window quickly.

---

## Feature 4: Aider (Terminal Plan-then-Edit)

**What it is:** A terminal coding agent with a genuine planning step. `planner` describes what needs to change in plain English; `coder` turns that into file edits. You review the plan before any file is touched.

Open a terminal, navigate to a project, and run:

```powershell
cd C:\my-project
llm aider
```

### A typical aider session

```
> /add src/auth.py
> /read docs/auth-spec.md

> Add JWT token expiry validation. Raise AuthError with a clear message if the token is expired.
```

What happens:
1. `planner` reads the files and writes a prose description of the changes it will make
2. You see the plan in the terminal
3. Press **Enter** to proceed, or type feedback to refine the plan
4. `coder` generates the diff and applies it

```
> /diff       # see what's pending
> /undo       # roll back the last edit (reverts git commit)
> /drop src/auth.py    # remove from context when done
```

aider commits each accepted edit to git automatically. Work on a branch so `/undo` stays clean.

### When to use aider vs Cline

| | aider | Cline |
|---|---|---|
| Lives in | Terminal | VS Code |
| Plan review | Always explicit | Shown but faster to skip |
| File scope control | Manual (`/add`, `/drop`) | Cline decides |
| Best for | Careful, reviewable edits | Fast multi-step tasks |

---

## Feature 5: Fabric (Shell Pattern Pipes)

**What it is:** Named prompt patterns you pipe text through in the terminal. Instead of writing the same system prompt every time ("summarize this in bullet points, formatted as..."), you pipe to `fabric --pattern <name>`.

First-time setup (once):
```powershell
llm fabric-setup
```

### Common patterns

```powershell
# Write a commit message from your staged diff
git diff --staged | fabric --pattern write_git_commit

# Summarize any document
cat meeting-notes.txt | fabric --pattern summarize

# Extract key takeaways and action items
cat meeting-notes.txt | fabric --pattern extract_wisdom

# Review code quality
cat src/parser.py | fabric --pattern code_review

# Explain an error log
cat error.log | fabric --pattern explain_code
```

See all 254 patterns:
```powershell
fabric -l
```

Fabric uses the `coder` model by default. For deeper analysis:
```powershell
cat architecture-doc.md | fabric --pattern analyze_claims --model planner
```

---

## Feature 6: SearXNG (Private Web Search)

**What it is:** A self-hosted search engine at http://localhost:8888. You type a query, SearXNG sends it to Google, Bing, DuckDuckGo, and others in parallel, and shows you combined results. Your searches aren't linked to any account.

Open http://localhost:8888 and try a search. Results come from multiple engines simultaneously.

### Set it as your browser's default search

Go to your browser's settings → Search engines → Add:
- Name: `Local Search`
- Shortcut: `s`
- URL: `http://localhost:8888/search?q=%s`

Now type `s <query>` in the address bar to search privately.

### @web in Continue.dev

This is where SearXNG integrates with your coding workflow. In the Continue chat panel:

```
@web what are the breaking changes in Python 3.13?
@web site:github.com llama.cpp fix KV cache
@web FastAPI background tasks best practices
```

Continue queries SearXNG, includes the top results as context, then asks the model. So the model answers with current information, not just what it was trained on. This is especially useful for library releases, recent bug fixes, and anything that changes frequently.

If `@web` returns nothing, check that Docker services are running: `llm services status`.

---

## Feature 7: n8n (Workflow Automation)

**What it is:** A visual workflow builder at http://localhost:5678. Connect triggers (a schedule, a webhook, a file change) to actions (call the local LLM, send an email, post to Slack) without writing scripts.

Open http://localhost:5678. On first visit, create a local account.

### Your first workflow: Commit message generator

Let's build a workflow that generates a commit message when you call a webhook.

1. Click **New Workflow**
2. Add a **Webhook** trigger node
   - Method: `POST`
   - Copy the webhook URL shown (something like `http://localhost:5678/webhook/abc123`)
3. Add an **HTTP Request** node after it
   - Method: `POST`
   - URL: `http://host.docker.internal:8080/v1/chat/completions`
   - Add header: `Authorization: Bearer sk-local`
   - Body (JSON):
     ```json
     {
       "model": "coder",
       "messages": [
         {"role": "system", "content": "Write a concise git commit message for this diff. Output only the message, nothing else."},
         {"role": "user", "content": "{{ $json.body.diff }}"}
       ]
     }
     ```
4. Add a **Set** node to extract the response:
   - Field: `message`
   - Value: `{{ $json.choices[0].message.content }}`
5. Add a **Respond to Webhook** node (returns the message as the HTTP response)
6. Click **Save**, then **Activate**

Now test it from a terminal:
```powershell
$diff = git diff --staged
$body = @{ diff = $diff } | ConvertTo-Json
Invoke-RestMethod -Uri "http://localhost:5678/webhook/abc123" -Method POST -Body $body -ContentType "application/json"
```

You get a commit message back. Wire this into a git hook to automate it completely.

> **Note:** Inside n8n containers, your machine is at `host.docker.internal`. The inference endpoint is always `http://host.docker.internal:8080/v1`.

### More workflow ideas

| Workflow | Trigger | What it does |
|---|---|---|
| PR summary | GitHub webhook on PR open | Fetches the diff → asks `coder` → posts summary comment |
| Daily digest | Schedule (every morning) | Fetches RSS feed → asks `planner` to summarize → emails you |
| Code review | Webhook from CI | Sends changed files to `coder` → returns review checklist |
| Release notes | Git tag push | Reads commit log → asks `planner` → writes formatted release notes |

---

## Feature 8: Langfuse (LLM Observability)

**What it is:** A dashboard at http://localhost:3001 that records every AI request routed through LiteLLM: the full prompt, response, latency, token counts, and retries. Useful for understanding what the model actually received (not what you think you sent), debugging unexpected answers, and seeing which workflows are expensive.

Default login: `admin@local.dev` / `admin123`

### Enabling tracing

Langfuse only captures requests routed through the LiteLLM proxy (port 8081). Direct requests to port 8080 are invisible. Here's how to wire it up:

**Step 1: Get API keys from Langfuse:**
1. Open http://localhost:3001
2. Go to **Settings → API Keys**
3. Click **Create API Key** and copy both the **Public Key** (`pk-lf-...`) and **Secret Key** (`sk-lf-...`)

**Step 2: Add keys to litellm.yaml:**

Open `config/litellm.yaml` and uncomment the callback block:
```yaml
litellm_settings:
  success_callback: ["langfuse"]
  failure_callback: ["langfuse"]

environment_variables:
  LANGFUSE_PUBLIC_KEY: "pk-lf-..."   # paste your public key here
  LANGFUSE_SECRET_KEY: "sk-lf-..."   # paste your secret key here
  LANGFUSE_HOST: "http://localhost:3001"
```

**Step 3: Start LiteLLM:**
```powershell
llm litellm stop      # stop if already running
llm litellm -NoWindow # restart with the new config
llm litellm status    # confirm it's running
```

**Step 4: Route requests through :8081:**

In Cline settings, change Base URL from `:8080/v1` to `:8081/v1`. For aider, set `openai-api-base: http://localhost:8081/v1` in `config/aider/.aider.conf.yml`. Direct `llm chat` calls go through LiteLLM automatically.

**Step 5: Make a request and check Langfuse:**

```powershell
llm chat coder "explain what a mutex is"
```

Open http://localhost:3001 → **Traces**. Within a few seconds you'll see the request appear with the full prompt, the response, and timing information.

### Reading a trace

Click any trace to expand it. You'll see:
- **Input**: the exact messages the model received, including system prompt
- **Output**: the model's full response
- **Latency**: time to first token and total generation time
- **Token usage**: prompt tokens + completion tokens + cost estimate (at $0 since it's local, but useful for seeing what's expensive)

This is how you debug "why did the model respond like that?": you see the exact system prompt and conversation history, not your application's internal representation.

---

## Command Reference: Everything at a Glance

### Inference

| Task | Command |
|---|---|
| Start everything | `llm up` |
| Start without browser | `llm up -NoOpen` |
| Start inference only | `llm serve` |
| Check what's running | `llm status` |
| Stop everything | `llm stop` |
| Tail logs | `llm logs` |

### Chat from terminal

| Task | Command |
|---|---|
| Chat with coder | `llm chat coder "your question"` |
| Chat with planner | `llm chat planner "design question"` |
| Skip the scratchpad | `llm chat chat "quick question /no_think"` |

### Docker services

| Task | Command |
|---|---|
| Start services | `llm services start` |
| Stop services | `llm services stop` |
| Check status | `llm services status` |
| Tail logs | `llm services logs` |

### Models

| Task | Command |
|---|---|
| List models | `llm models` |
| Switch to 12gb profile | `llm profile 12gb` |
| Download missing models | `llm fetch` |
| Throughput benchmark | `llm bench` |

### Aider

| Command | What it does |
|---|---|
| `/add src/file.py` | Add file as editable |
| `/read docs/spec.md` | Add file as read-only reference |
| `/ask <question>` | Ask without triggering edits |
| `/undo` | Revert last committed edit |
| `/diff` | Show pending changes |
| `/drop src/file.py` | Remove from context |

### Fabric

| Task | Command |
|---|---|
| Commit message from staged diff | `git diff --staged \| fabric --pattern write_git_commit` |
| Summarize a document | `cat notes.txt \| fabric --pattern summarize` |
| Extract action items | `cat meeting.txt \| fabric --pattern extract_wisdom` |
| Code review | `cat file.py \| fabric --pattern code_review` |
| Explain an error | `cat error.log \| fabric --pattern explain_code` |
| List all patterns | `fabric -l` |
| Use planner model | `cat doc.md \| fabric --pattern analyze_claims --model planner` |

### LiteLLM proxy

| Task | Command |
|---|---|
| Start proxy in background | `llm litellm -NoWindow` |
| Check proxy is running | `llm litellm status` |
| Stop proxy | `llm litellm stop` |
| Start foreground (see logs) | `llm litellm` |

LiteLLM runs on port 8081. Point any client at `:8081/v1` instead of `:8080/v1` to get retry-on-failure and Langfuse tracing.

### Diagnostics

| Task | Command |
|---|---|
| Hardware + CUDA + model health | `llm diagnose` |
| Running processes (PID, RAM) | `llm ps` |
| Check model files on disk | `llm show coder` |
| Throughput benchmark | `llm bench` |

---

## Evening: Wrapping Up

Stop the inference stack to free VRAM:
```powershell
llm stop
```

Stop Docker services to free RAM (optional; they're lightweight, you can leave them running):
```powershell
llm services stop
```

Data is always preserved when you stop. Langfuse traces, n8n workflows, and model files are all on disk. `llm up` tomorrow picks up exactly where you left off.

---

## What to Try First

If this was your first read-through, here's a short sequence that touches every feature:

1. `llm up`: start the stack
2. `llm diagnose`: confirm GPU, CUDA, and model files are all healthy
3. Open http://localhost:3000: chat with Open WebUI, try `/no_think` on a simple question
4. Open VS Code: accept an autocomplete suggestion, try `Ctrl+I` on a block of code
5. Open the Continue panel (`Ctrl+L`): ask `@web what changed in the latest Python release?`
6. Open the Cline panel: give it a small contained task ("add a docstring to this function")
7. In a terminal: `cd C:\my-project && llm aider`: add a file with `/add`, ask for a change, review the plan
8. In a terminal: `git diff --staged | fabric --pattern write_git_commit`
9. `llm services start`: start Docker services
10. Open http://localhost:8888: do a search, set it as a browser shortcut
11. Open http://localhost:5678: create a webhook workflow that calls the LLM
12. Enable Langfuse tracing (steps in the Langfuse section), make a request, open http://localhost:3001 and look at the trace
13. `llm stop`: shut down cleanly

For more detail on any feature: [USAGE.md](USAGE.md). For troubleshooting the Docker services: [USAGE.md § Docker troubleshooting](USAGE.md#troubleshooting-docker).
