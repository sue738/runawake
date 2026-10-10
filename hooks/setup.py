#!/usr/bin/python3 -I
"""Install/remove runawake-mark hooks for installed AI agents.

  python3 hooks/setup.py install     # install (no-op if already installed)
  python3 hooks/setup.py uninstall   # remove only entries containing runawake-mark

Before modifying a config file, back it up once to <file>.bak-runawake.
Agents that are not installed (no config directory) are left alone.
"""
import json, os, shutil, sys

HOME = os.path.expanduser("~")
HERE = os.path.dirname(os.path.abspath(__file__))
MARK = os.path.join(HOME, ".runawake", "bin", "runawake-mark")
TAG = "runawake-mark"


def cmd(mode, agent, reply=""):
    return f"'{MARK}' {mode} {agent}" + (f" '{reply}'" if reply else "")


def load(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def save(path, data):
    # Back up only the state before runawake touched it (don't back up files we created)
    if os.path.exists(path) and not os.path.exists(path + ".bak-runawake") and TAG not in open(path).read():
        shutil.copy2(path, path + ".bak-runawake")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
        f.write("\n")


def strip(obj):
    """Remove entries containing runawake-mark (any format, recursing into nested structures)."""
    if isinstance(obj, list):
        return [strip(x) for x in obj if TAG not in json.dumps(x)]
    if isinstance(obj, dict):
        return {k: strip(v) for k, v in obj.items()}
    return obj


def prune_empty(hooks):
    return {k: v for k, v in hooks.items() if v != []}


# ---- Claude Code / Codex: same format ---------------------------------------------
def claude_like(path, agent, events):
    def install():
        d = load(path, {})
        h = strip(d.get("hooks", {}))
        for ev, mode in events:
            matcher = NOTIFICATION_MATCHER if ev == "Notification" else ""
            h.setdefault(ev, []).append({"matcher": matcher, "hooks": [{"type": "command", "command": cmd(mode, agent), "timeout": 5}]})
        d["hooks"] = h
        save(path, d)

    def uninstall():
        d = load(path, None)
        if d is None:
            return
        d["hooks"] = prune_empty(strip(d.get("hooks", {})))
        save(path, d)

    return install, uninstall


CLAUDE_EVENTS = [("UserPromptSubmit", "busy"), ("PostToolUse", "busy"), ("Stop", "idle")]
# Claude Code sends no Stop when interrupted with Esc. Go idle on input/permission-wait notifications to avoid staying awake.
CLAUDE_ONLY_EVENTS = CLAUDE_EVENTS + [("Notification", "idle"), ("SubagentStart", "busy"), ("SubagentStop", "idle")]
NOTIFICATION_MATCHER = "permission_prompt|idle_prompt|agent_needs_input"


# ---- Gemini CLI ---------------------------------------------------------------------
def gemini():
    path = os.path.join(HOME, ".gemini", "settings.json")

    def install():
        d = load(path, {})
        d.setdefault("tools", {})["enableHooks"] = True
        h = strip(d.get("hooks", {}))
        h.pop("enabled", None)  # 0.28.x rejects hooks.enabled and then fails to read the whole config
        for ev, mode in [("BeforeAgent", "busy"), ("AfterTool", "busy"), ("AfterAgent", "idle")]:
            h.setdefault(ev, []).append({"matcher": "*", "hooks": [{"name": f"runawake-{mode}", "type": "command", "command": cmd(mode, "gemini", "{}")}]})
        d["hooks"] = h
        save(path, d)

    def uninstall():
        d = load(path, None)
        if d is None:
            return
        d["hooks"] = prune_empty(strip(d.get("hooks", {})))
        save(path, d)

    return install, uninstall


# ---- Antigravity CLI (agy) ----------------------------------------------------------
def antigravity():
    path = os.path.join(HOME, ".gemini", "config", "hooks.json")

    def install():
        d = load(path, {})
        d["runawake"] = {
            "enabled": True,
            "PreInvocation": [{"type": "command", "command": cmd("busy", "antigravity", "{}"), "timeout": 10}],
            "Stop": [{"type": "command", "command": cmd("idle", "antigravity", "{}"), "timeout": 10}],
        }
        save(path, d)

    def uninstall():
        d = load(path, None)
        if d is not None and d.pop("runawake", None) is not None:
            save(path, d)

    return install, uninstall


# ---- Cursor (IDE agent. The cursor-agent CLI doesn't call these, so the app catches it via CPU detection) ----
def cursor():
    path = os.path.join(HOME, ".cursor", "hooks.json")

    def install():
        d = load(path, {"version": 1, "hooks": {}})
        d.setdefault("version", 1)
        h = strip(d.get("hooks", {}))
        h.setdefault("beforeSubmitPrompt", []).append({"command": cmd("busy", "cursor", '{"continue":true}')})
        h.setdefault("postToolUse", []).append({"command": cmd("busy", "cursor", "{}")})
        h.setdefault("stop", []).append({"command": cmd("idle", "cursor", "{}")})
        d["hooks"] = h
        save(path, d)

    def uninstall():
        d = load(path, None)
        if d is None:
            return
        d["hooks"] = prune_empty(strip(d.get("hooks", {})))
        save(path, d)

    return install, uninstall


# ---- GitHub Copilot CLI ----------------------------------------------------------------
def copilot():
    base = os.environ.get("COPILOT_HOME") or os.path.join(HOME, ".copilot")
    path = os.path.join(base, "hooks", "runawake.json")

    def install():
        ev = {"userPromptSubmitted": "busy", "postToolUse": "busy", "agentStop": "idle"}
        save(path, {"version": 1, "hooks": {e: [{"type": "command", "bash": cmd(m, "copilot"), "timeoutSec": 5}] for e, m in ev.items()}})

    def uninstall():
        if os.path.exists(path):
            os.remove(path)

    return install, uninstall


# ---- OpenCode (plugin) ------------------------------------------------------------------
OPENCODE_PLUGIN = """// runawake: puts marks (runawake-mark) so the Mac doesn't sleep only while OpenCode is responding
import { spawn } from "node:child_process"

const MARK = %s

function mark(mode, sid) {
  const p = spawn(MARK, [mode, "opencode"], { stdio: ["pipe", "ignore", "ignore"] })
  p.on("error", () => {})
  p.stdin.end(JSON.stringify({ session_id: sid, cwd: process.cwd() }))
}

export const RunawakePlugin = async () => ({
  event: async ({ event }) => {
    const sid = event.properties?.sessionID
    if (!sid) return
    if (event.type === "session.idle") mark("idle", sid)
    else if (event.type === "session.status") mark(event.properties?.status?.type === "idle" ? "idle" : "busy", sid)
  },
  "tool.execute.after": async (input) => {
    if (input?.sessionID) mark("busy", input.sessionID)
  },
})
"""


def opencode():
    path = os.path.join(HOME, ".config", "opencode", "plugin", "runawake.js")

    def install():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write(OPENCODE_PLUGIN % json.dumps(MARK))

    def uninstall():
        if os.path.exists(path):
            os.remove(path)

    return install, uninstall


# (name, path indicating it is installed, install/uninstall)
AGENTS = [
    ("Claude Code", os.path.join(HOME, ".claude"), claude_like(os.path.join(HOME, ".claude", "settings.json"), "claude", CLAUDE_ONLY_EVENTS)),
    ("Codex", os.path.join(HOME, ".codex"), claude_like(os.path.join(HOME, ".codex", "hooks.json"), "codex", CLAUDE_EVENTS)),
    ("Antigravity CLI", os.path.join(HOME, ".gemini", "antigravity-cli"), antigravity()),
    ("Gemini CLI", os.path.join(HOME, ".gemini"), gemini()),
    ("Cursor", os.path.join(HOME, ".cursor"), cursor()),
    ("Copilot CLI", os.environ.get("COPILOT_HOME") or os.path.join(HOME, ".copilot"), copilot()),
    ("OpenCode", os.path.join(HOME, ".config", "opencode"), opencode()),
]


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "install"
    if action == "install":
        os.makedirs(os.path.dirname(MARK), exist_ok=True)
        shutil.copy2(os.path.join(HERE, "runawake-mark"), MARK)
        os.chmod(MARK, 0o755)
    if action == "uninstall":
        # Forget which agents' hooks were seen working, so the app falls back to CPU detection right away
        shutil.rmtree(os.path.join(HOME, ".runawake", "hooks-ok"), ignore_errors=True)
    for name, marker, (install, uninstall) in AGENTS:
        if not os.path.isdir(marker):
            print(f"  -  {name}: not installed, skipped")
            continue
        (install if action == "install" else uninstall)()
        print(f"  ✓  {name}: {'installed' if action == 'install' else 'removed'}")


if __name__ == "__main__":
    main()
