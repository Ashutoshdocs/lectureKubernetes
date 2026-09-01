// Rock Paper Scissors - backend API
// 3-tier practical: browser -> nginx (frontend) -> this API -> MySQL
// The server referees each round, so the result is authoritative before
// it is written to MySQL.

const express = require("express");
const mysql = require("mysql2/promise");

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;

const dbConfig = {
  host: process.env.DB_HOST || "mysql",
  port: Number(process.env.DB_PORT || 3306),
  user: process.env.DB_USER || "arcade",
  password: process.env.DB_PASSWORD || "arcade",
  database: process.env.DB_NAME || "arcadedb",
  waitForConnections: true,
  connectionLimit: 10,
};

let pool;

const MOVES = ["rock", "paper", "scissors"];
const BEATS = { rock: "scissors", paper: "rock", scissors: "paper" };

function judge(player, cpu) {
  if (player === cpu) return "draw";
  return BEATS[player] === cpu ? "win" : "lose";
}

async function initDb(retries = 30) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    try {
      pool = mysql.createPool(dbConfig);
      const conn = await pool.getConnection();
      await conn.query(`
        CREATE TABLE IF NOT EXISTS players (
          id INT AUTO_INCREMENT PRIMARY KEY,
          name VARCHAR(50) NOT NULL UNIQUE,
          wins INT NOT NULL DEFAULT 0,
          losses INT NOT NULL DEFAULT 0,
          draws INT NOT NULL DEFAULT 0,
          updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        )
      `);
      conn.release();
      console.log(`[db] connected and table ready (attempt ${attempt})`);
      return;
    } catch (err) {
      console.log(`[db] not ready (attempt ${attempt}/${retries}): ${err.code || err.message}`);
      await new Promise((r) => setTimeout(r, 3000));
    }
  }
  throw new Error("Could not connect to MySQL after several attempts");
}

// Health check for k8s probes
app.get("/api/health", async (_req, res) => {
  try {
    await pool.query("SELECT 1");
    res.json({ status: "ok" });
  } catch (err) {
    res.status(503).json({ status: "down", error: err.message });
  }
});

// Play one round. Body: { name, move }
app.post("/api/play", async (req, res) => {
  const name = String((req.body && req.body.name) || "").trim().slice(0, 50);
  const move = String((req.body && req.body.move) || "").toLowerCase();

  if (!name) return res.status(400).json({ error: "a player name is required" });
  if (!MOVES.includes(move)) {
    return res.status(400).json({ error: `move must be one of: ${MOVES.join(", ")}` });
  }

  const cpu = MOVES[Math.floor(Math.random() * MOVES.length)];
  const result = judge(move, cpu); // win | lose | draw (player's view)

  const inc = {
    wins: result === "win" ? 1 : 0,
    losses: result === "lose" ? 1 : 0,
    draws: result === "draw" ? 1 : 0,
  };

  try {
    // Upsert: create the player on first play, otherwise add to their tally.
    await pool.query(
      `INSERT INTO players (name, wins, losses, draws)
       VALUES (?, ?, ?, ?)
       ON DUPLICATE KEY UPDATE
         wins = wins + VALUES(wins),
         losses = losses + VALUES(losses),
         draws = draws + VALUES(draws)`,
      [name, inc.wins, inc.losses, inc.draws]
    );

    const [[row]] = await pool.query(
      `SELECT name, wins, losses, draws, (wins*3 + draws) AS points
       FROM players WHERE name = ?`,
      [name]
    );

    res.json({ you: move, cpu, result, stats: row });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Top scorers. points = wins*3 + draws
app.get("/api/leaderboard", async (req, res) => {
  const limit = Math.min(Number(req.query.limit) || 20, 100);
  try {
    const [rows] = await pool.query(
      `SELECT name, wins, losses, draws, (wins*3 + draws) AS points
       FROM players
       ORDER BY points DESC, wins DESC, name ASC
       LIMIT ?`,
      [limit]
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Look up players by name
app.get("/api/players/search", async (req, res) => {
  const q = `%${(req.query.q || "").trim()}%`;
  try {
    const [rows] = await pool.query(
      `SELECT name, wins, losses, draws, (wins*3 + draws) AS points
       FROM players WHERE name LIKE ?
       ORDER BY points DESC LIMIT 50`,
      [q]
    );
    res.json(rows);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Fun aggregate stats straight from MySQL
app.get("/api/stats", async (_req, res) => {
  try {
    const [[totals]] = await pool.query(
      `SELECT COUNT(*) AS players,
              COALESCE(SUM(wins + losses + draws), 0) AS rounds
       FROM players`
    );
    const [[champ]] = await pool.query(
      `SELECT name, (wins*3 + draws) AS points
       FROM players ORDER BY points DESC LIMIT 1`
    );
    res.json({ ...totals, champion: champ || null });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

initDb()
  .then(() => app.listen(PORT, () => console.log(`[api] listening on ${PORT}`)))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });
