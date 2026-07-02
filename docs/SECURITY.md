# Bob — Security Review (Module N / N9)

Scope: the agent tool surface and the `bob agent serve` HTTP server. Bob is a local-first,
single-operator assistant; the threat model is (1) a prompt-injected or misbehaving LLM abusing
its tools, and (2) exposure to other machines when the server is bound to `0.0.0.0`. Each claim
below names the test that backs it — run `tools\venv-litellm\Scripts\python.exe -m unittest discover -s tests`.

## Summary of guarantees

| Surface | Guarantee | Backed by |
|---------|-----------|-----------|
| Auth | Every endpoint except `/health` requires a valid bearer token (401 otherwise) | `test_server.test_auth_rejects_bad_token`, `test_completion_requires_auth`, `test_stream_requires_auth` |
| Ownership | A token only sees/modifies sessions its owner created; others 404 (no existence leak) | `test_server.test_owner_cannot_read_others_session_404`, `..._delete_...`, `..._complete_...`, `..._stream_...`, `test_unknown_and_unowned_are_indistinguishable` |
| `file_read`/`file_write` | Refuse paths outside `allowedReadPaths`/`allowedWritePaths` | `test_file.test_denies_outside_allowed_root` |
| Secrets denylist | `config.json`, `*.psd1`, `*.db`, `logs/`, `.env*` unreadable even inside an allowed root; the litellm key never leaks | `test_file.test_denies_config_json_and_hides_secret`, `..._psd1`, `..._db`, `..._env`, `..._logs_dir`, `test_write_refuses_secret_even_when_allowed` |
| `git_*` | Restricted to allow-listed repos (repo root + `gitAllowedRoots`); any other path refused | `test_git.test_outside_repo_denied`, `test_default_repo_allowed`, `test_extra_root_allowed` |
| `web_fetch` | http/https only; loopback/private/link-local blocked unless `allowPrivateFetch` (SSRF) | `test_web.*` |
| `shell_run` | Fails closed with no stdin; always requires interactive confirmation | manual (see below) |
| Session store | Concurrent access is safe; no lost turns | `test_session_concurrency.*` |
| Cancellation | Client disconnect / Ctrl-C aborts an in-flight run; no bogus turn recorded | `test_server.test_stream_disconnect_stops_and_records_no_turn`, `test_agent_loop.test_cancel_*` |

## Tool-by-tool

### `file_read` / `file_write` ([scripts/tools/file.py](../scripts/tools/file.py))
- **Allowlist.** `file_read` returns `Access denied` for any path outside `agent.allowedReadPaths`
  (defaults to the repo root at runtime — [_models.ps1](../scripts/_models.ps1)). `file_write` is
  **disabled** unless `agent.allowedWritePaths` is set.
- **Secrets denylist (N9, OS-aware since NB3/C3).** Even inside an allowed root, `_is_denied_secret`
  refuses `config.json` (holds `litellmKey` + `apiTokens`), any `*.psd1` (config), any `*.db` (session
  / memory stores), anything under a `logs/` directory, and `.env*`. NB3 (contract C3) made it
  OS-aware: it also denies the resolved secrets file (`data/secrets.json`) and the platform secret
  dirs (`~/.ssh`, `~/.aws`, `~/.gnupg`, `~/.config/bob`) on every OS. This closes the pre-N9 gap
  where the default repo-root allowlist exposed the proxy key and session DB to a prompt-injected
  read. Secrets themselves resolve through the seam — `osenv.secret()` (Python) / `Get-Secret`
  (PowerShell, NC1): env → OS keychain → `data/secrets.json` → default; never a git-tracked file. To
  read a legitimately-named-but-safe file that collides with the denylist, place it outside those
  patterns.

### `git_status` / `git_log` / `git_diff` ([scripts/tools/git.py](../scripts/tools/git.py))
- Read-only git subcommands. **Path allow-list (N9):** `_is_allowed_repo` restricts them to the
  Bob repo root plus `agent.gitAllowedRoots`; any other path returns `Access denied`. Before N9 a
  `path` argument could point at any repo on disk (info disclosure of unrelated history).

