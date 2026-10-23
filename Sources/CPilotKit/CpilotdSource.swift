// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The small helper CPilot installs on a server when "keep sessions running while I am away" is on.
/// It is a single Node.js file with no dependencies and no network port; CPilot reaches it over SSH.
public enum Cpilotd {
    public static let version = 1
    public static let source = #"""
#!/usr/bin/env node
// cpilotd keeps agent processes running on this machine and lets CPilot attach to them, detach, and attach again.
// It has no network port: CPilot reaches it over SSH, so your SSH keys are the only credential.
//
//   cpilotd version
//   cpilotd start <id> --cwd <dir> -- <command> [args...]   run an agent in the background
//   cpilotd attach <id> [--from N]                         replay output from line N, then stream; stdin goes to the agent
//   cpilotd status <id>                                    {running, exit, lines}
//   cpilotd list                                           every session on this machine
//   cpilotd stop <id>                                      stop the agent
//   cpilotd gc                                             remove sessions that ended more than a week ago
import fs from 'node:fs';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const VERSION = 1;
const ROOT = process.env.CPILOTD_HOME || path.join(os.homedir(), '.cpilot', 'sessions');
const safe = (id) => id.replace(/[^A-Za-z0-9_.-]/g, '_');
const dir = (id) => path.join(ROOT, safe(id));
const file = (id, name) => path.join(dir(id), name);

function sockPath(id) {
  const p = file(id, 'sock');
  return p.length < 100 ? p : path.join(os.tmpdir(), 'cpd-' + crypto.createHash('sha1').update(id).digest('hex').slice(0, 16) + '.sock');
}
const readJSON = (p) => { try { return JSON.parse(fs.readFileSync(p, 'utf8')); } catch { return null; } };
const alive = (pid) => { try { process.kill(pid, 0); return true; } catch { return false; } };
const lineCount = (id) => { try { const t = fs.readFileSync(file(id, 'out.log'), 'utf8'); return t ? t.split('\n').length - 1 : 0; } catch { return 0; } };
const say = (o) => process.stdout.write(JSON.stringify(o) + '\n');

function state(id) {
  const meta = readJSON(file(id, 'meta.json'));
  if (!meta) return null;
  const status = readJSON(file(id, 'status.json'));
  const pid = readJSON(file(id, 'pid.json'));
  const running = !status && !!pid && alive(pid.supervisor);
  return { id, cwd: meta.cwd, running, exit: status ? status.exit : null, signal: status ? status.signal : null, error: status ? status.error : null, lines: lineCount(id) };
}

const [cmd, ...rest] = process.argv.slice(2);

if (cmd === 'version') {
  console.log('cpilotd ' + VERSION);
} else if (cmd === 'start') {
  const id = rest[0];
  const cwdAt = rest.indexOf('--cwd'), sep = rest.indexOf('--');
  if (!id || sep < 0 || sep + 1 >= rest.length) { console.error('usage: cpilotd start <id> --cwd <dir> -- <command> [args]'); process.exit(2); }
  const cwd = cwdAt >= 0 ? rest[cwdAt + 1] : process.cwd();
  const s = state(id);
  if (s && s.running) { say({ ok: true, already: true }); process.exit(0); }
  fs.rmSync(dir(id), { recursive: true, force: true });
  fs.mkdirSync(dir(id), { recursive: true, mode: 0o700 });
  fs.writeFileSync(file(id, 'meta.json'), JSON.stringify({ id, cwd, command: rest[sep + 1], args: rest.slice(sep + 2), started: Date.now() }), { mode: 0o600 });
  const sup = spawn(process.execPath, [fileURLToPath(import.meta.url), 'supervise', id], { detached: true, stdio: 'ignore', env: process.env });
  sup.unref();
  const t0 = Date.now();
  const wait = () => {
    // A command that does not exist reports its failure a moment after the socket is up, so give it that moment before saying ok.
    if (fs.existsSync(file(id, 'status.json')) || (fs.existsSync(sockPath(id)) && Date.now() - t0 > 500)) { const st = state(id); say(st && st.error ? { ok: false, error: st.error } : { ok: true }); process.exit(0); }
    if (Date.now() - t0 > 8000) { say({ ok: false, error: 'The agent did not start in time.' }); process.exit(1); }
    setTimeout(wait, 50);
  };
  wait();
} else if (cmd === 'supervise') {
  const id = rest[0];
  const meta = readJSON(file(id, 'meta.json'));
  const out = fs.openSync(file(id, 'out.log'), 'a', 0o600);
  const err = fs.openSync(file(id, 'err.log'), 'a', 0o600);
  let finished = false;
  let client = null;
  const finish = (status) => {
    if (finished) return; finished = true;
    fs.writeFileSync(file(id, 'status.json'), JSON.stringify({ ...status, ended: Date.now() }));
    try { fs.unlinkSync(sockPath(id)); } catch {}
    if (client) client.end();
    setTimeout(() => process.exit(0), 200);
  };
  let child;
  try {
    child = spawn(meta.command, meta.args, { cwd: meta.cwd, stdio: ['pipe', 'pipe', 'pipe'], env: process.env });
  } catch (e) { finish({ exit: null, error: String(e.message || e) }); }
  if (child) {
    fs.writeFileSync(file(id, 'pid.json'), JSON.stringify({ supervisor: process.pid, agent: child.pid }));
    let buf = '';
    child.stdout.on('data', (d) => {
      buf += d.toString('utf8');
      let i;
      while ((i = buf.indexOf('\n')) >= 0) {
        const line = buf.slice(0, i); buf = buf.slice(i + 1);
        fs.writeSync(out, line + '\n');
        if (client) client.write(line + '\n');
      }
    });
    child.stderr.on('data', (d) => { try { fs.writeSync(err, d); } catch {} });
    child.stdin.on('error', () => {});
    child.on('error', (e) => finish({ exit: null, error: e.code === 'ENOENT' ? meta.command + ' was not found on this machine.' : String(e.message || e) }));
    child.on('close', (code, signal) => finish({ exit: code, signal }));
    const server = net.createServer((sock) => {
      let head = '';
      sock.on('error', () => {});
      sock.on('data', function first(d) {
        head += d.toString('utf8');
        const i = head.indexOf('\n');
        if (i < 0) return;
        sock.removeListener('data', first);
        let from = 0;
        try { from = Math.max(0, JSON.parse(head.slice(0, i)).from || 0); } catch {}
        const more = head.slice(i + 1);
        // Replay and go live in one step, so nothing is lost or repeated.
        let text = '';
        try { text = fs.readFileSync(file(id, 'out.log'), 'utf8'); } catch {}
        const all = text ? text.split('\n').slice(0, -1) : [];
        if (client && client !== sock) client.destroy();
        client = sock;
        if (all.length > from) sock.write(all.slice(from).join('\n') + '\n');
        let inbuf = more;
        const flush = () => { let j; while ((j = inbuf.indexOf('\n')) >= 0) { const l = inbuf.slice(0, j + 1); inbuf = inbuf.slice(j + 1); if (!finished) child.stdin.write(l); } };
        flush();
        sock.on('data', (c) => { inbuf += c.toString('utf8'); flush(); });
        sock.on('close', () => { if (client === sock) client = null; });
      });
    });
    try { fs.unlinkSync(sockPath(id)); } catch {}
    server.listen(sockPath(id), () => { try { fs.chmodSync(sockPath(id), 0o600); } catch {} });
    const stop = () => { try { child.kill('SIGTERM'); } catch {} setTimeout(() => { try { child.kill('SIGKILL'); } catch {} }, 3000); };
    process.on('SIGTERM', stop);
    process.on('SIGINT', stop);
  }
} else if (cmd === 'attach') {
  const id = rest[0];
  const fromAt = rest.indexOf('--from');
  const from = fromAt >= 0 ? parseInt(rest[fromAt + 1], 10) || 0 : 0;
  const st = state(id);
  if (!st) { console.error('No such session.'); process.exit(3); }
  if (!st.running) {
    // The agent already finished: replay what is left, then stop.
    try { const t = fs.readFileSync(file(id, 'out.log'), 'utf8'); const all = t ? t.split('\n').slice(0, -1) : []; if (all.length > from) process.stdout.write(all.slice(from).join('\n') + '\n'); } catch {}
    process.exit(0);
  }
  const sock = net.connect(sockPath(id));
  sock.on('error', (e) => { console.error('Could not attach: ' + e.message); process.exit(3); });
  sock.on('connect', () => { sock.write(JSON.stringify({ attach: true, from }) + '\n'); process.stdin.pipe(sock); });
  sock.pipe(process.stdout);
  sock.on('close', () => process.exit(0));
  process.stdin.on('end', () => sock.end());
} else if (cmd === 'status') {
  const st = state(rest[0]);
  if (!st) { say({ running: false, missing: true }); } else say(st);
} else if (cmd === 'list') {
  let ids = [];
  try { ids = fs.readdirSync(ROOT); } catch {}
  say(ids.map((i) => state(i)).filter(Boolean));
} else if (cmd === 'stop') {
  const pid = readJSON(file(rest[0], 'pid.json'));
  if (pid && alive(pid.supervisor)) { try { process.kill(pid.supervisor, 'SIGTERM'); } catch {} }
  say({ ok: true });
} else if (cmd === 'gc') {
  let n = 0;
  try {
    for (const i of fs.readdirSync(ROOT)) {
      const s = readJSON(file(i, 'status.json'));
      if (s && Date.now() - s.ended > 7 * 86400000) { fs.rmSync(dir(i), { recursive: true, force: true }); n++; }
    }
  } catch {}
  say({ removed: n });
} else {
  console.error('usage: cpilotd version | start | attach | status | list | stop | gc');
  process.exit(2);
}
"""#
}
