#!/usr/bin/env python3
"""Turns build/demo/raw.mov + events.json into the site's demo videos, one per language.

  post.py            writes site/media/demo-en.mp4, demo-zh.mp4 and their posters

What it adds on top of the raw screen recording:
  - blurs the menu bar's other status icons and the clock (only the Claude Lights dot stays sharp)
  - step captions (English or Chinese), rendered by headless Chrome in the site's fonts
  - a 3x inset of the light bar with a ring on the light that just changed, and a "from -> to" label
  - the app's own notification sound (Ping) wherever a banner appears; screen recording has no audio

ffmpeg runs from the linuxserver/ffmpeg Docker image, so every path it touches lives under $HOME.
"""
import json
import os
import pathlib
import shutil
import subprocess

REPO = pathlib.Path(__file__).resolve().parents[2]
WORK = REPO / "build" / "demo"
OVER = WORK / "overlays"
MEDIA = REPO / "site" / "media"
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SYSTEM_PING = pathlib.Path("/System/Library/Sounds/Ping.aiff")
PING = WORK / "Ping.aiff"   # copied next to the recording so the Docker ffmpeg can read it

SCALE = 2            # raw.mov is Retina: 2 px per point; the output is 1 px per point
OUT_W, OUT_H = 1512, 982
CHANGE_LAG = 0.45    # the poller shows a registry change about this long after it is written
MOUSE_LAG = 0.1

LABELS = {
    "en": {"working": "working", "done": "done ✓", "waiting": "needs you !"},
    "zh": {"working": "工作中", "done": "已完成 ✓", "waiting": "等你处理 !"},
}

# (start, end, english, chinese) in video seconds, before lag correction is applied by `at()`.
def captions(ev):
    t = {f"{e['kind']}:{e.get('session', '')}:{e.get('to', '')}": e["t"] for e in ev}
    c = lambda key: t[key] + CHANGE_LAG
    m = lambda key: t[key] + MOUSE_LAG
    end = t["end::"] + 1.5
    return [
        (0.0, c("change:api-server:done"),
         "You're working in the browser. Each Claude Code session is one light on the bar.",
         "你在浏览器里工作。每个 Claude Code 会话，是灯条上的一盏灯。"),
        (c("change:api-server:done"), c("change:docs-site:waiting"),
         "api-server finished: the light turns green, with a banner and a ping.",
         "api-server 做完了：灯变绿，弹出通知，叮一声。"),
        (c("change:docs-site:waiting"), m("hover:docs-site:"),
         "docs-site needs your permission: its light turns red.",
         "docs-site 需要你批准权限：灯变红。"),
        (m("hover:docs-site:"), m("click:docs-site:"),
         "Hover a light to see what it's waiting for.",
         "鼠标停在灯上，就能看到它在等什么。"),
        (m("click:docs-site:"), m("approve:docs-site:"),
         "Click it: Terminal comes forward, already on docs-site's tmux window.",
         "点一下：Terminal 跳到前面，tmux 已经切到 docs-site 的窗口。"),
        (m("approve:docs-site:"), c("change:mobile-app:done"),
         "Approve the command, and the light goes back to working.",
         "批准命令后，灯变回工作中。"),
        (c("change:mobile-app:done"), m("click:mobile-app:"),
         "mobile-app runs in its own Terminal window, not in tmux. It just finished.",
         "mobile-app 没用 tmux，单独开在一个 Terminal 窗口里。它刚做完。"),
        (m("click:mobile-app:"), c("change:docs-site:done"),
         "Click its light: that exact window comes forward.",
         "点它的灯：直接跳到那个窗口。"),
        (c("change:docs-site:done"), m("menu::"),
         "docs-site finishes while you're looking elsewhere.",
         "你在看别处时，docs-site 也做完了。"),
        (m("menu::"), end,
         "The menu bar dot lists every session.",
         "菜单栏的小点，列出所有会话。"),
    ]


def highlights(ev, dots, bar):
    """One inset per state change: (start, end, session, to, dot_x_in_bar_points)."""
    out = []
    for e in ev:
        if e["kind"] == "change":
            start = e["t"] + CHANGE_LAG
            out.append((start, start + 3.2, e["session"], e["to"], dots[e["session"]][0] - bar["x"]))
    return out


def beeps(ev):
    # Only first notifications of a session show a banner (a repeat id updates silently), and only
    # those play the sound in the real app. docs-site's second change ("done") is the repeat here.
    seen, out = set(), []
    for e in ev:
        if e["kind"] == "change" and e.get("notify"):
            if e["session"] not in seen:
                out.append(e["t"] + CHANGE_LAG)
            seen.add(e["session"])
    return out


# ---------------------------------------------------------------- overlay rendering

