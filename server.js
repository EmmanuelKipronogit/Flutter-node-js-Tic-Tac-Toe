require('dotenv').config();
const express = require('express');
const http = require('http');
const cors = require('cors');
const bcrypt = require('bcryptjs');
const jwt = require('jsonwebtoken');
const crypto = require('crypto');
const nodemailer = require('nodemailer');
const fs = require('fs');
const path = require('path');
const { Pool } = require('pg');
const { Server } = require('socket.io');

const PORT = process.env.PORT || 3000;
const isProd = process.env.NODE_ENV === 'production';
const SECRET = process.env.JWT_SECRET || 'dev-secret-change-me';
const ORIGIN = process.env.CORS_ORIGIN || '*';
if (isProd && !process.env.JWT_SECRET) { console.error('JWT_SECRET is required in production'); process.exit(1); }

// ---------- Postgres ----------
const pool = new Pool({
  connectionString: process.env.DATABASE_URL || 'postgres://game:game@localhost:5432/game',
  ssl: process.env.PGSSL === 'true' ? { rejectUnauthorized: false } : undefined,
});
const q = (text, params) => pool.query(text, params);
const migrate = () => q(fs.readFileSync(path.join(__dirname, 'schema.sql'), 'utf8'));
const pubUser = (u) => ({ id: u.id, name: u.name, email: u.email, stats: { wins: u.wins, losses: u.losses, draws: u.draws } });

// ---------- Gmail ----------
const GMAIL_USER = process.env.GMAIL_USER;
const GMAIL_PASS = (process.env.GMAIL_APP_PASSWORD || '').replace(/\s+/g, ''); // Google shows it with spaces
const SMTP_PORT = +process.env.SMTP_PORT || 465;
const mailer = GMAIL_USER && GMAIL_PASS
  ? nodemailer.createTransport({
      host: 'smtp.gmail.com', port: SMTP_PORT, secure: SMTP_PORT === 465,
      auth: { user: GMAIL_USER, pass: GMAIL_PASS },
    })
  : null;

if (mailer) {
  mailer.verify()
    .then(() => console.log('✅ Gmail SMTP ready'))
    .catch((e) => console.error(`❌ Gmail SMTP failed: ${e.message}\n   Check: 2-Step Verification ON, a fresh App Password, GMAIL_USER matches that account, server restarted after editing .env`));
} else {
  console.warn('⚠️  GMAIL_USER / GMAIL_APP_PASSWORD not set – codes will print in this console (dev only)');
}

async function sendCode(email, code) {
  if (!mailer) {
    if (isProd) throw Object.assign(new Error('Email is not configured on the server'), { safe: true });
    return console.log(`[DEV] Code for ${email}: ${code}`);
  }
  try {
    await mailer.sendMail({
      from: `"Tic-Tac-Toe" <${GMAIL_USER}>`,
      to: email,
      subject: `Your login code: ${code}`,
      text: `Your verification code is ${code}. It expires in 10 minutes. If this wasn't you, ignore this email.`,
    });
  } catch (e) {
    console.error('Gmail send failed:', e.message);
    if (process.env.DEV_FALLBACK === 'true') return console.log(`[DEV_FALLBACK] Code for ${email}: ${code}`);
    throw Object.assign(
      new Error(`Could not send verification code (${e.code || 'mail error'}). Check the server's Gmail settings.`),
      { safe: true });
  }
}

// ---------- 2FA challenges (stored in Postgres) ----------
const hashCode = (c) => crypto.createHash('sha256').update(c + SECRET).digest('hex');

async function startChallenge(user, existingId) {
  const code = String(crypto.randomInt(100000, 1000000));
  const id = existingId || crypto.randomUUID();
  await q(
    `insert into login_codes(id,user_id,code_hash,expires_at,attempts,sent_at)
     values($1,$2,$3,now()+interval '10 minutes',0,now())
     on conflict (id) do update set code_hash=$3, expires_at=now()+interval '10 minutes', attempts=0, sent_at=now()`,
    [id, user.id, hashCode(code)]);
  try { await sendCode(user.email, code); }
  catch (e) { if (!existingId) await q('delete from login_codes where id=$1', [id]); throw e; }
  return id;
}
setInterval(() => q('delete from login_codes where expires_at < now()').catch(() => {}), 60000);

const sign = (u) => jwt.sign({ id: u.id }, SECRET, { expiresIn: '7d' });
const wrap = (fn) => (req, res, next) => fn(req, res, next).catch((e) => {
  console.error(e);
  res.status(500).json({ error: isProd && !e.safe ? 'Server error' : e.message });
});

// ---------- HTTP API ----------
const app = express();
app.use(cors({ origin: ORIGIN }));
app.use(express.json());
app.get('/health', (req, res) => res.json({ ok: true }));

