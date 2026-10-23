// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Antigravity command line (`agy`) as an agent. It has no ACP mode of its own and its ACP server is built for 4 KB memory pages
/// (it aborts on a Raspberry Pi 5), so CPilot runs a small Node.js adapter that speaks ACP to CPilot and runs `agy -p` for each message.
/// Sign-in goes through `agy`'s own login (a link to open here, a code to paste back), driven by the adapter through a terminal.
public enum AgyAdapter {
    public static let agentId = "agy"
    public static let name = "Antigravity CLI (agy)"
    /// Bumped whenever `source` changes, so servers that have an older copy are set up again.
    public static let version = 1

    /// The same on this Mac and on a server: everything lives under ~/.cpilot, resolved by the shell that runs it.
    public static var config: AcpAgentConfig {
        AcpAgentConfig(id: agentId, name: name, command: "sh",
                       args: ["-c", "PATH=\"$HOME/.cpilot/node/bin:$PATH\"; export PATH; exec node \"$HOME/.cpilot/agy/adapter.mjs\" \"$@\"", "agy-adapter"])
    }

    static func adapter(_ args: [String]) -> (tool: String, args: [String]) { (config.command, config.args + args) }

    /// Whether the agy command and the current adapter are on the machine, and Node.js is able to run it.
    static let readyProbe = """
    export PATH="$HOME/.cpilot/node/bin:$HOME/.cpilot/bin:$HOME/.local/bin:$PATH"
    command -v agy >/dev/null 2>&1 || exit 1
    grep -q "ADAPTER_VERSION = \(version)$" "$HOME/.cpilot/agy/adapter.mjs" 2>/dev/null || exit 1
    \(Provisioner.nodeProbe)
    """

    static let installScript = """
    export PATH="$HOME/.cpilot/bin:$HOME/.local/bin:$PATH"
    command -v agy >/dev/null 2>&1 && exit 0
    URL=https://antigravity.google/cli/install.sh
    mkdir -p "$HOME/.cpilot/bin" || exit 1
    if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL" | bash -s -- -d "$HOME/.cpilot/bin"
    elif command -v wget >/dev/null 2>&1; then wget -qO- "$URL" | bash -s -- -d "$HOME/.cpilot/bin"
    else echo "Neither curl nor wget is on the machine, so agy could not be downloaded." >&2; exit 1; fi
    [ -x "$HOME/.cpilot/bin/agy" ] || command -v agy >/dev/null 2>&1
    """

    /// Gets `agy` and the adapter onto this Mac (`env` nil) or a server. Node.js comes first when it is missing.
    public static func install(on env: EnvironmentConfig?, progress: @escaping @Sendable (String) -> Void) async throws {
        func fail(_ why: String) -> ShellError { .failed(command: "install", status: 1, stderr: why) }
        progress("Installing Node.js…")
        let node = try await Provisioner.run(RemoteHost.nodeInstallScript, on: env, progress: progress)
        guard node.code == 0 else { throw fail("Node.js could not be installed, and the Antigravity adapter needs it. \(node.last)") }
        progress("Downloading agy…")
        let agy = try await Provisioner.run(installScript, on: env, progress: progress)
        guard agy.code == 0 else { throw fail("agy could not be installed: \(agy.last)") }
        progress("Installing the adapter…")
        let write = "mkdir -p \"$HOME/.cpilot/agy\" && cat > \"$HOME/.cpilot/agy/adapter.mjs\" && chmod 700 \"$HOME/.cpilot/agy/adapter.mjs\""
        let r = try await Exec.with(env) { try await Shell.run("sh", ["-c", write], input: Data(source.utf8), timeout: 30) }
        guard r.ok else { throw fail("The adapter could not be written: \(r.stderr)") }
    }

    public static func isSignedIn(_ env: EnvironmentConfig?) async -> Bool {
        let c = adapter(["check"])
        let r = try? await Exec.with(env) { try await Shell.run(c.tool, c.args, timeout: 40) }
        return r?.ok == true
    }