### `shell_run` ([scripts/tools/shell.py](../scripts/tools/shell.py))
- **Fail-closed.** Always prints the command and calls `input()` for a `y/N` confirmation
  regardless of the agency setting; on `EOFError`/no-stdin (the server, cron, any non-interactive
  caller) it returns `"Cancelled (no stdin)."` and runs nothing. 30s timeout; process killed on
  timeout. It is therefore **not** a remote-code-execution vector from the server. (Verified by
  reading the code; the tool is intentionally unusable non-interactively — a manual check, since a
  unit test can't assert on an interactive `input()` without mocking stdin.)

### `web_search` / `web_fetch` ([scripts/tools/web.py](../scripts/tools/web.py))
- `web_fetch` allowlists the `http`/`https` schemes (blocks `file://`, `gopher://`, etc.) and
  blocks hosts that resolve to loopback / RFC-1918 private / link-local / reserved / multicast
  addresses (SSRF), unless `agent.allowPrivateFetch = $true`. `web_search` hits only the local
  SearXNG instance. Backed by [tests/test_web.py](../tests/test_web.py).

### `fabric_run` ([scripts/tools/fabric.py](../scripts/tools/fabric.py))
- Runs a **named** fabric pattern (`fabric --pattern <name>`) on piped input, 120s timeout. The
  pattern name is resolved and validated by fabric itself against its installed pattern set; there
  is no path/argument passthrough from the model, so there is no traversal or injection surface
  here beyond whatever patterns the operator installed. No code change in N9 — documented as
  accepted.

### `memory_recall` / `memory_store` ([scripts/tools/memory.py](../scripts/tools/memory.py))
- Operate only on the local `bob.db` via the embed server; no external egress. Disabled unless
  `memory.enabled`.

## Auth + ownership ([scripts/bob_agent_server.py](../scripts/bob_agent_server.py))
- **Auth.** `_authed_owner` accepts a bearer token iff it is the litellm key or an `agent.apiTokens`
  entry, else **401**. `/health` is intentionally unauthenticated (returns only tool counts).
- **Ownership (N1).** Each token maps to an owner id (`agent.apiTokens` records `@{token;owner}`;
  the litellm key → `agent.defaultOwner`). Sessions are stamped with the creating owner; every
  session route resolves through `get_owned`/`delete_owned`, so another owner's `session_id`
  returns **404** — indistinguishable from an unknown id (no existence leak). Revocation = remove
  the token from config and restart `bob agent serve`.

## Exposing on `0.0.0.0` — checklist
`agent.serveHost` defaults to `127.0.0.1`. Before setting `0.0.0.0` (LAN/other machines):
1. Set strong, per-client `agent.apiTokens` with distinct owners — do **not** rely on the default
   `sk-local` litellm key. (Auth: 401 without a valid token; ownership: 404 across owners.)
2. Confirm the `file_read` secrets denylist is in force (N9) — the default repo-root allowlist
   would otherwise expose `config.json`. Narrow `allowedReadPaths` further if desired.
3. Leave `allowPrivateFetch = $false` so `web_fetch` can't be used to SSRF the host's private
   network from a LAN client.
4. Leave `allowedWritePaths` empty (or tightly scoped) — `file_write` is off by default.
5. Keep `gitAllowedRoots` empty unless a specific extra repo must be exposed.
6. Remember `shell_run` is inert on the server (no stdin) — no action needed.
7. Watch `logs/bob-agent.log`: every run carries a run-id (N5) so concurrent clients are
   distinguishable and any single run is greppable end-to-end.

## Known residual / accepted risks
- Token revocation requires a server restart (config is read once at startup) — acceptable for a
  single-operator local harness; documented, not a bug.
- `fabric_run` executes whatever patterns the operator installed; treat the fabric pattern library
  as trusted operator config.
- The secrets denylist is deliberately broad (all `*.psd1`/`*.db`, any `logs/`); a user who needs
  to read such a file via the agent must place it outside those patterns.
- **Denylist is name/path-based** (`Path.resolve()` — it follows symlinks/junctions and expands 8.3
  short names, but does *not* dereference NTFS **hardlinks**). An attacker who can create a hardlink
  to `config.json` under an allowed root with an innocuous name/suffix could read it via `file_read`.
  Reachability is low: `file_write` refuses the same secret patterns, and `shell_run` is
  confirmation-gated (inert on the server), so the agent has no built-in way to create such a link.
  Treat write access to an allowed root as trusted; do not expose the server on `0.0.0.0` while
  granting untrusted callers any file-creation capability inside an allowed root.
