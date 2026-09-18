// Same-origin: nginx proxies /api/ to the backend service.
const API = "/api";
const $ = (id) => document.getElementById(id);
const medals = { 1: "\uD83E\uDD47", 2: "\uD83E\uDD48", 3: "\uD83E\uDD49" };
const EMOJI = { rock: "\uD83E\uDEA8", paper: "\uD83D\uDCC4", scissors: "\u2702\uFE0F" };
const VERDICT = { win: "YOU WIN", lose: "YOU LOSE", draw: "DRAW" };

// per-browser session tally (all-time totals come from MySQL)
const session = { win: 0, lose: 0, draw: 0 };

async function j(url, opts) {
  const res = await fetch(url, opts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
  return data;
}

const fmt = (n) => Number(n).toLocaleString("en-US");
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

async function loadStats() {
  try {
    const s = await j(`${API}/stats`);
    $("stat-rounds").textContent = fmt(s.rounds);
    $("stat-players").textContent = fmt(s.players);
    $("stat-champ").textContent = s.champion ? s.champion.name : "--";
  } catch (_) {}
}

function renderBoard(rows) {
  const board = $("board");
  if (!rows.length) {
    board.innerHTML = '<li class="empty">No players yet. Be the first to throw.</li>';
    return;
  }
  board.innerHTML = rows
    .map((r, i) => {
      const rank = i + 1;
      const badge = medals[rank] || rank;
      const cls = rank <= 3 ? `top${rank}` : "";
      return `<li class="${cls}">
        <span class="rank">${badge}</span>
        <span class="who">${esc(r.name)}<small>${r.wins}W &middot; ${r.losses}L &middot; ${r.draws}D</small></span>
        <span class="pts">${fmt(r.points)}</span>
      </li>`;
    })
    .join("");
}

async function loadBoard(query) {
  try {
    const url = query ? `${API}/players/search?q=${encodeURIComponent(query)}` : `${API}/leaderboard`;
    renderBoard(await j(url));
  } catch (e) {
    $("board").innerHTML = `<li class="empty">Could not reach the API: ${esc(e.message)}</li>`;
  }
}

async function refresh() {
  await Promise.all([loadStats(), loadBoard($("query").value.trim())]);
}

function showRound(you, cpu, result) {
  $("you-emoji").textContent = EMOJI[you];
  $("cpu-emoji").textContent = EMOJI[cpu];
  const v = $("verdict");
  v.textContent = VERDICT[result];
  v.className = "verdict " + result;
  const arena = $("versus");
  arena.classList.remove("flash");
  void arena.offsetWidth; // restart the animation
  arena.classList.add("flash");
}

async function play(move) {
  const name = $("name").value.trim();
  const msg = $("msg");
  if (!name) {
    msg.className = "msg err";
    msg.textContent = "Enter a handle first.";
    $("name").focus();
    return;
  }
  msg.textContent = "";
  try {
    const r = await j(`${API}/play`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ name, move }),
    });
    showRound(r.you, r.cpu, r.result);
    session[r.result]++;
    $("session").textContent =
      `${name}: ${session.win}W / ${session.lose}L / ${session.draw}D this session ` +
      `\u00b7 all-time ${r.stats.points} pts`;
    await refresh();
  } catch (e) {
    msg.className = "msg err";
    msg.textContent = e.message;
  }
}

document.querySelectorAll(".move").forEach((btn) =>
  btn.addEventListener("click", () => play(btn.dataset.move))
);

let t;
$("query").addEventListener("input", (e) => {
  clearTimeout(t);
  t = setTimeout(() => loadBoard(e.target.value.trim()), 250);
});
$("clear").addEventListener("click", () => {
  $("query").value = "";
  loadBoard("");
});

refresh();
