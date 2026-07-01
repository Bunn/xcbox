// bin/mcp-call.js — minimal MCP-over-HTTP client for the STATEFUL streamable-HTTP
// gateway (supergateway --stateful). Opens ONE session (initialize +
// notifications/initialized), runs the given JSON-RPC calls in order within that
// session (so tool state like session_set_defaults carries between them, exactly
// as a real MCP client sees it), prints each call's `result` as one JSON line,
// then terminates the session. Exits 1 on transport / JSON-RPC / tool (isError) error.
//
// Usage: node mcp-call.js <baseUrl> <callsJSON>
//   callsJSON = a JSON array of { "method": <string>, "params"?: <object> }.
// Works both as `node mcp-call.js URL CALLS` and `node - URL CALLS < mcp-call.js`
// (argv[2]=URL, argv[3]=CALLS in both).
const [, , base, callsRaw] = process.argv;
const calls = JSON.parse(callsRaw);

// streamableHttp frames responses as SSE: lines beginning "data: <json>".
function parseSSE(text, id) {
  const datas = text.split(/\r?\n/).filter((l) => l.startsWith("data:")).map((l) => l.slice(5).trim());
  const payloads = (datas.length ? datas : [text])
    .map((d) => { try { return JSON.parse(d); } catch { return null; } })
    .filter(Boolean);
  return payloads.find((p) => p.id === id) || payloads[payloads.length - 1] || null;
}

function post(sid, msg) {
  const headers = { "Accept": "application/json, text/event-stream", "Content-Type": "application/json" };
  if (sid) headers["mcp-session-id"] = sid;
  return fetch(base, { method: "POST", headers, body: JSON.stringify(msg) });
}

(async () => {
  // 1. initialize — no session id yet; the server assigns one via the response header.
  const initRes = await post(null, { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "xcbox-harness", version: "0" } } });
  const sid = initRes.headers.get("mcp-session-id");
  const initMsg = parseSSE(await initRes.text(), 1);
  if (!initMsg || initMsg.error) { console.error("initialize failed: " + JSON.stringify(initMsg && initMsg.error)); process.exit(1); }
  // 2. notifications/initialized — required before regular requests (a notification: no id).
  await (await post(sid, { jsonrpc: "2.0", method: "notifications/initialized", params: {} })).text();
  // 3. run the requested calls in order, sharing this session.
  let id = 1;
  for (const c of calls) {
    id += 1;
    const res = await post(sid, { jsonrpc: "2.0", id, method: c.method, params: c.params || {} });
    const msg = parseSSE(await res.text(), id);
    if (!msg) { console.error("no JSON-RPC payload for " + c.method); process.exit(1); }
    if (msg.error) { console.error("JSON-RPC error (" + c.method + "): " + JSON.stringify(msg.error)); process.exit(1); }
    if (msg.result && msg.result.isError) { console.error("MCP tool error (" + c.method + "): " + JSON.stringify(msg.result)); process.exit(1); }
    console.log(JSON.stringify(msg.result));
  }
  // 4. best-effort session teardown so we don't leak sessions on the stateful server.
  try { if (sid) await fetch(base, { method: "DELETE", headers: { "mcp-session-id": sid } }); } catch { /* ignore */ }
})().catch((e) => { console.error(e.message); process.exit(1); });
