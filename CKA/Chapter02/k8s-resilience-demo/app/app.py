#!/usr/bin/env python3
"""
K8s Resilience Demo app.

Serves a colourful page showing:
  - the container name
  - the node (hostname) the request landed on
  - the pod name
  - the time this container started

Also exposes a /leak endpoint that allocates memory on purpose so you can
trigger an OOMKilled event for Demo 1.
"""

import os
import socket
import hashlib
from datetime import datetime, timezone

from flask import Flask, jsonify, request

app = Flask(__name__)

# Captured once, when this process (container) starts.
START_TIME = datetime.now(timezone.utc)

# Injected via the Kubernetes Downward API (see k8s/deployment.yaml).
CONTAINER_NAME = os.getenv("CONTAINER_NAME", "web")
NODE_NAME = os.getenv("NODE_NAME", socket.gethostname())
POD_NAME = os.getenv("POD_NAME", socket.gethostname())
POD_NAMESPACE = os.getenv("POD_NAMESPACE", "default")
POD_IP = os.getenv("POD_IP", "unknown")

# Somewhere to stash allocated memory so the OOM demo actually leaks.
_MEMORY_HOG = []


def color_from(text: str) -> str:
    """Deterministically turn any string into a nice HSL colour."""
    h = int(hashlib.sha256(text.encode()).hexdigest(), 16)
    hue = h % 360
    return f"hsl({hue}, 78%, 58%)"


def gradient_from(seed: str) -> tuple[str, str, str]:
    """Two-stop gradient + an accent, all derived from a seed string."""
    h = int(hashlib.sha256(seed.encode()).hexdigest(), 16)
    hue1 = h % 360
    hue2 = (hue1 + 55) % 360
    accent = (hue1 + 180) % 360
    return (
        f"hsl({hue1}, 80%, 55%)",
        f"hsl({hue2}, 80%, 45%)",
        f"hsl({accent}, 85%, 62%)",
    )