app.post('/api/register', wrap(async (req, res) => {
  const { name, email, password } = req.body;
  const mail = String(email || '').trim().toLowerCase();
  if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(mail) || !password || password.length < 6)
    return res.status(400).json({ error: 'Valid email and 6+ character password required' });
  const nm = String(name || mail.split('@')[0]).trim().slice(0, 24);
  const hash = bcrypt.hashSync(password, 10);
  const { rows: [existing] } = await q('select * from users where email=$1', [mail]);
  if (existing && existing.verified) return res.status(409).json({ error: 'Email already registered' });
  const user = existing
    ? (await q('update users set name=$2, hash=$3 where id=$1 returning *', [existing.id, nm, hash])).rows[0]
    : (await q('insert into users(name,email,hash) values($1,$2,$3) returning *', [nm, mail, hash])).rows[0];
  res.json({ challengeId: await startChallenge(user) });
}));

app.post('/api/login', wrap(async (req, res) => {
  const mail = String(req.body.email || '').trim().toLowerCase();
  const { rows: [u] } = await q('select * from users where email=$1 and verified', [mail]);
  if (!u || !bcrypt.compareSync(req.body.password || '', u.hash))
    return res.status(401).json({ error: 'Invalid email or password' });
  res.json({ challengeId: await startChallenge(u) });
}));

app.post('/api/resend', wrap(async (req, res) => {
  const { rows: [ch] } = await q('select * from login_codes where id=$1 and expires_at > now()', [req.body.challengeId]);
  if (!ch) return res.status(400).json({ error: 'Session expired, please start again' });
  if (Date.now() - new Date(ch.sent_at).getTime() < 30000)
    return res.status(429).json({ error: 'Wait 30 seconds before resending' });
  const { rows: [u] } = await q('select * from users where id=$1', [ch.user_id]);
  await startChallenge(u, ch.id);
  res.json({ ok: true });
}));

app.post('/api/verify', wrap(async (req, res) => {
  const { challengeId, code } = req.body;
  const { rows: [ch] } = await q('select * from login_codes where id=$1', [challengeId]);
  if (!ch || new Date(ch.expires_at) < new Date())
    return res.status(400).json({ error: 'Code expired, please start again' });
  if (ch.attempts >= 5) {
    await q('delete from login_codes where id=$1', [ch.id]);
    return res.status(429).json({ error: 'Too many attempts, start again' });
  }
  await q('update login_codes set attempts=attempts+1 where id=$1', [ch.id]);
  const a = Buffer.from(hashCode(String(code || '')), 'hex'), b = Buffer.from(ch.code_hash, 'hex');
  if (!crypto.timingSafeEqual(a, b)) return res.status(401).json({ error: 'Incorrect code' });
  await q('delete from login_codes where id=$1', [ch.id]);
  const { rows: [u] } = await q('update users set verified=true where id=$1 returning *', [ch.user_id]);
  res.json({ token: sign(u), user: pubUser(u) });
}));

const auth = wrap(async (req, res, next) => {
  let id;
  try { id = jwt.verify((req.headers.authorization || '').replace('Bearer ', ''), SECRET).id; }
  catch { return res.status(401).json({ error: 'Not authenticated' }); }
  const { rows: [u] } = await q('select * from users where id=$1 and verified', [id]);
  if (!u) return res.status(401).json({ error: 'Not authenticated' });
  req.user = u;
  next();
});
app.get('/api/me', auth, (req, res) => res.json(pubUser(req.user)));
app.get('/api/leaderboard', auth, wrap(async (req, res) => {
  const { rows } = await q('select name,wins,losses,draws from users where verified order by wins desc, losses asc limit 10');
  res.json(rows);
}));

// ---------- Real-time multiplayer ----------
const server = http.createServer(app);
const io = new Server(server, { cors: { origin: ORIGIN } });
const rooms = new Map();
let queue = [];
const chatLog = [];
const LINES = [[0,1,2],[3,4,5],[6,7,8],[0,3,6],[1,4,7],[2,5,8],[0,4,8],[2,4,6]];

const outcome = (b) => {
  for (const [x, y, z] of LINES) if (b[x] && b[x] === b[y] && b[x] === b[z]) return b[x];
  return b.every(Boolean) ? 'draw' : null;
};
const seat = (s) => ({ id: s.user.id, name: s.user.name, sid: s.id });
const view = (r) => ({
  code: r.code, board: r.board, turn: r.turn, status: r.status, winner: r.winner, note: r.note,
  players: { X: r.players.X && { id: r.players.X.id, name: r.players.X.name },
             O: r.players.O && { id: r.players.O.id, name: r.players.O.name } },
});
const push = (r) => io.to(r.code).emit('state', view(r));
const symOf = (r, s) => (r.players.X?.sid === s.id ? 'X' : r.players.O?.sid === s.id ? 'O' : null);

// lobby: players online + open public games, broadcast to everyone (debounced)
const lobbyView = () => ({
  online: io.of('/').sockets.size,
  rooms: [...rooms.values()].filter((r) => r.status === 'waiting' && r.public)
    .map((r) => ({ code: r.code, host: r.players.X.name })),
});
let lobbyTimer;
const pushLobby = () => { clearTimeout(lobbyTimer); lobbyTimer = setTimeout(() => io.emit('lobby', lobbyView()), 100); };