PAGE = """<!doctype html><html><head><meta charset="utf-8">
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500&family=JetBrains+Mono&display=swap">
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/lxgw-wenkai-webfont@1.7.0/lxgwwenkai-regular.css">
<style>
html,body{{margin:0;background:transparent;width:{w}px;height:{h}px;overflow:hidden}}
body{{display:flex;align-items:center;justify-content:center;font-family:'Inter','LXGW WenKai',sans-serif}}
{css}
</style></head><body>{body}</body></html>"""

CAPTION_CSS = """
.cap{display:flex;align-items:center;gap:14px;max-width:1100px;padding:12px 20px;background:#fafafa;
  color:#171717;border:1px solid #171717;border-radius:999px;font-size:21px;line-height:1.35;
  box-shadow:0 0 0 6px rgba(250,250,250,.55)}
.n{font:13px 'JetBrains Mono',monospace;color:#8f8f8f;letter-spacing:.04em}
"""

LABEL_CSS = """
.lab{display:inline-flex;align-items:center;gap:10px;padding:5px 12px;background:#fafafa;color:#171717;
  border:1px solid #171717;border-radius:999px;font:15px 'JetBrains Mono','LXGW WenKai',monospace}
.lab b{font-weight:500}
.arrow{color:#8f8f8f}
"""


def render(name, w, h, css, body):
    html = OVER / f"{name}.html"
    png = OVER / f"{name}.png"
    html.write_text(PAGE.format(w=w, h=h, css=css, body=body))
    subprocess.run([CHROME, "--headless=new", "--hide-scrollbars", "--force-device-scale-factor=1",
                    "--default-background-color=00000000", "--virtual-time-budget=4000",
                    f"--window-size={w},{h}", f"--screenshot={png}", html.as_uri()],
                   check=True, capture_output=True)
    return png


def ring_png():
    svg = OVER / "ring.svg"
    svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="64" height="64">'
                   '<circle cx="32" cy="32" r="27" fill="none" stroke="#171717" stroke-width="2.5"/>'
                   '<circle cx="32" cy="32" r="30.5" fill="none" stroke="#fafafa" stroke-width="2"/></svg>')
    return render("ring", 64, 64, "", f'<img src="{svg.as_uri()}">')


# ---------------------------------------------------------------- ffmpeg

def ffmpeg(*args):
    home = str(pathlib.Path.home())
    if shutil.which("ffmpeg") and not open(shutil.which("ffmpeg"), "rb").read(2) == b"#!":
        cmd = ["ffmpeg", *args]
    else:   # the machine's ffmpeg is a Docker wrapper that insists on a TTY; call the image directly
        cmd = ["docker", "run", "--rm", "-v", f"{home}:{home}", "-w", str(WORK), "linuxserver/ffmpeg", *args]
    subprocess.run(cmd, check=True)


