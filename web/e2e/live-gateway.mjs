import { chromium, webkit } from "@playwright/test";
import fs from "node:fs";

const browserName = process.argv[2];
const url = fs.readFileSync(0, "utf8").trim();
if (!url || !["chromium", "webkit"].includes(browserName)) throw new Error("usage: live-gateway.mjs chromium|webkit; URL is stdin");
const type = browserName === "chromium" ? chromium : webkit;
const browser = await type.launch({ headless: true });
try {
  const page = await browser.newPage();
  await page.goto(url, { waitUntil: "networkidle" });
  await page.getByRole("heading", { name: "Start a session" }).waitFor();
  if (new URL(page.url()).hash) throw new Error("launch fragment was not removed");
  const checks = await page.evaluate(async () => {
    const session = JSON.parse(sessionStorage.getItem("agentland.web-session"));
    const headers = { Authorization: `Bearer ${session.token}` };
    const state = await fetch("/web/state", { cache: "no-store", headers });
    const capabilities = await fetch("/api/v1/capabilities", { cache: "no-store", headers });
    return { state: state.status, capabilities: capabilities.status, hasToken: Boolean(session.token) };
  });
  if (checks.state !== 200 || checks.capabilities !== 200 || !checks.hasToken) throw new Error(`gateway checks failed: ${JSON.stringify(checks)}`);
  const forbidden = await page.evaluate(async () => {
    const session = JSON.parse(sessionStorage.getItem("agentland.web-session"));
    const response = await fetch("/api/v1/providers", { cache: "no-store", headers: { Authorization: `Bearer ${session.token}` } });
    return response.status;
  });
  if (forbidden !== 404) throw new Error(`provider route was available: ${forbidden}`);
  const listener = new URL(page.url());
  const foreign = await page.context().request.get(listener.origin + "/", { headers: { Host: "localhost:" + listener.port } });
  if (foreign.status() !== 403) throw new Error(`foreign host status ${foreign.status()}`);
} finally { await browser.close(); }
