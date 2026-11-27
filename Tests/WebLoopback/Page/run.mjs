// Runs the web loopback in headless Chromium: serves this folder (with the
// PackageToJS output linked in as Package/ and communication_webrtc.js
// copied beside it) on a loopback port of its own, opens the page, and
// waits for the Swift side to set `webLoopback`. Exits 0 on "ok".
//
//   node run.mjs   (Playwright's Chromium installed)
import { chromium } from "playwright";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL(".", import.meta.url));
const types = { ".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".wasm": "application/wasm", ".json": "application/json" };
const server = createServer(async (request, response) => {
  const path = normalize(join(root, decodeURIComponent(new URL(request.url, "http://x").pathname)));
  if (!path.startsWith(root)) return response.writeHead(403).end();
  try {
    const body = await readFile(path.endsWith("/") ? join(path, "index.html") : path);
    response.writeHead(200, { "content-type": types[extname(path)] ?? "application/octet-stream" }).end(body);
  } catch {
    response.writeHead(404).end();
  }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const url = `http://127.0.0.1:${server.address().port}/index.html`;

const browser = await chromium.launch();
let outcome = "timed out";
try {
  const page = await browser.newPage();
  page.on("console", (message) => console.log(`page: ${message.text()}`));
  page.on("pageerror", (error) => console.log(`page error: ${error.message}`));
  await page.goto(url);
  outcome = await page.waitForFunction(() => window.webLoopback, null, { timeout: 60000 }).then((h) => h.jsonValue()).catch(() => "timed out");
} finally {
  await browser.close();
  server.close();
}
console.log(`web loopback: ${outcome}`);
process.exit(outcome === "ok" ? 0 : 1);
