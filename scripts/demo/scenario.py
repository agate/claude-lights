#!/usr/bin/env python3
"""Records the Claude Lights demo with synthetic sessions only. Nothing personal is shown.

  scenario.py setup      fake registry + isolated tmux + Terminal windows + clean Chrome + demo app
  scenario.py set NAME STATE
  scenario.py shot       still screenshots (bar, menu, notification) into build/demo/
  scenario.py record     hide other apps, run the timeline, screen-record into build/demo/
  scenario.py teardown   undo everything and relaunch the user's own Claude Lights

The demo app instance reads CLAUDE_LIGHTS_SESSIONS_DIR (a fake registry) and TMUX_TMPDIR (a separate
tmux server), so the user's real Claude, tmux and herdr sessions never appear. See scripts/demo/README.md.
"""
import json
import os
import plistlib
import pathlib
import shutil
import subprocess
import sys
import time
import uuid

REPO = pathlib.Path(__file__).resolve().parents[2]
APP = REPO / "build" / "ClaudeLights.app"
OUT = REPO / "build" / "demo"            # under $HOME so the Docker ffmpeg can read it
RUN = pathlib.Path("/tmp/cl-demo")
BIN, REG, STATE, TMUXDIR = RUN / "bin", RUN / "sessions", RUN / "state", RUN / "tmux"
CHROME_PROFILE = RUN / "chrome"
SAVED = RUN / "app-prefs.backup.plist"
TERM_PREFS_BACKUP = RUN / "terminal-prefs.backup.plist"
TERM_SAVED_STATE = pathlib.Path.home() / "Library" / "Saved Application State" / "com.apple.Terminal.savedState"
BUNDLE = "me.honghao.ClaudeLights"
FAKE = REPO / "scripts" / "demo" / "fake_claude.py"

# Bar order follows startedAt, oldest first.
SESSIONS = ["docs-site", "api-server", "data-pipeline", "blog", "mobile-app", "notes"]
TMUX_SESSIONS = ["docs-site", "api-server", "data-pipeline", "blog", "notes"]   # mobile-app runs without tmux
INITIAL = {"docs-site": "working", "api-server": "working", "data-pipeline": "answered",
           "blog": "idle", "mobile-app": "working", "notes": "fresh"}
NO_TRANSCRIPT = {"notes"}   # the app shows a session with no transcript yet as hollow gray ("just started")
TRANSCRIPTS = pathlib.Path.home() / ".claude" / "projects"
TRANSCRIPT_PREFIX = "-Users-demo-projects-"   # matches cwd /Users/demo/projects/<name>; removed on teardown
REGISTRY_STATUS = {"working": "busy", "approved": "busy", "waiting": "waiting",
                   "done": "idle", "idle": "idle", "answered": "shell", "fresh": None}

# Screen layout in points (1512 x 982 display, 33 pt menu bar).
CHROME_BOUNDS = (0, 33, 1512, 982)
TERM_TMUX_BOUNDS = (150, 150, 1010, 760)
TERM_SOLO_BOUNDS = (430, 230, 1290, 830)
BAR_FRACTION = (0.5186, 0.9695)       # top center (measured after a drag): clear of notification banners


def sh(*args, check=True, env=None, **kw):
    r = subprocess.run(args, text=True, capture_output=True, env={**os.environ, **(env or {})}, **kw)
    if check and r.returncode != 0:
        raise SystemExit(f"failed ({r.returncode}): {' '.join(args)}\n{r.stderr.strip()}")
    return r.stdout.strip()


def osa(script):
    return sh("osascript", "-e", script)


def tmux(*args):
    return sh("tmux", *args, env={"TMUX_TMPDIR": str(TMUXDIR)})


def ids():
    return json.loads((RUN / "ids.json").read_text())


def now_ms():
    return int(time.time() * 1000)