def build(lang, data):
    ev, dots, bar, si = data["events"], data["dots"], data["bar"], data["status_item"]
    caps, hls, pings = captions(ev), highlights(ev, dots, bar), beeps(ev)
    duration = ev[-1]["t"] + 1.5

    inputs = ["-i", str(WORK / "scaled.mp4")]

    def add_input(*args):
        inputs.extend(args)
        return inputs.count("-i") - 1

    # Overlay images are single-frame inputs; eof_action=repeat holds them (looping them as streams
    # makes ffmpeg buffer every one and runs out of memory).
    # Inset geometry (output pixels): the bar, cropped from the frame and scaled 3x, below the bar.
    k = 3
    bx, by, bw, bh = int(bar["x"]), int(bar["y"]), int(bar["w"]), int(bar["h"])
    iw, ih = bw * k, bh * k
    ix, iy = bx + bw // 2 - iw // 2, by + bh + 34
    # Menu bar: blur everything right of the app menus, then paste the Claude Lights dot back sharp.
    mb_h, left_edge = 33, 620
    si_x0, si_x1 = int(si["x"]) - 4, int(si["x"] + si["w"]) + 4

    f = ["[0:v]split=3[base][forblur][forsharp]",
         f"[forblur]crop={OUT_W - left_edge}:{mb_h}:{left_edge}:0,boxblur=lr=8:lp=4:cr=6:cp=4[mb]",
         f"[base][mb]overlay={left_edge}:0[b0]",
         "[forsharp]split[forsi][forinset]",
         f"[forsi]crop={si_x1 - si_x0}:{mb_h}:{si_x0}:0[sharp]",
         f"[b0][sharp]overlay={si_x0}:0[v0]",
         f"[forinset]crop={bw}:{bh}:{bx}:{by},scale={iw}:{ih}:flags=lanczos,"
         f"pad={iw + 2}:{ih + 2}:1:1:color=0x171717,split={len(hls)}" + "".join(f"[ins{j}]" for j in range(len(hls)))]
    last = "v0"

    ring = add_input("-i", str(ring_png()))
    f.append(f"[{ring}:v]split={len(hls)}" + "".join(f"[ring{j}]" for j in range(len(hls))))
    L = LABELS[lang]
    for j, (start, end, session, to, dotx) in enumerate(hls):
        on = f"eof_action=repeat:enable='between(t,{start:.2f},{end:.2f})'"
        frm = {"done": "working", "waiting": "working", "working": "waiting"}[to]
        lab = add_input("-i", str(render(
            f"lab-{lang}-{j}", 520, 44, LABEL_CSS,
            f'<div class="lab"><b>{session}</b><span>{L[frm]}</span><span class="arrow">→</span><span>{L[to]}</span></div>')))
        cx, cy = ix + 1 + dotx * k, iy + 1 + ih / 2
        f.append(f"[{last}][ins{j}]overlay={ix}:{iy}:{on}[h{j}a]")
        f.append(f"[h{j}a][ring{j}]overlay={int(cx - 32)}:{int(cy - 32)}:{on}[h{j}b]")
        f.append(f"[h{j}b][{lab}:v]overlay={bx + bw // 2 - 260}:{iy + ih + 12}:{on}[h{j}]")
        last = f"h{j}"

    for i, (start, end, en, zh) in enumerate(caps):
        png = render(f"cap-{lang}-{i}", 1200, 90, CAPTION_CSS,
                     f'<div class="cap"><span class="n">{i + 1:02d}</span><span>{en if lang == "en" else zh}</span></div>')
        c = add_input("-i", str(png))
        f.append(f"[{last}][{c}:v]overlay={(OUT_W - 1200) // 2}:{OUT_H - 120}:"
                 f"eof_action=repeat:enable='between(t,{start:.2f},{end:.2f})'[c{i}]")
        last = f"c{i}"

    mix = []
    for n, p in enumerate(pings):
        a = add_input("-i", str(PING))
        ms = int(p * 1000)
        f.append(f"[{a}:a]aresample=48000,adelay={ms}|{ms},volume=0.8[p{n}]")
        mix.append(f"[p{n}]")
    f.append(f"anullsrc=r=48000:cl=stereo,atrim=0:{duration:.2f}[sil]")
    f.append(f"[sil]{''.join(mix)}amix=inputs={len(mix) + 1}:normalize=0,atrim=0:{duration:.2f}[aout]")

    out = MEDIA / f"demo-{lang}.mp4"
    ffmpeg("-hide_banner", "-loglevel", "error", "-y", *inputs, "-filter_complex", ";".join(f),
           "-map", f"[{last}]", "-map", "[aout]", "-t", f"{duration:.2f}", "-r", "30",
           "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "20", "-preset", "medium", "-threads", "2",
           "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", str(out))
    poster = MEDIA / f"demo-{lang}-poster.jpg"
    ffmpeg("-hide_banner", "-loglevel", "error", "-y", "-ss", f"{caps[1][0] + 1.2:.2f}", "-i", str(out),
           "-frames:v", "1", "-q:v", "3", str(poster))
    print(f"wrote {out.relative_to(REPO)} and {poster.relative_to(REPO)}")


def main():
    OVER.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(SYSTEM_PING, PING)
    # Downscale the Retina recording once; composing at full size runs Docker's 2 GB VM out of memory.
    ffmpeg("-hide_banner", "-loglevel", "error", "-y", "-i", str(WORK / "raw.mov"),
           "-vf", f"scale={OUT_W}:{OUT_H}:flags=lanczos,setsar=1,fps=30", "-c:v", "libx264", "-crf", "12",
           "-preset", "fast", "-an", str(WORK / "scaled.mp4"))
    MEDIA.mkdir(parents=True, exist_ok=True)
    data = json.loads((WORK / "events.json").read_text())
    for lang in ("en", "zh"):
        build(lang, data)
    jump_clip(data)


def jump_clip(data):
    """A short, caption-free loop of the click-to-jump moment for the features grid."""
    t = {f"{e['kind']}:{e.get('session', '')}": e["t"] for e in data["events"]}
    start = t["hover:docs-site"] + 0.4
    end = t["approve:docs-site"] + 0.2
    out = MEDIA / "jump.mp4"
    ffmpeg("-hide_banner", "-loglevel", "error", "-y", "-ss", f"{start:.2f}", "-to", f"{end:.2f}",
           "-i", str(WORK / "scaled.mp4"), "-vf", "crop=1080:720:130:40,scale=720:-2:flags=lanczos",
           "-an", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "22", "-movflags", "+faststart", str(out))
    print(f"wrote {out.relative_to(REPO)}")


if __name__ == "__main__":
    main()