function newRoom(s, isPublic = false) {
  let code;
  do { code = crypto.randomBytes(3).toString('hex').slice(0, 5).toUpperCase(); } while (rooms.has(code));
  const r = { code, public: isPublic, board: Array(9).fill(''), turn: 'X', status: 'waiting', winner: null, note: '', players: { X: seat(s), O: null } };
  rooms.set(code, r); s.join(code); s.data.code = code;
  return r;
}
function sit(r, sym, s) { r.players[sym] = seat(s); s.join(r.code); s.data.code = r.code; }

function finish(r, w) {
  r.status = 'finished'; r.winner = w;
  const bump = (sym, col) => { const p = r.players[sym]; if (p) q(`update users set ${col}=${col}+1 where id=$1`, [p.id]).catch(console.error); };
  if (w === 'draw') { bump('X', 'draws'); bump('O', 'draws'); }
  else { bump(w, 'wins'); bump(w === 'X' ? 'O' : 'X', 'losses'); }
}

function leave(s) {
  queue = queue.filter((x) => x.id !== s.id);
  const r = rooms.get(s.data.code);
  if (!r) return;
  const sym = symOf(r, s);
  s.leave(r.code); s.data.code = null;
  if (!sym) return;
  const opp = sym === 'X' ? 'O' : 'X';
  if (r.status === 'playing' && r.players[opp]) { r.note = `${r.players[sym].name} left the game`; finish(r, opp); }
  else if (r.players[opp]) r.note = `${r.players[sym].name} left`;
  r.players[sym] = null;
  if ((!r.players.X && !r.players.O) || r.status === 'waiting') rooms.delete(r.code);
  else push(r);
  pushLobby();
}

io.use(async (socket, next) => {
  try {
    const id = jwt.verify(socket.handshake.auth.token, SECRET).id;
    const { rows: [u] } = await q('select id,name from users where id=$1 and verified', [id]);
    if (!u) throw new Error();
    socket.user = u;
    next();
  } catch { next(new Error('unauthorized')); }
});

io.on('connection', (s) => {
  s.emit('chat_history', chatLog);
  pushLobby();

  s.on('create', (opts) => { leave(s); push(newRoom(s, !!(opts && opts.public))); pushLobby(); });

  s.on('join', (code) => {
    leave(s);
    const r = rooms.get(String(code || '').trim().toUpperCase());
    if (!r) return s.emit('error_msg', 'Room not found');
    if (r.players.O || r.status !== 'waiting') return s.emit('error_msg', 'Room is full');
    if (r.players.X.id === s.user.id) return s.emit('error_msg', "You can't join your own room");
    sit(r, 'O', s); r.status = 'playing'; push(r); pushLobby();
  });

  s.on('quick', () => {
    leave(s);
    queue = queue.filter((x) => x.connected);
    const other = queue.shift();
    if (!other) { queue.push(s); return; }
    const r = newRoom(other); sit(r, 'O', s); r.status = 'playing'; push(r); pushLobby();
  });

  s.on('cancel', () => { queue = queue.filter((x) => x.id !== s.id); });

  s.on('move', (i) => {
    const r = rooms.get(s.data.code);
    if (!r || r.status !== 'playing' || !Number.isInteger(i) || i < 0 || i > 8) return;
    const sym = symOf(r, s);
    if (sym !== r.turn || r.board[i]) return;
    r.board[i] = sym;
    const w = outcome(r.board);
    if (w) finish(r, w); else r.turn = sym === 'X' ? 'O' : 'X';
    push(r);
  });

  s.on('rematch', () => {
    const r = rooms.get(s.data.code);
    if (!r || r.status !== 'finished' || !r.players.X || !r.players.O) return;
    [r.players.X, r.players.O] = [r.players.O, r.players.X];
    Object.assign(r, { board: Array(9).fill(''), turn: 'X', status: 'playing', winner: null, note: '' });
    push(r);
  });

  s.on('chat', (text) => {
    const t = String(text || '').trim().slice(0, 200);
    if (!t || Date.now() - (s.data.lastChat || 0) < 500) return;
    s.data.lastChat = Date.now();
    const msg = { name: s.user.name, text: t, t: Date.now() };
    chatLog.push(msg);
    if (chatLog.length > 50) chatLog.shift();
    io.emit('chat', msg);
  });

  s.on('leave', () => leave(s));
  s.on('disconnect', () => { leave(s); pushLobby(); });
});

migrate()
  .then(() => server.listen(PORT, () => console.log(`Game server on http://localhost:${PORT}`)))
  .catch((e) => { console.error('❌ Database connection/migration failed:', e.message, '\n   Is Postgres running and DATABASE_URL correct?'); process.exit(1); });