PAGE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>K8s Resilience Demo</title>
<style>
  :root {{
    --c1: {c1};
    --c2: {c2};
    --accent: {accent};
  }}
  * {{ box-sizing: border-box; margin: 0; padding: 0; }}
  html, body {{ height: 100%; }}
  body {{
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: linear-gradient(135deg, var(--c1) 0%, var(--c2) 100%);
    background-attachment: fixed;
    color: #fff;
    display: flex;
    align-items: center;
    justify-content: center;
    padding: 24px;
    min-height: 100vh;
    overflow-x: hidden;
  }}
  .blobs {{ position: fixed; inset: 0; z-index: 0; overflow: hidden; }}
  .blob {{
    position: absolute; border-radius: 50%; filter: blur(60px); opacity: .45;
    animation: float 14s ease-in-out infinite;
  }}
  .blob.a {{ width: 340px; height: 340px; background: var(--accent); top: -80px; left: -60px; }}
  .blob.b {{ width: 420px; height: 420px; background: #ffffff55; bottom: -120px; right: -80px; animation-delay: -6s; }}
  @keyframes float {{
    0%,100% {{ transform: translate(0,0) scale(1); }}
    50%     {{ transform: translate(30px,-30px) scale(1.08); }}
  }}
  .card {{
    position: relative; z-index: 1;
    width: 100%; max-width: 560px;
    background: rgba(255,255,255,0.14);
    border: 1px solid rgba(255,255,255,0.35);
    backdrop-filter: blur(16px);
    -webkit-backdrop-filter: blur(16px);
    border-radius: 24px;
    padding: 36px;
    box-shadow: 0 24px 60px rgba(0,0,0,0.28);
  }}
  .badge {{
    display: inline-flex; align-items: center; gap: 8px;
    background: rgba(0,0,0,0.22); border-radius: 999px;
    padding: 6px 14px; font-size: 13px; font-weight: 600; letter-spacing: .3px;
    margin-bottom: 18px;
  }}
  .dot {{ width: 9px; height: 9px; border-radius: 50%; background: #38ff9b; box-shadow: 0 0 10px #38ff9b; }}
  h1 {{ font-size: 26px; line-height: 1.25; margin-bottom: 4px; }}
  .sub {{ opacity: .85; font-size: 14px; margin-bottom: 24px; }}
  .grid {{ display: grid; gap: 12px; }}
  .row {{
    display: flex; align-items: center; justify-content: space-between; gap: 16px;
    background: rgba(0,0,0,0.20); border-radius: 14px; padding: 14px 16px;
  }}
  .row .k {{ font-size: 12px; text-transform: uppercase; letter-spacing: 1px; opacity: .8; }}
  .row .v {{
    font-family: "SF Mono", ui-monospace, Menlo, Consolas, monospace;
    font-size: 14px; font-weight: 600; text-align: right; word-break: break-all;
  }}
  .node .v {{ color: var(--accent); font-size: 16px; }}
  .foot {{ margin-top: 22px; display: flex; gap: 12px; flex-wrap: wrap; }}
  button, a.btn {{
    flex: 1; min-width: 150px; text-align: center; text-decoration: none;
    border: none; cursor: pointer; border-radius: 12px; padding: 12px 14px;
    font-size: 14px; font-weight: 700; color: #1a1a1a;
    background: #ffffff; transition: transform .12s ease, opacity .12s ease;
  }}
  button:hover, a.btn:hover {{ transform: translateY(-2px); }}
  .danger {{ background: #ff6b6b; color: #fff; }}
  .uptime {{ font-variant-numeric: tabular-nums; }}
  .hint {{ margin-top: 14px; font-size: 12px; opacity: .75; text-align: center; }}
</style>
</head>
<body>
  <div class="blobs"><div class="blob a"></div><div class="blob b"></div></div>
  <div class="card">
    <span class="badge"><span class="dot"></span> Serving your request</span>
    <h1>Kubernetes Resilience Demo</h1>
    <div class="sub">Refresh or hit the LoadBalancer again — watch the node & colour change.</div>

    <div class="grid">
      <div class="row"><span class="k">Container</span><span class="v">{container}</span></div>
      <div class="row node"><span class="k">Node (hostname)</span><span class="v">{node}</span></div>
      <div class="row"><span class="k">Pod</span><span class="v">{pod}</span></div>
      <div class="row"><span class="k">Pod IP</span><span class="v">{pod_ip}</span></div>
      <div class="row"><span class="k">Namespace</span><span class="v">{namespace}</span></div>
      <div class="row"><span class="k">Started at</span><span class="v">{started}</span></div>
      <div class="row"><span class="k">Uptime</span><span class="v uptime" id="uptime">…</span></div>
    </div>

    <div class="foot">
      <button onclick="location.reload()">↻ Refresh</button>
      <a class="btn danger" href="/leak?mb=40">💥 Leak 40&nbsp;MB (OOM)</a>
    </div>
    <div class="hint">Tip: keep clicking “Leak” to push past the memory limit and trigger an OOMKilled restart.</div>
  </div>

<script>
  const start = new Date("{started_iso}").getTime();
  function tick() {{
    const s = Math.floor((Date.now() - start) / 1000);
    const h = String(Math.floor(s/3600)).padStart(2,'0');
    const m = String(Math.floor((s%3600)/60)).padStart(2,'0');
    const sec = String(s%60).padStart(2,'0');
    document.getElementById('uptime').textContent = `${{h}}:${{m}}:${{sec}}`;
  }}
  tick(); setInterval(tick, 1000);
</script>
</body>
</html>"""


@app.route("/")
def index():
    c1, c2, accent = gradient_from(POD_NAME)
    return PAGE.format(
        c1=c1,
        c2=c2,
        accent=accent,
        container=CONTAINER_NAME,
        node=NODE_NAME,
        pod=POD_NAME,
        pod_ip=POD_IP,
        namespace=POD_NAMESPACE,
        started=START_TIME.strftime("%Y-%m-%d %H:%M:%S UTC"),
        started_iso=START_TIME.isoformat(),
    )


@app.route("/api")
def api():
    """Machine-readable version of the same info."""
    return jsonify(
        container=CONTAINER_NAME,
        node=NODE_NAME,
        pod=POD_NAME,
        pod_ip=POD_IP,
        namespace=POD_NAMESPACE,
        started=START_TIME.isoformat(),
        color=color_from(POD_NAME),
    )


@app.route("/leak")
def leak():
    """Allocate memory on purpose to push the container toward its limit."""
    mb = int(request.args.get("mb", 40))
    # 1 MB blob per iteration; kept in a module-level list so it never frees.
    for _ in range(mb):
        _MEMORY_HOG.append(bytearray(1024 * 1024))
    held = len(_MEMORY_HOG)
    return (
        f"<body style='font-family:monospace;background:#111;color:#0f0;padding:40px'>"
        f"Allocated {mb} MB. Now holding ~{held} MB total on {POD_NAME}.<br><br>"
        f"Keep hitting this endpoint to exceed the memory limit and get OOMKilled.<br><br>"
        f"<a style='color:#6cf' href='/leak?mb={mb}'>Leak {mb} more MB »</a> &nbsp; "
        f"<a style='color:#6cf' href='/'>« Back</a></body>"
    )


@app.route("/healthz")
def healthz():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
