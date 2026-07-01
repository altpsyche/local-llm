"""NB1 — config/defaults.json is the neutral single source of truth for ports + roles, read
identically by Python (bob_core.load_defaults / _port / get_role) and PowerShell (_models.ps1
Get-BobPortDefault / Get-RoleForTask). This proves the two sides agree and that a dropped key
fails loudly on the Python side."""
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

import _common  # noqa: F401 — puts scripts/ on sys.path
import bob_core

REPO = Path(bob_core.REPO)
DEFAULTS = REPO / "config" / "defaults.json"

# A fully-populated routing/vision config so both languages resolve to the routing *values*
# (the fallback literals only matter for sparse configs, which production never has).
_CFG = {
    "routing": {
        "defaultRole": "chat", "proRole": "chat-pro",
        "codeRole": "coder", "proCodeRole": "coder-pro",
        "thinkRole": "planner", "proThinkRole": "planner-pro",
        "agentRole": "agent",
    },
    "vision": {"visionRole": "vision", "visionProRole": "vision-pro"},
}
# Tasks the PowerShell Get-RoleForTask ValidateSet accepts (no 'agent' there).
_TASKS = ["chat", "code", "think", "vision", "voice"]


class TestDefaultsPythonSide(unittest.TestCase):
    def test_ports_load_and_resolve(self):
        ports = bob_core.load_defaults()["ports"]
        for name in ("port", "litellmPort", "agentPort", "searxngPort", "sttPort",
                     "ttsPort", "webuiPort", "langfusePort", "n8nPort"):
            self.assertIn(name, ports)
            self.assertEqual(bob_core._port({}, name), ports[name])

    def test_role_table_drives_get_role(self):
        for task in _TASKS:
            self.assertEqual(bob_core.get_role(_CFG, task),
                             bob_core.get_role(_CFG, task, pro=False))

    def test_missing_ports_section_raises_clearly(self):
        bad = Path(tempfile.mkdtemp(prefix="bob-def-")) / "defaults.json"
        bad.write_text(json.dumps({"roleTable": {}}), encoding="utf-8")
        orig_file, orig_cache = bob_core._DEFAULTS_FILE, bob_core._defaults_cache
        try:
            bob_core._DEFAULTS_FILE = bad
            bob_core._defaults_cache = None
            with self.assertRaises(RuntimeError) as ctx:
                bob_core.load_defaults()
            self.assertIn("ports", str(ctx.exception))
        finally:
            bob_core._DEFAULTS_FILE, bob_core._defaults_cache = orig_file, orig_cache
            shutil.rmtree(bad.parent, ignore_errors=True)


@unittest.skipUnless(shutil.which("pwsh"), "pwsh not available — Python/PowerShell parity skipped")
class TestDefaultsParityWithPowerShell(unittest.TestCase):
    """Prove PowerShell reads config/defaults.json to the same values Python does."""

    def _pwsh(self, script: str) -> str:
        r = subprocess.run(["pwsh", "-NoProfile", "-Command", script],
                            capture_output=True, text=True, cwd=str(REPO), timeout=90)
        self.assertEqual(r.returncode, 0, f"pwsh failed:\n{r.stdout}\n{r.stderr}")
        return r.stdout.strip()

    def test_ports_identical(self):
        out = self._pwsh(". ./scripts/_models.ps1; "
                         "$script:BobPortDefaults | ConvertTo-Json -Compress")
        ps_ports = {k: int(v) for k, v in json.loads(out).items()}
        self.assertEqual(ps_ports, bob_core.load_defaults()["ports"])

    def test_roles_identical(self):
        cfg_ps = ("@{routing=@{defaultRole='chat';proRole='chat-pro';codeRole='coder';"
                  "proCodeRole='coder-pro';thinkRole='planner';proThinkRole='planner-pro';"
                  "agentRole='agent'};vision=@{visionRole='vision';visionProRole='vision-pro'}}")
        lines = []
        for t in _TASKS:
            lines.append(f'"{t}|" + (Get-RoleForTask -Config $c -Task {t})')
            lines.append(f'"{t}-pro|" + (Get-RoleForTask -Config $c -Task {t} -Pro)')
        script = f". ./scripts/_models.ps1; $c={cfg_ps}; " + "; ".join(lines)
        ps = dict(line.split("|", 1) for line in self._pwsh(script).splitlines())
        for t in _TASKS:
            self.assertEqual(ps[t], bob_core.get_role(_CFG, t), f"role mismatch: {t}")
            self.assertEqual(ps[f"{t}-pro"], bob_core.get_role(_CFG, t, pro=True),
                             f"pro role mismatch: {t}")


if __name__ == "__main__":
    unittest.main()