    /// One sign-in: start it, hand over the link, take the code from the browser page, check it worked.
    public final class Login: @unchecked Sendable {
        public enum Failure: Error, LocalizedError {
            case message(String)
            public var errorDescription: String? { if case .message(let m) = self { m } else { nil } }
        }
        private let env: EnvironmentConfig?
        private var live: LiveProcess?
        private let lock = NSLock()
        private var text = ""
        private var consumed = 0
        public init(_ env: EnvironmentConfig?) { self.env = env }

        /// Events the adapter has printed since the last call, as (event, value).
        private func events() -> [(String, String)] {
            lock.lock(); defer { lock.unlock() }
            let lines = text.components(separatedBy: "\n")
            var out: [(String, String)] = []
            for l in lines.dropLast().dropFirst(consumed) {
                guard let d = l.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let e = o["event"] as? String else { continue }
                out.append((e, (o["url"] as? String) ?? (o["message"] as? String) ?? ""))
            }
            consumed = max(consumed, lines.count - 1)
            return out
        }

        /// Starts agy's sign-in and returns the link to open here.
        public func begin() async throws -> URL {
            let c = adapter(["login"])
            let l = try await Exec.with(env) { try Shell.spawn(c.tool, c.args) { [weak self] s in self?.append(s) } }
            live = l
            for _ in 0..<200 {
                for (e, v) in events() {
                    if e == "url", let u = URL(string: v) { return u }
                    if e == "error" { l.terminate(); throw Failure.message(v) }
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            l.terminate()
            throw Failure.message("agy did not give a sign-in link. Check that it is installed there.")
        }

        /// Gives the code the browser page shows to agy and reports whether it is now signed in.
        public func finish(code: String) async throws {
            let c = code.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let live, !c.isEmpty, !c.contains("\n") else { throw Failure.message("Paste the code from the page.") }
            live.send(c + "\n")
            for _ in 0..<180 {
                for (e, v) in events() {
                    if e == "done" { return }
                    if e == "error" { live.terminate(); throw Failure.message(v) }
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            live.terminate()
            throw Failure.message("agy did not finish signing in.")
        }

        public func cancel() { live?.terminate() }
        private func append(_ s: String) { lock.lock(); text += s; lock.unlock() }
    }

    /// ACP on one side, `agy -p --output-format stream-json` on the other. A single Node.js file with no dependencies.
    public static let source = #"""
#!/usr/bin/env node
// ADAPTER_VERSION = 1
// Lets CPilot talk to the Antigravity command line (agy) as an ACP agent.
//
//   adapter.mjs            ACP over stdin/stdout (what CPilot starts)
//   adapter.mjs login      sign in: prints {"event":"url"}, reads the code from stdin, prints {"event":"done"} or {"event":"error"}
//   adapter.mjs check      exit 0 when agy is signed in
//
// The last run's raw agy output is kept in ~/.cpilot/agy/last-run.jsonl, to see what agy said when a reply looks wrong.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import readline from 'node:readline';
import { spawn, execFile } from 'node:child_process';

const HOME = os.homedir();
const DIR = path.join(HOME, '.cpilot', 'agy');
const exists = (p) => { try { fs.accessSync(p, fs.constants.X_OK); return true; } catch { return false; } };
const AGY = process.env.AGY_BIN || [path.join(HOME, '.cpilot', 'bin', 'agy'), path.join(HOME, '.local', 'bin', 'agy')].find(exists) || 'agy';
const strip = (s) => s.replace(/\x1b\[[0-9;?<>=]*[ -\/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][A-Za-z0-9]|\x1b[=>]/g, '');
const say = (o) => process.stdout.write(JSON.stringify(o) + '\n');

// ---- Signed in? true, false, or null when agy is not on this machine ----
function signedIn() {
  return new Promise((resolve) => {
    execFile(AGY, ['models', '--output-format', 'json'], { timeout: 30000, env: process.env }, (err, stdout, stderr) => {
      if (err && err.code === 'ENOENT') return resolve(null);
      const said = strip(String(stdout) + String(stderr));
      resolve(!err && !/sign in|not signed in|log ?in/i.test(said));
    });
  });
}
const MISSING = 'agy is not installed on this machine. Use Set up in Settings → Agents.';

// ---- Sign-in through agy's own login screen, run in a terminal ----
async function login() {
  const inner = `stty cols 2000 rows 50 2>/dev/null; exec "${AGY}"`;
  const args = process.platform === 'darwin' ? ['-q', '/dev/null', 'sh', '-c', inner] : ['-qec', inner, '/dev/null'];
  const p = spawn('script', args, { stdio: ['pipe', 'pipe', 'pipe'], env: { ...process.env, TERM: 'xterm-256color' } });
  let buf = '', picked = false, gaveUrl = false, sentCode = false, finished = false;
  const end = (o, code) => { if (finished) return; finished = true; say(o); try { p.kill('SIGKILL'); } catch {} setTimeout(() => process.exit(code), 100); };
  p.on('error', (e) => end({ event: 'error', message: e.code === 'ENOENT' ? 'The script command is missing on this machine, so agy cannot be signed in from here.' : String(e) }, 1));
  const onData = (d) => {
    buf += strip(String(d));
    if (!picked && /Select login method/.test(buf)) { picked = true; setTimeout(() => p.stdin.write('\r'), 400); }
    if (!gaveUrl) {
      const m = buf.match(/https:\/\/accounts\.google\.com[\s\S]*?(?=─|After authenticating)/);
      if (m && /After authenticating/.test(buf)) {
        gaveUrl = true;
        say({ event: 'url', url: m[0].replace(/\s+/g, '') });
      }
    }
    if (sentCode) {
      const e = buf.match(/Got an error: ([^\n]*)/);
      if (e) end({ event: 'error', message: e[1].trim() }, 1);
    }
  };
  p.stdout.on('data', onData); p.stderr.on('data', onData);
  readline.createInterface({ input: process.stdin }).on('line', async (line) => {
    const code = line.trim();
    if (!code || sentCode || !gaveUrl) return;
    sentCode = true; buf = '';
    for (const ch of code) { p.stdin.write(ch); await new Promise((r) => setTimeout(r, 4)); }
    p.stdin.write('\r');
    for (let i = 0; i < 40 && !finished; i++) {
      await new Promise((r) => setTimeout(r, 1000));
      if (!finished && !/Signing in/.test(buf.slice(-400)) && (await signedIn()) === true) { end({ event: 'done' }, 0); return; }
    }
    end({ event: 'error', message: 'agy did not finish signing in.' }, 1);
  });
  p.on('close', () => { if (!finished) end({ event: 'error', message: 'agy stopped before signing in.' }, 1); });
  setTimeout(() => end({ event: 'error', message: 'Timed out waiting for the sign-in.' }, 1), 10 * 60 * 1000);
}

if (process.argv[2] === 'check') {
  signedIn().then((ok) => { if (ok !== true) console.error(ok === null ? MISSING : 'agy is not signed in.'); process.exit(ok === true ? 0 : 1); });
} else if (process.argv[2] === 'login') {
  login();
} else if (process.argv[2] === 'version') {
  console.log('agy-adapter 1');
} else {
  acp();
}

// ---- ACP ----
function acp() {
  const sessionsFile = path.join(DIR, 'sessions.json');
  const sessions = (() => { try { return JSON.parse(fs.readFileSync(sessionsFile, 'utf8')); } catch { return {}; } })();
  const save = () => { try { fs.mkdirSync(DIR, { recursive: true }); fs.writeFileSync(sessionsFile, JSON.stringify(sessions)); } catch {} };
  const running = new Map();   // session id -> child process

  const reply = (id, result) => say({ jsonrpc: '2.0', id, result });
  const fail = (id, message, code = -32000) => say({ jsonrpc: '2.0', id, error: { code, message } });
  const update = (sessionId, u) => say({ jsonrpc: '2.0', method: 'session/update', params: { sessionId, update: u } });
  const NOT_SIGNED_IN = 'Authentication required: sign in to Antigravity in CPilot (Settings → Agents → Test → Sign in).';

  readline.createInterface({ input: process.stdin }).on('line', async (line) => {
    let m; try { m = JSON.parse(line); } catch { return; }
    if (!m.method) return;
    const p = m.params || {};
    try {
      switch (m.method) {
        case 'initialize':
          return reply(m.id, { protocolVersion: 1, agentInfo: { name: 'agy-adapter', version: '1' }, agentCapabilities: { loadSession: true, promptCapabilities: { image: false } }, authMethods: [] });
        case 'session/new': {
          const ok = await signedIn();
          if (ok === null) return fail(m.id, MISSING);
          if (!ok) return fail(m.id, NOT_SIGNED_IN);
          const id = crypto.randomUUID();
          sessions[id] = { cwd: p.cwd || HOME, conv: null, turns: 0 }; save();
          return reply(m.id, { sessionId: id });
        }
        case 'session/load': {
          const ok = await signedIn();
          if (ok === null) return fail(m.id, MISSING);
          if (!ok) return fail(m.id, NOT_SIGNED_IN);
          sessions[p.sessionId] = { cwd: p.cwd || HOME, conv: null, turns: 0, ...(sessions[p.sessionId] || {}) };
          if (p.cwd) sessions[p.sessionId].cwd = p.cwd;
          save();
          return reply(m.id, {});
        }
        case 'session/prompt': return prompt(m.id, p);
        case 'session/cancel': { const c = running.get(p.sessionId); if (c) { c.cancelled = true; c.kill('SIGTERM'); } return; }
        default: if (m.id !== undefined) fail(m.id, 'Method not supported', -32601);
      }
    } catch (e) { if (m.id !== undefined) fail(m.id, String(e && e.message || e)); }
  });

  const sessionFor = (sid) => sessions[sid] || (sessions[sid] = { cwd: HOME, conv: null, turns: 0 });

  function flagsFor(access) {
    // agy runs without anyone to ask in this mode, so what it may do is decided before it starts.
    if (access === 'fullAccess') return ['--dangerously-skip-permissions'];
    if (access === 'editFiles') return ['--mode', 'accept-edits'];
    return ['--mode', 'plan'];
  }

  function prompt(id, p) {
    const sid = p.sessionId, s = sessionFor(sid);
    const text = (p.prompt || []).filter((b) => b.type === 'text').map((b) => b.text).join('\n\n');
    const args = [`--print=${text}`, '--output-format', 'stream-json', ...flagsFor(process.env.CPILOT_ACCESS)];
    if (s.conv) args.push('--conversation', s.conv); else if (s.turns > 0) args.push('--continue');
    const child = spawn(AGY, args, { cwd: fs.existsSync(s.cwd) ? s.cwd : HOME, stdio: ['ignore', 'pipe', 'pipe'], env: process.env });
    running.set(sid, child);
    let errTail = '', sawResult = false, spoke = false, resultError = null;
    const raw = fs.createWriteStream(path.join(DIR, 'last-run.jsonl'));
    const t = translator(sid, s, () => { spoke = true; });
    child.on('error', (e) => { running.delete(sid); fail(id, e.code === 'ENOENT' ? MISSING : String(e)); });
    child.stderr.on('data', (d) => { errTail = (errTail + String(d)).slice(-4000); raw.write('stderr: ' + String(d)); });
    readline.createInterface({ input: child.stdout }).on('line', (line) => {
      raw.write(line + '\n');
      let e; try { e = JSON.parse(line); } catch { return; }
      if (t.handle(e)) sawResult = true;
      if (e && (e.is_error || e.error) && (e.type === 'result')) resultError = String(e.error?.message || e.error || e.result || 'agy reported an error');
    });
    child.on('close', (code) => {
      raw.end(); running.delete(sid);
      s.turns += 1; save();
      if (child.cancelled) return reply(id, { stopReason: 'cancelled' });
      if (/not signed in|sign in/i.test(strip(errTail)) && !spoke) return fail(id, NOT_SIGNED_IN);
      const agyError = errTail.match(/AGY_ERROR: (\{.*\})/);
      if (resultError || (code !== 0 && !sawResult)) {
        let why = resultError;
        if (!why && agyError) { try { why = JSON.parse(agyError[1]).message; } catch {} }
        if (!why) why = strip(errTail).trim().split('\n').slice(-3).join(' ') || `agy stopped (exit ${code}).`;
        return fail(id, why);
      }
      reply(id, { stopReason: 'end_turn' });
    });
  }

  // Turns agy's stream-json events into ACP updates. Only the shape documented for agy is relied on (init, step_update with a
  // step_type, result); text and tool details are looked for under the usual names so a small change in field names does not blank the chat.
  function translator(sid, s, onSpeak) {
    const TEXT = ['text', 'content', 'response', 'message', 'delta', 'output'];
    const str = (o, keys) => { for (const k of keys) if (o && typeof o[k] === 'string' && o[k]) return o[k]; return ''; };
    const deep = (o, keys, depth = 0) => {
      if (!o || typeof o !== 'object' || depth > 3) return '';
      const own = str(o, keys); if (own) return own;
      for (const v of Object.values(o)) { if (v && typeof v === 'object') { const r = deep(v, keys, depth + 1); if (r) return r; } }
      return '';
    };
    const findConv = (o, depth = 0) => {
      if (!o || typeof o !== 'object' || depth > 4) return '';
      for (const [k, v] of Object.entries(o)) if (/^conversation_?id$/i.test(k) && typeof v === 'string' && v) return v;
      for (const v of Object.values(o)) { const r = findConv(v, depth + 1); if (r) return r; }
      return '';
    };
    const sent = new Map();      // step id -> text already sent
    const tools = new Set();
    let spoke = false;
    const stream = (kind, key, full) => {
      const before = sent.get(key) || '';
      const piece = full.startsWith(before) ? full.slice(before.length) : full;
      sent.set(key, full.startsWith(before) ? full : before + full);
      if (!piece) return;
      spoke = true; onSpeak();
      update(sid, { sessionUpdate: kind, content: { type: 'text', text: piece } });
    };
    const toolKind = (t) => /command|terminal|shell|run|exec/.test(t) ? 'execute' : /edit|write|creat|replace|patch|delete/.test(t) ? 'edit'
      : /search|grep|find/.test(t) ? 'search' : /view|read|list|open|directory/.test(t) ? 'read' : /web|fetch|browse|url/.test(t) ? 'fetch' : 'other';
    return {
      /** Returns true on the final result. */
      handle(e) {
        if (!e || typeof e !== 'object') return false;
        const conv = findConv(e);
        if (conv && s.conv !== conv) { s.conv = conv; save(); }
        const type = String(e.type || e.event || '').toLowerCase();
        if (type === 'result') {
          if (!spoke) { const r = typeof e.result === 'string' ? e.result : deep(e, TEXT); if (r) stream('agent_message_chunk', 'result', r); }
          return true;
        }
        if (type !== 'step_update') return false;
        const step = (e.step && typeof e.step === 'object') ? e.step : e;
        const kindName = String(step.step_type || step.stepType || e.step_type || '').toLowerCase();
        const key = String(step.id ?? step.step_id ?? step.index ?? step.step_index ?? e.step_id ?? e.index ?? kindName);
        const status = String(step.status || e.status || '').toLowerCase();
        if (/user|input|checkpoint|ephemeral|conversation_history/.test(kindName)) return false;
        if (/think|reason|thought/.test(kindName)) { const x = deep(step, TEXT); if (x) stream('agent_thought_chunk', 'think:' + key, x); return false; }
        if (/response|message|answer|text|planner|model/.test(kindName) && !/tool|command|file|search/.test(kindName)) {
          const x = deep(step, TEXT); if (x) stream('agent_message_chunk', 'text:' + key, x); return false;
        }
        const state = /fail|error|denied|cancel/.test(status) ? 'failed' : /done|complete|success|finish/.test(status) ? 'completed' : 'in_progress';
        const title = str(step, ['title', 'description', 'command', 'path', 'name', 'query', 'url']) || deep(step, ['command', 'path', 'query', 'url', 'title']) || kindName || 'Tool';
        const out = deep(step, ['output', 'stdout', 'result', 'text']);
        const content = out ? [{ type: 'content', content: { type: 'text', text: out.slice(0, 4000) } }] : undefined;
        if (!tools.has(key)) { tools.add(key); update(sid, { sessionUpdate: 'tool_call', toolCallId: key, title, kind: toolKind(kindName), status: state, ...(content ? { content } : {}) }); }
        else update(sid, { sessionUpdate: 'tool_call_update', toolCallId: key, title, status: state, ...(content ? { content } : {}) });
        return false;
      },
    };
  }
}
"""#
}
