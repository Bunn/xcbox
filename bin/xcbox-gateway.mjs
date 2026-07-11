#!/usr/bin/env node
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { isInitializeRequest } from '@modelcontextprotocol/sdk/types.js';

const port = Number.parseInt(process.env.GATEWAY_PORT ?? '8765', 10);
const host = process.env.GATEWAY_BIND_HOST ?? '127.0.0.1';
const endpoint = process.env.MCP_ENDPOINT ?? '/mcp';
const healthEndpoint = '/healthz';
const containerHost = process.env.GATEWAY_HOST ?? 'host.container.internal';
const xcodebuildmcp = process.env.XCBOX_XCODEBUILDMCP_BIN;
const maxBodyBytes = 10 * 1024 * 1024;
const allowedHosts = new Set([`127.0.0.1:${port}`, `localhost:${port}`, `${containerHost}:${port}`]);

if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error(`Invalid GATEWAY_PORT: ${process.env.GATEWAY_PORT}`);
if (!xcodebuildmcp) throw new Error('XCBOX_XCODEBUILDMCP_BIN is required');

const sessions = new Map();
const provisionalSessions = new Set();
let shuttingDown = false;

function log(message) {
  process.stderr.write(`[xcbox-gateway] ${message}\n`);
}

function sendJsonError(res, status, code, message) {
  if (res.headersSent) return res.end();
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify({ jsonrpc: '2.0', error: { code, message }, id: null }));
}

function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    let body = '';
    let size = 0;
    let tooLarge = false;
    req.setEncoding('utf8');
    req.on('data', chunk => {
      size += Buffer.byteLength(chunk);
      if (size > maxBodyBytes) {
        tooLarge = true;
        reject(new Error('Request body exceeds 10 MiB'));
        return;
      }
      if (!tooLarge) body += chunk;
    });
    req.on('end', () => {
      try { resolve(JSON.parse(body)); }
      catch { reject(new Error('Invalid JSON')); }
    });
    req.on('error', reject);
  });
}

async function createSession() {
  const session = {
    id: null,
    child: null,
    childExited: false,
    closed: false,
    sendChain: Promise.resolve(),
    transport: null,
    killTimer: null,
  };

  const transport = new StreamableHTTPServerTransport({
    sessionIdGenerator: randomUUID,
    enableDnsRebindingProtection: true,
    allowedHosts: [...allowedHosts],
    onsessioninitialized: sessionId => {
      session.id = sessionId;
      provisionalSessions.delete(session);
      sessions.set(sessionId, session);
    },
    onsessionclosed: () => closeSession(session),
  });
  session.transport = transport;
  provisionalSessions.add(session);

  const child = spawn(xcodebuildmcp, ['mcp'], {
    env: process.env,
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  session.child = child;

  let stdoutBuffer = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', chunk => {
    stdoutBuffer += chunk;
    const lines = stdoutBuffer.split(/\r?\n/);
    stdoutBuffer = lines.pop() ?? '';
    for (const line of lines) {
      if (!line.trim()) continue;
      let message;
      try { message = JSON.parse(line); }
      catch {
        log(`ignored non-JSON child output: ${line}`);
        continue;
      }
      session.sendChain = session.sendChain
        .then(() => transport.send(message))
        .catch(error => {
          log(`transport send failed for session ${session.id ?? 'initializing'}: ${error.message}`);
          void transport.close().catch(() => closeSession(session));
        });
    }
  });
  child.stderr.on('data', chunk => process.stderr.write(chunk));
  child.stdin.on('error', error => {
    if (!session.closed) log(`child stdin failed for session ${session.id ?? 'initializing'}: ${error.message}`);
  });
  child.once('error', error => {
    log(`could not start XcodeBuildMCP: ${error.message}`);
    void transport.close().catch(() => closeSession(session));
  });
  child.once('exit', (code, signal) => {
    session.childExited = true;
    if (session.killTimer) clearTimeout(session.killTimer);
    if (!session.closed) {
      log(`XcodeBuildMCP session ${session.id ?? 'initializing'} exited (code ${code}, signal ${signal})`);
      void transport.close();
    }
  });

  transport.onmessage = message => {
    if (!child.stdin.writable) {
      transport.onerror?.(new Error('XcodeBuildMCP stdin is not writable'));
      return;
    }
    child.stdin.write(`${JSON.stringify(message)}\n`);
  };
  transport.onerror = error => log(`session ${session.id ?? 'initializing'} transport error: ${error.message}`);
  transport.onclose = () => closeSession(session);
  await transport.start();
  return session;
}

