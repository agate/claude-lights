#!/usr/bin/env python3
"""A stand-in Claude Code screen for the demo recording. All content is synthetic.

Run inside a terminal pane:  fake_claude.py <session-name> <state-dir>
It redraws whenever <state-dir>/<session-name> changes. Each state file holds one word:
  working | waiting | approved | done | answered | idle
Pressing "1" while waiting writes "approved" (the scenario then flips the registry to busy).
"""
import os
import re
import select
import sys
import termios
import time
import tty

ORANGE, GRAY, DIM, BOLD, GREEN, RED, RESET = (
    "\033[38;5;173m", "\033[38;5;245m", "\033[2m", "\033[1m", "\033[38;5;71m", "\033[38;5;167m", "\033[0m")

SCENES = {
    "docs-site": {
        "prompt": "Regenerate the API reference pages from openapi.yaml",
        "steps": [("Read", "openapi.yaml", "Read 1,284 lines"),
                  ("Update", "docs/reference/auth.md", "Updated with 42 additions"),
                  ("Update", "docs/reference/users.md", "Updated with 31 additions")],
        "ask": ("Bash command", "npm run build:docs", "Build the docs site to check the new pages"),
        "done": "Regenerated 14 reference pages. `npm run build:docs` passes with no broken links.",
    },
    "api-server": {
        "prompt": "Add rate limiting to the /login route",
        "steps": [("Read", "src/routes/login.ts", "Read 88 lines"),
                  ("Write", "src/middleware/rate-limit.ts", "Wrote 46 lines"),
                  ("Bash", "npm test -- login", "6 passed")],
        "done": "Added a token-bucket limiter (5 tries per minute per IP) to /login. All 6 login tests pass.",
    },
    "data-pipeline": {
        "prompt": "Backfill last week's events and tell me when it's safe to deploy",
        "steps": [("Bash", "python backfill.py --since 7d", "Running in the background")],
        "answered": "The backfill is running in the background (about 4 minutes). It's safe to deploy now; "
                    "the new columns are nullable.",
        "done": "Backfill finished: 1.2M events, 0 errors. Safe to deploy.",
    },
    "blog": {
        "prompt": "Fix the typos in the October post",
        "steps": [("Update", "posts/2026-10-notes.md", "Updated with 5 changes")],
        "done": "Fixed 5 typos. No other changes.",
    },
    "mobile-app": {
        "prompt": "Bump the iOS deployment target to 17 and fix the warnings",
        "steps": [("Update", "ios/Project.xcconfig", "Updated with 1 change"),
                  ("Bash", "xcodebuild -scheme App build", "Build succeeded, 0 warnings")],
        "done": "Deployment target is now iOS 17. The build is clean: 0 warnings.",
    },
    "notes": {
        "prompt": "",
        "steps": [],
        "done": "",
    },
}

SPIN = "·✢✳✶✻✽"


def box(lines, width, color=GRAY):
    out = [f"{color}╭{'─' * (width - 2)}╮{RESET}"]
    for text, style in lines:
        pad = width - 4 - visible_len(text)
        out.append(f"{color}│{RESET} {style}{text}{RESET}{' ' * max(pad, 0)} {color}│{RESET}")
    out.append(f"{color}╰{'─' * (width - 2)}╯{RESET}")
    return out


def visible_len(s):
    # strip ANSI color codes; every glyph used here is single-width
    return len(re.sub(r"\033\[[0-9;]*m", "", s))


def render(name, state, tick):
    scene = SCENES[name]
    cols = min(os.get_terminal_size().columns, 92)
    w = cols - 2
    out = []
    out += box([(f"{ORANGE}✻{RESET}{BOLD} Welcome to Claude Code", ""),
                ("", ""),
                (f"  cwd: ~/projects/{name}", GRAY)], w, ORANGE)
    out.append("")
    if not scene["prompt"]:   # a session that has just started: empty input box only
        out += box([("> ", "")], w)
        return "\033[H\033[2J" + "\r\n".join(out)
    out.append(f"{GRAY}>{RESET} {scene['prompt']}")
    out.append("")
    shown = scene["steps"] if state != "working" else scene["steps"][: 1 + tick // 12 % len(scene["steps"])]
    for tool, arg, result in shown:
        out.append(f"{GREEN}⏺{RESET} {BOLD}{tool}{RESET}({arg})")
        out.append(f"  {GRAY}⎿  {result}{RESET}")
    out.append("")
    if state == "working":
        out.append(f"{ORANGE}{SPIN[tick % len(SPIN)]} Working… {RESET}{GRAY}({8 + tick // 4}s · esc to interrupt){RESET}")
    elif state == "waiting":
        title, cmd, why = scene["ask"]
        out += box([(title, BOLD), ("", ""), (f"  {cmd}", ""), (f"  {why}", GRAY), ("", ""),
                    ("Do you want to proceed?", ""), (f"{ORANGE}❯{RESET} 1. Yes", ""),
                    ("  2. No, and tell Claude what to do differently", GRAY)], w, RED)
    elif state == "approved":
        title, cmd, _ = scene["ask"]
        out.append(f"{GREEN}⏺{RESET} {BOLD}Bash{RESET}({cmd})")
        out.append(f"  {GRAY}⎿  Running…{RESET}")
        out.append("")
        out.append(f"{ORANGE}{SPIN[tick % len(SPIN)]} Working… {RESET}{GRAY}(esc to interrupt){RESET}")
    elif state in ("done", "idle"):
        out.append(f"{GREEN}⏺{RESET} {scene.get('done', '')}")
    elif state == "answered":
        out.append(f"{GREEN}⏺{RESET} {scene.get('answered', '')}")
        out.append("")
        out.append(f"{GRAY}  ⎿  1 background task running{RESET}")
    out.append("")
    out += box([("> ", "")], w)
    return "\033[H\033[2J" + "\r\n".join(out)


def main():
    name, state_dir = sys.argv[1], sys.argv[2]
    path = os.path.join(state_dir, name)
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    tty.setcbreak(fd)
    sys.stdout.write("\033[?25l")  # hide the cursor
    last, tick = None, 0
    try:
        while True:
            try:
                state = open(path).read().strip()
            except OSError:
                state = "working"
            animated = state in ("working", "approved")
            if state != last or animated:
                sys.stdout.write(render(name, state, tick))
                sys.stdout.flush()
                last = state
            if select.select([sys.stdin], [], [], 0.25)[0]:
                if sys.stdin.read(1) == "1" and state == "waiting":
                    with open(path, "w") as f:
                        f.write("approved")
            tick += 1
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)


if __name__ == "__main__":
    main()