def write_registry(name, state):
    meta = ids()[name]
    status = REGISTRY_STATUS[state]
    rec = {"pid": meta["pid"], "sessionId": meta["sid"], "cwd": f"/Users/demo/projects/{name}",
           "kind": "interactive", "version": "2.1.302", "startedAt": meta["startedAt"],
           "statusUpdatedAt": now_ms(), "updatedAt": now_ms()}
    if status:
        rec["status"] = status
    if state == "waiting":
        rec["waitingFor"] = "permission prompt"
    tmp = REG / f".{meta['pid']}.json.tmp"
    tmp.write_text(json.dumps(rec))
    tmp.replace(REG / f"{meta['pid']}.json")


def set_state(name, state):
    (STATE / name).write_text("done" if state == "fresh" else state)
    write_registry(name, state)


def find_pid(name, tries=40):
    for _ in range(tries):
        # anchored on python3: the tmux server's own command line also contains the script path
        out = sh("pgrep", "-f", f"^python3 -I [^ ]*fake_claude.py {name} ", check=False)
        if out:
            return int(out.split()[0])
        time.sleep(0.25)
    raise SystemExit(f"fake session {name} did not start")


def demo_app_pid():
    for line in sh("pgrep", "-fl", "ClaudeLights.app/Contents/MacOS", check=False).splitlines():
        pid = int(line.split()[0])
        env = sh("ps", "eww", "-o", "command=", "-p", str(pid), check=False)
        if "CLAUDE_LIGHTS_SESSIONS_DIR" in env:
            return pid
    return None


def windows(owner=None):
    rows = [json.loads(l) for l in sh(str(BIN / "windows")).splitlines()]
    return [r for r in rows if owner is None or r["owner"] == owner]


def bar_frame():
    for r in windows("Claude Lights"):
        if r["layer"] == 3 and r["h"] < 60:
            return r
    return None


def status_item():
    pid = demo_app_pid()
    rows = sh(str(BIN / "windows"), "--status-item", str(pid)).splitlines()
    return json.loads(rows[-1]) if rows else None


def mouse(*args):
    sh(str(BIN / "mouse"), *map(str, args))


# ---------------------------------------------------------------- setup / teardown

def build_helpers():
    BIN.mkdir(parents=True, exist_ok=True)
    for tool in ("mouse", "windows"):
        src = REPO / "scripts" / "demo" / f"{tool}.swift"
        dst = BIN / tool
        if not dst.exists() or dst.stat().st_mtime < src.stat().st_mtime:
            sh("swiftc", "-O", "-o", str(dst), str(src))


def terminal_window(command, title, bounds):
    osa(f'tell application "Terminal" to do script "cd /tmp; {command}"')
    time.sleep(0.8)
    osa('tell application "Terminal"\n'
        '  set current settings of selected tab of front window to settings set "Basic"\n'
        '  tell selected tab of front window\n'
        f'    set custom title to "{title}"\n'
        '    set title displays custom title to true\n'
        '    set title displays device name to false\n'
        '    set title displays shell path to false\n'
        '    set title displays window size to false\n'
        '    set title displays file name to false\n'
        '  end tell\n'
        f'  set bounds of front window to {{{",".join(map(str, bounds))}}}\n'
        'end tell')


def close_stray_terminal_windows():
    """Minimizes Terminal's own startup window (it shows the user's prompt). Closing it would ask
    to terminate the login shell's helpers, and a minimized window stays out of the recording."""
    osa('tell application "Terminal"\n'
        '  repeat with w in (every window whose name does not contain "work" and name does not contain "mobile-app")\n'
        '    set miniaturized of w to true\n'
        '  end repeat\n'
        'end tell')