function closeSession(session) {
  if (session.closed) return;
  session.closed = true;
  provisionalSessions.delete(session);
  if (session.id) sessions.delete(session.id);
  if (!session.childExited && session.child) {
    session.child.kill('SIGTERM');
    session.killTimer = setTimeout(() => {
      if (!session.childExited) session.child.kill('SIGKILL');
    }, 1500);
    session.killTimer.unref();
  }
}

async function handleMcpRequest(req, res) {
  const sessionId = req.headers['mcp-session-id'];

  if (req.method === 'POST') {
    const accept = req.headers.accept ?? '';
    const contentType = req.headers['content-type'] ?? '';
    if (!accept.includes('application/json') || !accept.includes('text/event-stream')) {
      sendJsonError(res, 406, -32000, 'Client must accept application/json and text/event-stream');
      return;
    }
    if (!contentType.includes('application/json')) {
      sendJsonError(res, 415, -32000, 'Content-Type must be application/json');
      return;
    }
    let body;
    try { body = await readJsonBody(req); }
    catch (error) {
      sendJsonError(res, error.message.includes('10 MiB') ? 413 : 400, -32700, error.message);
      return;
    }

    let session;
    if (sessionId) {
      session = sessions.get(sessionId);
      if (!session) {
        sendJsonError(res, 404, -32001, 'Session not found');
        return;
      }
    } else if (isInitializeRequest(body)) {
      session = await createSession();
    } else {
      sendJsonError(res, 400, -32000, 'Mcp-Session-Id header is required');
      return;
    }

    try {
      await session.transport.handleRequest(req, res, body);
      if (!sessionId && !session.transport.sessionId) {
        await session.transport.close();
        closeSession(session);
      }
    } catch (error) {
      log(`POST ${endpoint} failed: ${error.stack ?? error.message}`);
      sendJsonError(res, 500, -32603, 'Internal gateway error');
      await session.transport.close().catch(() => {});
      closeSession(session);
    }
    return;
  }

  if (req.method === 'GET' || req.method === 'DELETE') {
    if (!sessionId || !sessions.has(sessionId)) {
      sendJsonError(res, sessionId ? 404 : 400, sessionId ? -32001 : -32000, sessionId ? 'Session not found' : 'Mcp-Session-Id header is required');
      return;
    }
    const session = sessions.get(sessionId);
    try { await session.transport.handleRequest(req, res); }
    catch (error) {
      log(`${req.method} ${endpoint} failed: ${error.stack ?? error.message}`);
      sendJsonError(res, 500, -32603, 'Internal gateway error');
    }
    return;
  }

  res.writeHead(405, { allow: 'GET, POST, DELETE' });
  res.end();
}

const server = createServer(async (req, res) => {
  const pathname = (req.url ?? '/').split('?', 1)[0];
  if (pathname === healthEndpoint && req.method === 'GET') {
    res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('ok');
    return;
  }
  if (pathname !== endpoint) {
    res.writeHead(404);
    res.end();
    return;
  }
  if (!allowedHosts.has(req.headers.host ?? '')) {
    sendJsonError(res, 403, -32000, `Invalid Host header: ${req.headers.host ?? '(missing)'}`);
    return;
  }
  try { await handleMcpRequest(req, res); }
  catch (error) {
    log(`unhandled request error: ${error.stack ?? error.message}`);
    sendJsonError(res, 500, -32603, 'Internal gateway error');
  }
});

server.on('clientError', (_error, socket) => socket.end('HTTP/1.1 400 Bad Request\r\n\r\n'));
server.listen(port, host, () => log(`listening on http://${host}:${port}${endpoint}`));

function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  log(`received ${signal}; closing ${sessions.size + provisionalSessions.size} session(s)`);
  for (const session of [...sessions.values(), ...provisionalSessions]) {
    void session.transport.close().catch(() => {});
    closeSession(session);
  }
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 2000).unref();
}

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => shutdown(signal));
