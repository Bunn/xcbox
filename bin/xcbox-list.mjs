#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const [, , stateHome, boxHomeRoot, metadataRoot] = process.argv;
if (!stateHome || !boxHomeRoot || !metadataRoot) {
  console.error("xcbox-list: state, box-home, and metadata paths are required");
  process.exit(2);
}

const input = await new Promise((resolve) => {
  let value = "";
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", (chunk) => value += chunk);
  process.stdin.on("end", () => resolve(value));
});

let inventory;
try {
  const parsed = JSON.parse(input || "[]");
  inventory = Array.isArray(parsed) ? parsed : [parsed];
} catch {
  console.error("xcbox: container returned invalid inventory JSON");
  process.exit(1);
}

function canonical(value) {
  try { return fs.realpathSync.native(value); }
  catch { return path.resolve(value); }
}

function safeFile(file) {
  try {
    const stat = fs.lstatSync(file);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch { return false; }
}

function readProject(name) {
  const file = path.join(metadataRoot, name);
  if (!safeFile(file)) return "";
  try { return fs.readFileSync(file, "utf8").split(/\r?\n/, 1)[0]; }
  catch { return ""; }
}

function retainedHomeNames() {
  try {
    return fs.readdirSync(boxHomeRoot, { withFileTypes: true })
      .filter((entry) => entry.isDirectory() && entry.name.startsWith("xcbox-") && safeFile(path.join(boxHomeRoot, entry.name, ".xcbox-home-version")))
      .map((entry) => entry.name);
  } catch { return []; }
}

function clean(value) {
  return String(value || "—").replace(/[\x00-\x1f\x7f]/g, "?");
}

const rows = new Map();
const canonicalStateHome = canonical(stateHome);

for (const item of inventory) {
  const name = item?.id || item?.configuration?.id || "";
  if (!name.startsWith("xcbox-")) continue;
  const rootMount = item?.configuration?.mounts?.find((mount) => mount.destination === "/root")?.source || "";
  const expectedHome = path.join(boxHomeRoot, name);
  let home = "missing";
  if (rootMount && canonical(rootMount) === canonical(expectedHome)) home = "isolated";
  else if (rootMount && canonical(rootMount) === canonicalStateHome) home = "legacy/shared";
  else if (rootMount) home = "mismatch";

  rows.set(name, {
    state: item?.status?.state || "unknown",
    home,
    name,
    project: readProject(name) || item?.configuration?.initProcess?.workingDirectory || "",
    rootMount,
  });
}

for (const name of retainedHomeNames()) {
  if (rows.has(name)) continue;
  rows.set(name, { state: "retained", home: "isolated", name, project: readProject(name), rootMount: "" });
}

const result = [...rows.values()].sort((left, right) => left.name.localeCompare(right.name));
if (result.length === 0) {
  console.log("xcbox: no boxes or retained homes");
  process.exit(0);
}

const headers = ["STATE", "HOME", "BOX", "PROJECT"];
const values = result.map((row) => [clean(row.state), clean(row.home), clean(row.name), clean(row.project)]);
const widths = headers.map((header, index) => Math.max(header.length, ...values.map((row) => row[index].length)));
const format = (row) => row.map((value, index) => index === row.length - 1 ? value : value.padEnd(widths[index])).join("  ");

console.log(format(headers));
for (const row of values) console.log(format(row));

for (const row of result.filter((entry) => entry.home === "legacy/shared" || entry.home === "mismatch" || entry.home === "missing")) {
  console.log(`WARNING: ${clean(row.name)} uses ${clean(row.home)} /root${row.rootMount ? ` from ${clean(row.rootMount)}` : ""}; recreate it before use.`);
}