def write_usage():
    """Made-up plan limits in the shape of Claude Code's get_usage answer, so the demo app never asks
    the real account (it would not anyway with a demo registry, but then the meter and menu would be empty)."""
    def at(hours):
        return time.strftime("%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() + hours * 3600))
    limits = {
        "limits": [
            {"group": "session", "percent": 38, "resets_at": at(2.4), "scope": None},
            {"group": "weekly", "percent": 22, "resets_at": at(70),
             "scope": {"model": {"display_name": "Fable"}}},
        ],
        "extra_usage": {"is_enabled": True, "monthly_limit": 10000, "used_credits": 2750,
                        "currency": "USD", "decimal_places": 2},
    }
    answer = {"type": "control_response", "response": {"subtype": "success", "request_id": "usage",
              "response": {"rate_limits_available": True, "rate_limits": limits}}}
    path = RUN / "usage.jsonl"
    path.write_text(json.dumps(answer) + "\n")
    return path


def setup():
    build_helpers()
    for d in (REG, STATE, TMUXDIR, OUT):
        d.mkdir(parents=True, exist_ok=True)
    for f in REG.glob("*.json"):
        f.unlink()

    # Remember the user's Claude Lights preferences (bar placement); teardown imports them back.
    if not SAVED.exists():
        sh("defaults", "export", BUNDLE, str(SAVED))

    for name in SESSIONS:
        (STATE / name).write_text(INITIAL[name])

    # Isolated tmux server: one window per tmux-hosted session.
    env = {"TMUX_TMPDIR": str(TMUXDIR)}
    sh("tmux", "kill-server", check=False, env=env)
    time.sleep(0.5)
    first = True
    for name in TMUX_SESSIONS:
        cmd = f"python3 -I {FAKE} {name} {STATE}"
        if first:
            # -f /dev/null: never load the user's ~/.tmux.conf (its theme shows the host name).
            sh("tmux", "-f", "/dev/null", "new-session", "-d", "-s", "work", "-n", name, "-x", "110", "-y", "34",
               cmd, env=env)
            for opt, val in (("status-style", "bg=#2b2b2b,fg=#bdbdbd"), ("status-left", " work  "),
                             ("status-left-length", "10"), ("status-right", ""), ("set-titles", "off"),
                             ("window-status-current-style", "bg=#d97757,fg=#1e1e1e"),
                             ("window-status-format", " #I #W "), ("window-status-current-format", " #I #W ")):
                sh("tmux", "set", "-g", opt, val, env=env)
            first = False
        else:
            sh("tmux", "new-window", "-t", "work", "-n", name, cmd, env=env)
    sh("tmux", "select-window", "-t", "work:blog", env=env)

    # Terminal.app (the user's own terminal is iTerm2, so nothing personal comes forward on a jump).
    # Its titles would show the home folder name and the command line, so the Basic profile is
    # switched to custom titles only; teardown restores the backed-up preferences.
    sh("pkill", "-9", "-x", "Terminal", check=False)   # quitting asks about running processes; only demo windows are open
    time.sleep(1.5)
    shutil.rmtree(TERM_SAVED_STATE, ignore_errors=True)   # else a force-quit Terminal reopens old windows
    if not TERM_PREFS_BACKUP.exists():
        sh("defaults", "export", "com.apple.Terminal", str(TERM_PREFS_BACKUP))
    prefs = plistlib.loads(TERM_PREFS_BACKUP.read_bytes())
    basic = prefs.setdefault("Window Settings", {}).setdefault("Basic", {})
    for key in ("ShowActiveProcessInTitle", "ShowActiveProcessArgumentsInTitle", "ShowRepresentedURLInTitle",
                "ShowRepresentedURLPathInTitle", "ShowShellCommandInTitle", "ShowTTYNameInTitle",
                "ShowDimensionsInTitle", "ShowCommandKeyInTitle", "ShowWindowSettingsNameInTitle"):
        basic[key] = False
    demo_prefs = RUN / "terminal-prefs.demo.plist"
    demo_prefs.write_bytes(plistlib.dumps(prefs))
    sh("defaults", "import", "com.apple.Terminal", str(demo_prefs))
    # Ignore saved window state, or a force-quit Terminal reopens every earlier window.
    sh("open", "-a", "Terminal", "--args", "-ApplePersistenceIgnoreState", "YES")
    time.sleep(2)
    osa('tell application "Terminal" to close every window saving no')
    time.sleep(0.5)
    terminal_window(f"clear; exec env TMUX_TMPDIR={TMUXDIR} tmux attach -t work", "work — tmux", TERM_TMUX_BOUNDS)
    terminal_window(f"clear; exec python3 -I {FAKE} mobile-app {STATE}", "mobile-app", TERM_SOLO_BOUNDS)
    time.sleep(0.5)
    close_stray_terminal_windows()

    meta = {}
    t0 = now_ms() - 40 * 60_000
    for i, name in enumerate(SESSIONS):
        meta[name] = {"pid": find_pid(name), "sid": str(uuid.uuid4()), "startedAt": t0 + i * 60_000}
    (RUN / "ids.json").write_text(json.dumps(meta))
    for name in SESSIONS:
        if name in NO_TRANSCRIPT:
            continue
        d = TRANSCRIPTS / f"{TRANSCRIPT_PREFIX}{name}"
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{meta[name]['sid']}.jsonl").write_text(json.dumps(
            {"type": "user", "message": {"role": "user", "content": "demo"}}) + "\n")
    for name in SESSIONS:
        write_registry(name, INITIAL[name])

    # A clean Chrome profile: no bookmarks, avatar, extensions or history. Restarted so it has one tab.
    sh("pkill", "-f", "--", f"user-data-dir={CHROME_PROFILE}", check=False)
    time.sleep(1.5)
    subprocess.Popen(["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
                      f"--user-data-dir={CHROME_PROFILE}", "--no-first-run", "--no-default-browser-check",
                      "--disable-search-engine-choice-screen", "--disable-features=SigninIntercept",
                      f"--window-position={CHROME_BOUNDS[0]},{CHROME_BOUNDS[1]}",
                      f"--window-size={CHROME_BOUNDS[2] - CHROME_BOUNDS[0]},{CHROME_BOUNDS[3] - CHROME_BOUNDS[1]}",
                      "https://honghao.me/"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Swap the user's Claude Lights for a demo instance that only sees the fake registry.
    sh("pkill", "-f", "ClaudeLights.app/Contents/MacOS", check=False)
    time.sleep(1.5)
    # Written after the old instance exits, which would otherwise save its own placement over these.
    prefs = plistlib.loads(SAVED.read_bytes())
    prefs.update(barPinnedTopRight=False, barHidden=False, barFraction=[float(v) for v in BAR_FRACTION])
    demo_prefs = RUN / "app-prefs.demo.plist"
    demo_prefs.write_bytes(plistlib.dumps(prefs))
    sh("defaults", "import", BUNDLE, str(demo_prefs))   # `defaults write -array` would store strings
    seen = ids()["blog"]["sid"]
    usage = write_usage()
    # Not `open -n`: a second instance is refused notification permission and only plays the sound.
    sh("open", str(APP), "--env", f"CLAUDE_LIGHTS_SESSIONS_DIR={REG}",
       "--env", f"TMUX_TMPDIR={TMUXDIR}", "--env", f"CLAUDE_LIGHTS_DEMO_SEEN_IDS={seen}",
       "--env", f"CLAUDE_LIGHTS_DEMO_USAGE_FILE={usage}")
    time.sleep(3)
    print(json.dumps({"bar": bar_frame(), "status_item": status_item()}))


def teardown():
    sh("pkill", "-f", "ClaudeLights.app/Contents/MacOS", check=False)
    sh("tmux", "kill-server", check=False, env={"TMUX_TMPDIR": str(TMUXDIR)})
    sh("pkill", "-f", "fake_claude.py", check=False)
    sh("pkill", "-9", "-x", "Terminal", check=False)   # quitting asks about running processes; only demo windows are open
    time.sleep(1.5)
    shutil.rmtree(TERM_SAVED_STATE, ignore_errors=True)
    if TERM_PREFS_BACKUP.exists():
        sh("defaults", "import", "com.apple.Terminal", str(TERM_PREFS_BACKUP))
        TERM_PREFS_BACKUP.unlink()
    sh("pkill", "-f", "--", f"user-data-dir={CHROME_PROFILE}", check=False)
    for d in TRANSCRIPTS.glob(f"{TRANSCRIPT_PREFIX}*"):
        shutil.rmtree(d)
    if SAVED.exists():
        sh("defaults", "import", BUNDLE, str(SAVED))
        SAVED.unlink()
    unhide_all()
    time.sleep(1)
    sh("open", str(APP))   # the user's own instance, real registry


def hide_others():
    keep = {str(p) for p in [demo_app_pid()] if p}
    keep |= {str(chrome_pid())}
    keep |= set(sh("pgrep", "-x", "Terminal", check=False).split())
    osa('tell application "System Events" to set procs to every process whose background only is false\n'
        f'set keep to {{{",".join(keep)}}}\n'
        'tell application "System Events" to repeat with p in procs\n'
        '  if keep does not contain (unix id of p) then set visible of p to false\n'
        'end repeat')


def unhide_all():
    osa('tell application "System Events" to set visible of every process whose background only is false to true')


# ---------------------------------------------------------------- recording

def dot_center(name):
    """Center of a session's dot on the floating bar, in screen points (calibrated in calibrate.json)."""
    cal = json.loads((OUT / "calibrate.json").read_text())
    bar = bar_frame()
    i = SESSIONS.index(name)
    return bar["x"] + cal["first"] + i * cal["pitch"], bar["y"] + bar["h"] / 2


def chrome_pid():
    """The demo Chrome's main process (its helpers share the --user-data-dir argument)."""
    out = sh("pgrep", "-f", "--", f"MacOS/Google Chrome --user-data-dir={CHROME_PROFILE}", check=False)
    return int(out.split()[0]) if out else None


def front_chrome():
    pid = chrome_pid()
    osa(f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true')


def record(duration=46):
    events = []
    t0 = None

    def mark(kind, **data):
        events.append({"t": round(time.time() - t0, 2), "kind": kind, **data})

    for name in SESSIONS:
        set_state(name, INITIAL[name])
    tmux("select-window", "-t", "work:blog")
    front_chrome()
    hide_others()
    front_chrome()
    mouse("move", 760, 520, 0.2)
    time.sleep(1.5)

    movie = OUT / "raw.mov"
    movie.unlink(missing_ok=True)
    rec = subprocess.Popen(["screencapture", "-v", "-x", "-k", "-V", str(duration), str(movie)])
    t0 = time.time()
    time.sleep(1.0)
    mark("start")

    # 1. Working in the browser; the bar sits quietly on top.
    mouse("scroll", -300, 30)
    time.sleep(2.5)

    # 2. api-server finishes -> green check, banner, ping.
    set_state("api-server", "done"); mark("change", session="api-server", to="done", notify=True)
    time.sleep(5)

    # 3. docs-site needs a permission -> red.
    set_state("docs-site", "waiting"); mark("change", session="docs-site", to="waiting", notify=True)
    time.sleep(4.5)

    # 4. Hover the red light, then click: Terminal comes forward on the right tmux window.
    x, y = dot_center("docs-site")
    mark("hover", session="docs-site")
    mouse("move", x, y, 0.9)
    time.sleep(1.8)
    mark("click", session="docs-site")
    mouse("click", x, y)
    time.sleep(3.2)

    # 5. Approve the command; the light goes back to working.
    mark("approve", session="docs-site")
    tmux("send-keys", "-t", "work:docs-site", "1")
    time.sleep(0.6)
    set_state("docs-site", "approved"); mark("change", session="docs-site", to="working")
    time.sleep(3)

    # 6. Back to the browser. mobile-app (no tmux, its own Terminal window) finishes.
    mouse("click", 1400, 500)   # a spot only Chrome covers
    time.sleep(1.5)
    set_state("mobile-app", "done"); mark("change", session="mobile-app", to="done", notify=True)
    time.sleep(3.5)
    x, y = dot_center("mobile-app")
    mark("hover", session="mobile-app")
    mouse("move", x, y, 0.9)
    time.sleep(1.4)
    mark("click", session="mobile-app")
    mouse("click", x, y)
    time.sleep(3.2)

    # 7. docs-site finishes while you're elsewhere.
    set_state("docs-site", "done"); mark("change", session="docs-site", to="done", notify=True)
    time.sleep(3.5)

    # 8. The menu bar dot lists every session.
    si = status_item()
    mark("menu")
    mouse("move", si["x"] + si["w"] / 2, si["y"] + si["h"] / 2, 0.9)
    mouse("click", si["x"] + si["w"] / 2, si["y"] + si["h"] / 2)
    time.sleep(4)
    mouse("click", 700, 600)
    mark("end")

    rec.wait()
    unhide_all()
    (OUT / "events.json").write_text(json.dumps({"events": events, "bar": bar_frame(), "status_item": si,
                                                 "dots": {n: dot_center(n) for n in SESSIONS}}, indent=1))
    print(f"recorded {movie}")


# ---------------------------------------------------------------- stills

def shot():
    """Bar with all six states, the open menu, and a notification banner, each as its own window capture."""
    # api-server is never jumped to, so its "done" stays the unseen green check.
    states = {"docs-site": "waiting", "api-server": "done", "data-pipeline": "answered",
              "blog": "idle", "mobile-app": "working"}
    for n, s in states.items():
        set_state(n, s)
    time.sleep(2)
    bar = bar_frame()
    sh("screencapture", "-x", "-o", "-l", str(bar["id"]), str(OUT / "bar.png"))
    si = status_item()
    mouse("click", si["x"] + si["w"] / 2, si["y"] + si["h"] / 2)
    time.sleep(1.2)
    menus = [w for w in windows() if w["layer"] >= 101 and w["owner"] == "Claude Lights"]
    if menus:
        sh("screencapture", "-x", "-l", str(menus[0]["id"]), str(OUT / "menu.png"))
    mouse("click", 700, 600)   # Escape does not always reach the menu; a click outside closes it
    time.sleep(1.5)            # let the menu finish fading out
    # A banner from a session that has not notified yet (a repeat id only updates silently). The app
    # shows the session's last assistant message as the body, so give the transcript one.
    meta = ids()["data-pipeline"]
    transcript = TRANSCRIPTS / f"{TRANSCRIPT_PREFIX}data-pipeline" / f"{meta['sid']}.jsonl"
    with transcript.open("a") as f:
        f.write(json.dumps({"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "text", "text": "Backfill finished: 1.2M events, 0 errors. Safe to deploy."}]}}) + "\n")
    set_state("data-pipeline", "working")
    time.sleep(3)
    set_state("data-pipeline", "done")
    time.sleep(1.2)
    # Banners are drawn by Notification Center without a listable window: capture the top-right corner.
    sh("screencapture", "-x", "-R1150,36,362,92", str(OUT / "notification.png"))
    print(json.dumps({"bar": bar, "menus": menus[:1]}))


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "setup":
        setup()
    elif cmd == "teardown":
        teardown()
    elif cmd == "set":
        set_state(sys.argv[2], sys.argv[3])
    elif cmd == "record":
        record()
    elif cmd == "shot":
        shot()
    elif cmd == "hide":
        hide_others()
    elif cmd == "unhide":
        unhide_all()
    else:
        print(__doc__)
