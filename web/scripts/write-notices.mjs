import {
  mkdirSync,
  writeFileSync,
  readFileSync,
  readdirSync,
  existsSync,
} from "node:fs";
import { join, basename } from "node:path";
mkdirSync("dist", { recursive: true });
const lock = JSON.parse(readFileSync("package-lock.json", "utf8"));
const root = process.cwd();
const blocks = [];
for (const [key, meta] of Object.entries(lock.packages || {})) {
  if (!key.startsWith("node_modules/") || meta.dev) continue;
  const dir = join(root, key);
  if (!existsSync(join(dir, "package.json"))) continue;
  const pkg = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  const names = readdirSync(dir).filter(
    (n) => /^licen[cs]e(?:[.-]|$)/i.test(n) || /^copying$/i.test(n),
  );
  let text = "";
  for (const name of names) {
    try {
      text = readFileSync(join(dir, name), "utf8");
      if (text) break;
    } catch {}
  }
  blocks.push(
    `Package: ${pkg.name}@${pkg.version}\nLicense: ${typeof pkg.license === "string" ? pkg.license : pkg.license?.type || "See package metadata"}\n${text || "License text was not shipped by this package; see its declared license metadata."}`,
  );
}
blocks.sort();
writeFileSync(
  "dist/THIRD_PARTY_NOTICES.txt",
  `AgentLand Web third-party notices\n\n${blocks.join("\n\n----------------------------------------\n\n")}\n`,
);
