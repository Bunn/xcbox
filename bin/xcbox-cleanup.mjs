#!/usr/bin/env node
import fs from "node:fs";
import path from "node:path";

const [, , boxHomeRoot, metadataRoot] = process.argv;
if (!boxHomeRoot || !metadataRoot) {
  console.error("xcbox-cleanup: box-home and metadata paths are required");
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

const validName = (name) => /^xcbox-[a-z0-9][a-z0-9._-]*$/.test(name);
const safeFile = (file) => {
  try {
    const stat = fs.lstatSync(file);
    return stat.isFile() && !stat.isSymbolicLink();
  } catch { return false; }
};
const safeHome = (name) => safeFile(path.join(boxHomeRoot, name, ".xcbox-home-version"));
const clean = (value) => String(value || "").replace(/[\x00-\x1f\x7f]/g, "?");

const containers = new Map();
for (const item of inventory) {
  const name = item?.id || item?.configuration?.id || "";
  if (!validName(name)) continue;
  containers.set(name, item?.status?.state === "running");
}

let metadataNames = [];
try {
  metadataNames = fs.readdirSync(metadataRoot, { withFileTypes: true })
    .filter((entry) => entry.isFile() && !entry.name.endsWith(".agent") && validName(entry.name))
    .map((entry) => entry.name);
} catch { /* an absent metadata root has nothing to prune */ }

const rows = [];
for (const name of metadataNames) {
  const metadata = path.join(metadataRoot, name);
  if (!safeFile(metadata)) continue;
  let project = "";
  try { project = fs.readFileSync(metadata, "utf8").split(/\r?\n/, 1)[0]; }
  catch { continue; }
  if (!path.isAbsolute(project) || fs.existsSync(project)) continue;

  rows.push({
    action: containers.get(name) ? "SKIP" : "REMOVE",
    name,
    project: clean(project),
    container: containers.has(name),
    home: safeHome(name),
  });
}

rows.sort((left, right) => left.name.localeCompare(right.name));
for (const row of rows) {
  const artifacts = [row.container && "container", row.home && "home", "metadata"].filter(Boolean).join("+");
  process.stdout.write(`${row.action}\t${row.name}\t${artifacts}\t${row.project}\n`);
}
