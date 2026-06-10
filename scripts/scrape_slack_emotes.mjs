#!/usr/bin/env node

import { createHash } from "node:crypto";
import { existsSync } from "node:fs";
import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import readline from "node:readline/promises";

const supportedExtensions = new Set(["png", "jpg", "jpeg", "gif", "webp"]);
const contentTypeExtensions = new Map([
  ["image/png", "png"],
  ["image/jpeg", "jpg"],
  ["image/gif", "gif"],
  ["image/webp", "webp"]
]);

const repoDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const options = parseArgs(process.argv.slice(2));

async function main() {
  if (typeof WebSocket !== "function" || typeof fetch !== "function") {
    throw new Error("this script needs Node 22+ for built-in fetch and WebSocket support");
  }

  const workspaceUrl = slackUrl(options);
  const profileDir = path.resolve(options.profile);
  const downloadDir = path.resolve(options.downloadDir);
  const configPath = path.resolve(options.config);
  const manifestPath = path.resolve(options.manifest || path.join(downloadDir, "manifest.json"));

  await mkdir(profileDir, { recursive: true });
  await mkdir(downloadDir, { recursive: true });

  const browser = await launchBrowser(profileDir);
  const found = new Map();
  const warnings = [];
  const networkRequests = new Map();

  try {
    const pageTarget = await waitForPageTarget(browser.port);
    const cdp = await CdpClient.connect(pageTarget.webSocketDebuggerUrl);

    try {
      await cdp.send("Runtime.enable");
      await cdp.send("Page.enable");
      await cdp.send("Network.enable");
      installNetworkCollectors(cdp, networkRequests, found, warnings);
      console.log(`Opening ${workspaceUrl}`);
      await cdp.send("Page.navigate", { url: workspaceUrl });
      await waitForLocation(cdp);
      await waitForDocument(cdp);

      if (!options.auto) {
        console.log("");
        console.log("If Slack asks you to sign in, finish login in the opened browser.");
        console.log("Make sure the custom emoji list is visible, then press Enter here.");
        const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
        await rl.question("");
        rl.close();
      }

      await sleep(3000);
      await scanPage(cdp, found);
      await scrollAndScan(cdp, found);

      if (found.size === 0) {
        throw new Error("no Slack emoji found; confirm the browser is logged in and the custom emoji page is visible");
      }

      const downloaded = await downloadEmoji(found, cdp, downloadDir, warnings);
      const config = buildConfig(found, downloaded, options, warnings);

      await writeJson(configPath, config);
      await writeJson(manifestPath, {
        generated_at: new Date().toISOString(),
        source: workspaceUrl,
        strategy: "authenticated-browser-session-cdp",
        browser: browser.executable,
        profile: profileDir,
        discovered_count: found.size,
        downloaded_count: Object.keys(downloaded).length,
        config_count: Object.keys(config).length,
        downloaded,
        warnings
      });

      warnings.forEach(warning => console.warn(`warning: ${warning}`));
      console.log(`Discovered ${found.size} Slack emoji entries`);
      console.log(`Downloaded ${Object.keys(downloaded).length} emoji files to ${downloadDir}`);
      console.log(`Wrote ${Object.keys(config).length} Hammerspoon aliases to ${configPath}`);
      console.log(`Wrote manifest to ${manifestPath}`);
    } finally {
      cdp.close();
    }
  } finally {
    if (!options.keepOpen) browser.process.kill();
  }
}

function parseArgs(args) {
  const homeDir = process.env.HOME || repoDir;
  const out = {
    auto: false,
    browser: process.env.BROWSER_PATH || null,
    config: path.join(repoDir, "emotes.generated.json"),
    downloadDir: path.join(repoDir, "slack-emotes"),
    keepOpen: false,
    manifest: null,
    mode: "auto",
    overwrite: true,
    profile: path.join(homeDir, "Library", "Application Support", "webex-emote-paster", "slack-browser-profile"),
    send: false,
    idleRounds: 400,
    maxScrollRounds: 3000,
    progressEvery: 10,
    scrollDelay: 350,
    timeout: 120000,
    url: null,
    workspace: null
  };

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index];
    const next = () => {
      index += 1;
      if (index >= args.length) throw new Error(`${arg} requires a value`);
      return args[index];
    };

    if (arg === "--auto") out.auto = true;
    else if (arg === "--browser") out.browser = next();
    else if (arg === "--config") out.config = next();
    else if (arg === "--download-dir") out.downloadDir = next();
    else if (arg === "--keep-open") out.keepOpen = true;
    else if (arg === "--manifest") out.manifest = next();
    else if (arg === "--idle-rounds") out.idleRounds = Number(next());
    else if (arg === "--max-scroll-rounds") out.maxScrollRounds = Number(next());
    else if (arg === "--mode") out.mode = next();
    else if (arg === "--no-overwrite") out.overwrite = false;
    else if (arg === "--progress-every") out.progressEvery = Number(next());
    else if (arg === "--profile") out.profile = next();
    else if (arg === "--scroll-delay") out.scrollDelay = Number(next());
    else if (arg === "--send") out.send = true;
    else if (arg === "--timeout") out.timeout = Number(next());
    else if (arg === "--url") out.url = next();
    else if (arg === "--workspace") out.workspace = next();
    else if (arg === "-h" || arg === "--help") {
      printHelp();
      process.exit(0);
    } else {
      throw new Error(`unknown option: ${arg}`);
    }
  }

  if (!["auto", "image", "file"].includes(out.mode)) {
    throw new Error("--mode must be auto, image, or file");
  }

  return out;
}

function printHelp() {
  console.log(`Usage:
  node scripts/scrape_slack_emotes.mjs --workspace WORKSPACE [options]
  node scripts/scrape_slack_emotes.mjs --url https://example.slack.com/customize/emoji [options]

Options:
  --workspace NAME       Slack workspace subdomain, e.g. your-workspace
  --url URL              Full Slack custom emoji page URL
  --browser PATH         Chrome-compatible browser executable path
  --download-dir PATH    Directory for downloaded emoji files
  --config PATH          Output Hammerspoon config JSON path
  --manifest PATH        Output manifest path
  --profile PATH         Persistent browser profile directory
  --mode MODE            auto, image, or file
  --send                 Set send=true in generated config
  --auto                 Do not wait for Enter after opening Slack
  --keep-open            Leave the browser open after scraping
  --max-scroll-rounds N  Maximum list scroll attempts (default: 3000)
  --idle-rounds N        Stop after this many no-growth rounds near the end (default: 400)
  --scroll-delay MS      Delay after each scroll step (default: 350)
  --progress-every N     Print progress every N rounds (default: 10)
  --no-overwrite         Reuse existing downloaded files
  --timeout MS           Browser startup/navigation timeout
  -h, --help             Show this help`);
}

function slackUrl(opts) {
  if (opts.url) return opts.url;
  if (opts.workspace) return `https://${opts.workspace.replace(/\.slack\.com$/, "")}.slack.com/customize/emoji`;
  throw new Error("pass --workspace NAME or --url https://workspace.slack.com/customize/emoji");
}

function findBrowser() {
  if (options.browser) {
    if (!existsSync(options.browser)) throw new Error(`browser not found: ${options.browser}`);
    return options.browser;
  }

  const candidates = [
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    "/Applications/Chromium.app/Contents/MacOS/Chromium",
    "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"
  ];

  const found = candidates.find(candidate => existsSync(candidate));
  if (!found) throw new Error("no Chrome-compatible browser found; pass --browser /path/to/browser");
  return found;
}

async function launchBrowser(profileDir) {
  const executable = findBrowser();
  const child = spawn(executable, [
    "--remote-debugging-port=0",
    `--user-data-dir=${profileDir}`,
    "--no-first-run",
    "--no-default-browser-check",
    "about:blank"
  ], { stdio: ["ignore", "ignore", "pipe"] });

  child.on("exit", code => {
    if (code !== null && code !== 0 && !child.killed) {
      console.error(`browser exited with code ${code}`);
    }
  });

  const wsUrl = await waitForDevToolsUrl(child, options.timeout);
  const port = Number(new URL(wsUrl).port);
  console.log(`Using browser: ${executable}`);
  return { executable, process: child, port };
}

function waitForDevToolsUrl(child, timeoutMs) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("timed out waiting for Chrome DevTools endpoint"));
    }, timeoutMs);

    let buffer = "";
    const onData = chunk => {
      buffer += chunk.toString("utf8");
      const match = buffer.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (match) {
        cleanup();
        resolve(match[1]);
      }
    };
    const onExit = code => {
      cleanup();
      reject(new Error(`browser exited before DevTools endpoint was ready; code=${code}`));
    };
    const cleanup = () => {
      clearTimeout(timer);
      child.stderr.off("data", onData);
      child.off("exit", onExit);
    };

    child.stderr.on("data", onData);
    child.on("exit", onExit);
  });
}

async function waitForPageTarget(port) {
  const deadline = Date.now() + options.timeout;
  while (Date.now() < deadline) {
    const targets = await fetchJson(`http://127.0.0.1:${port}/json/list`).catch(() => []);
    const page = targets.find(target => target.type === "page" && target.url?.startsWith("http")) ||
      targets.find(target => target.type === "page" && target.webSocketDebuggerUrl);
    if (page?.webSocketDebuggerUrl) return page;
    await sleep(250);
  }

  throw new Error("timed out waiting for page target");
}

async function fetchJson(url) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`HTTP ${response.status} for ${url}`);
  return response.json();
}

class CdpClient {
  static connect(url) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(url);
      const client = new CdpClient(ws);
      ws.addEventListener("open", () => resolve(client), { once: true });
      ws.addEventListener("error", event => reject(new Error(event.message || "WebSocket error")), { once: true });
    });
  }

  constructor(ws) {
    this.ws = ws;
    this.nextId = 1;
    this.pending = new Map();
    this.handlers = new Map();

    ws.addEventListener("message", event => {
      const data = JSON.parse(event.data);
      if (data.method) {
        const handlers = this.handlers.get(data.method) || [];
        for (const handler of handlers) {
          try {
            handler(data.params || {});
          } catch {
            // Event handlers are best-effort collectors; never break CDP message handling.
          }
        }
        return;
      }

      if (!data.id) return;

      const entry = this.pending.get(data.id);
      if (!entry) return;
      this.pending.delete(data.id);

      if (data.error) entry.reject(new Error(data.error.message || JSON.stringify(data.error)));
      else entry.resolve(data.result);
    });
  }

  send(method, params = {}) {
    const id = this.nextId++;
    this.ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
    });
  }

  async evaluate(expression) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true
    });

    if (result.exceptionDetails) {
      throw new Error(result.exceptionDetails.text || "page evaluation failed");
    }

    return result.result?.value;
  }

  close() {
    this.ws.close();
  }

  on(method, handler) {
    if (!this.handlers.has(method)) this.handlers.set(method, []);
    this.handlers.get(method).push(handler);
  }
}

function installNetworkCollectors(cdp, requests, found, warnings) {
  cdp.on("Network.responseReceived", params => {
    const response = params.response || {};
    const url = response.url || "";
    const contentType = String(response.headers?.["Content-Type"] || response.headers?.["content-type"] || "");
    if (!shouldInspectResponse(url, contentType)) return;

    requests.set(params.requestId, {
      url,
      contentType
    });
  });

  cdp.on("Network.loadingFinished", params => {
    const request = requests.get(params.requestId);
    if (!request) return;
    requests.delete(params.requestId);

    cdp.send("Network.getResponseBody", { requestId: params.requestId })
      .then(result => {
        const body = result.base64Encoded
          ? Buffer.from(result.body, "base64").toString("utf8")
          : result.body;
        const data = JSON.parse(body);
        const before = found.size;
        collectFromJson(data, found, `network:${request.url}`, warnings);
        const added = found.size - before;
        if (added > 0) {
          console.log(`network: +${added} emoji (${found.size} total)`);
        }
      })
      .catch(() => {
        // Some responses are compressed, streaming, opaque, or consumed before CDP can return a body.
      });
  });
}

function shouldInspectResponse(url, contentType) {
  if (contentType.includes("json")) return true;
  return /emoji|customize|admin|edgeapi|api/i.test(url);
}

async function waitForDocument(cdp) {
  const deadline = Date.now() + options.timeout;
  while (Date.now() < deadline) {
    const state = await cdp.evaluate("document.readyState").catch(() => null);
    if (state === "interactive" || state === "complete") return;
    await sleep(250);
  }

  throw new Error("timed out waiting for document to load");
}

async function waitForLocation(cdp) {
  const deadline = Date.now() + options.timeout;
  while (Date.now() < deadline) {
    const href = await cdp.evaluate("location.href").catch(() => "");
    if (href && href !== "about:blank") return;
    await sleep(250);
  }

  throw new Error("timed out waiting for browser navigation");
}

async function scanPage(cdp, found) {
  const records = await cdp.evaluate(`(() => {
    const records = [];

    function cleanName(value) {
      if (!value) return null;
      const match = String(value).match(/:?([A-Za-z0-9][A-Za-z0-9_-]*):?/);
      return match ? match[1] : null;
    }

    for (const img of Array.from(document.querySelectorAll("img"))) {
      const src = img.currentSrc || img.src;
      if (!src || !/emoji|slack-edge/i.test(src)) continue;

      const nearby = img.closest("tr, li, [role='row'], [data-qa], div");
      const name =
        cleanName(img.alt) ||
        cleanName(img.title) ||
        cleanName(img.getAttribute("aria-label")) ||
        cleanName(nearby?.textContent);

      if (name) records.push({ name, urlOrAlias: src, source: "dom" });
    }

    return records;
  })()`);

  for (const record of records || []) addRecord(found, record);
}

async function scrollAndScan(cdp, found) {
  let previousCount = found.size;
  let stableRounds = 0;

  for (let round = 1; round <= options.maxScrollRounds; round += 1) {
    const scrollInfo = await cdp.evaluate(`(() => {
      const scrollables = [
        document.scrollingElement,
        ...Array.from(document.querySelectorAll("*"))
      ]
        .filter(Boolean)
        .filter(node => node.scrollHeight > node.clientHeight + 100)
        .map((node, index) => {
          const before = node.scrollTop;
          const step = Math.max(240, Math.floor(node.clientHeight * 0.85));
          node.scrollTop = Math.min(node.scrollTop + step, node.scrollHeight - node.clientHeight);
          return {
            index,
            before,
            after: node.scrollTop,
            clientHeight: node.clientHeight,
            scrollHeight: node.scrollHeight,
            moved: node.scrollTop !== before,
            remaining: Math.max(0, node.scrollHeight - node.clientHeight - node.scrollTop)
          };
        })
        .sort((left, right) => {
          if (left.moved !== right.moved) return left.moved ? -1 : 1;
          return right.scrollHeight - left.scrollHeight;
        });

      window.scrollBy(0, Math.max(240, Math.floor(window.innerHeight * 0.85)));

      const best = scrollables[0] || {
        moved: false,
        remaining: 0,
        scrollHeight: document.body.scrollHeight,
        clientHeight: window.innerHeight,
        after: window.scrollY
      };

      return {
        moved: scrollables.some(item => item.moved),
        remaining: best.remaining,
        best,
        scrollableCount: scrollables.length
      };
    })()`);

    await cdp.send("Input.dispatchMouseEvent", {
      type: "mouseWheel",
      x: 700,
      y: 500,
      deltaX: 0,
      deltaY: Math.max(600, Number(scrollInfo?.best?.clientHeight || 700))
    }).catch(() => {});

    await sleep(options.scrollDelay);
    await scanPage(cdp, found);

    const added = found.size - previousCount;
    const nearEnd = !scrollInfo?.moved || Number(scrollInfo?.remaining || 0) < 50;

    if (added <= 0 && nearEnd) stableRounds += 1;
    else stableRounds = 0;

    if (added > 0 || round % options.progressEvery === 0) {
      console.log(
        `scroll ${round}/${options.maxScrollRounds}: ${found.size} emoji discovered` +
        ` (${added >= 0 ? "+" : ""}${added}), idle-near-end ${stableRounds}/${options.idleRounds}`
      );
    }

    previousCount = found.size;

    if (stableRounds >= options.idleRounds) {
      console.log(`stopping after ${stableRounds} no-growth rounds near the end of the list`);
      break;
    }
  }
}

function collectFromJson(value, found, source, warnings, depth = 0) {
  if (depth > 10 || value == null) return;

  if (Array.isArray(value)) {
    for (const item of value) collectFromJson(item, found, source, warnings, depth + 1);
    return;
  }

  if (typeof value !== "object") return;

  const map = value.emoji || value.emojis || value.custom_emoji || value.customEmoji;
  if (map && typeof map === "object" && !Array.isArray(map)) {
    for (const [name, urlOrAlias] of Object.entries(map)) {
      addRecord(found, { name, urlOrAlias, source });
    }
  }

  for (const [key, item] of Object.entries(value)) {
    if (typeof item === "string" && (isUrl(item) || item.startsWith("alias:")) && cleanEmojiName(key)) {
      addRecord(found, { name: key, urlOrAlias: item, source });
    }
  }

  const name = value.name || value.emoji_name || value.emojiName || value.shortcode || value.short_code;
  const url =
    value.url ||
    value.image_url ||
    value.imageUrl ||
    value.src ||
    value.image ||
    value.image_original ||
    value.imageOriginal;
  const alias = value.alias || value.alias_for || value.aliasFor;
  if (name && (url || alias)) {
    addRecord(found, {
      name,
      urlOrAlias: alias ? `alias:${String(alias).replace(/^:/, "").replace(/:$/, "")}` : url,
      source
    });
  }

  for (const child of Object.values(value)) {
    collectFromJson(child, found, source, warnings, depth + 1);
  }
}

function addRecord(found, record) {
  const name = cleanEmojiName(record.name);
  if (!name) return;

  const urlOrAlias = record.urlOrAlias || record.url;
  if (!urlOrAlias || typeof urlOrAlias !== "string") return;
  if (!urlOrAlias.startsWith("alias:") && !isEmojiUrl(urlOrAlias)) return;

  const existing = found.get(name);
  if (existing?.urlOrAlias?.startsWith("http") && urlOrAlias.startsWith("alias:")) return;

  found.set(name, { name, urlOrAlias, source: record.source || "unknown" });
}

function cleanEmojiName(value) {
  if (!value) return null;
  const cleaned = String(value).trim().replace(/^:/, "").replace(/:$/, "");
  return /^[A-Za-z0-9][A-Za-z0-9_-]*$/.test(cleaned) ? cleaned : null;
}

function isUrl(value) {
  return /^https?:\/\//.test(value);
}

function isEmojiUrl(value) {
  if (!isUrl(value)) return false;

  try {
    const url = new URL(value);
    return url.hostname === "emoji.slack-edge.com" ||
      url.pathname.includes("/emoji/") ||
      url.pathname.toLowerCase().includes("emoji");
  } catch {
    return false;
  }
}

async function downloadEmoji(found, cdp, downloadDir, warnings) {
  const downloaded = {};
  const records = [...found.values()].sort((left, right) => left.name.localeCompare(right.name));
  let index = 0;

  for (const record of records) {
    index += 1;
    if (!isUrl(record.urlOrAlias)) continue;

    if (index === 1 || index % 250 === 0) {
      console.log(`download ${index}/${records.length}: ${Object.keys(downloaded).length} files saved`);
    }

    try {
      const response = await fetch(record.urlOrAlias);
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const body = Buffer.from(await response.arrayBuffer());
      const ext = extensionFrom(record.urlOrAlias, response.headers.get("content-type"));
      const filePath = path.join(downloadDir, `${safeFilename(record.name)}.${ext}`);
      if (options.overwrite) await writeFile(filePath, body);
      else await writeFileIfMissing(filePath, body);
      downloaded[record.name] = {
        path: path.resolve(filePath),
        url: record.urlOrAlias,
        ext,
        source: record.source
      };
    } catch (nodeFetchError) {
      try {
        const result = await downloadInPage(cdp, record.urlOrAlias);
        const body = Buffer.from(result.base64, "base64");
        const ext = extensionFrom(record.urlOrAlias, result.contentType);
        const filePath = path.join(downloadDir, `${safeFilename(record.name)}.${ext}`);
        if (options.overwrite) await writeFile(filePath, body);
        else await writeFileIfMissing(filePath, body);
        downloaded[record.name] = {
          path: path.resolve(filePath),
          url: record.urlOrAlias,
          ext,
          source: record.source
        };
      } catch (pageFetchError) {
        warnings.push(`failed to download ${record.name}: ${nodeFetchError.message}; page fetch also failed: ${pageFetchError.message}`);
      }
    }
  }

  console.log(`download complete: ${Object.keys(downloaded).length}/${records.length} files saved`);

  return downloaded;
}

async function writeFileIfMissing(filePath, body) {
  try {
    await writeFile(filePath, body, { flag: "wx" });
  } catch (error) {
    if (error.code !== "EEXIST") throw error;
  }
}

async function downloadInPage(cdp, url) {
  const escapedUrl = JSON.stringify(url);
  return cdp.evaluate(`(async () => {
    const response = await fetch(${escapedUrl}, { credentials: "include" });
    if (!response.ok) throw new Error("HTTP " + response.status);
    const contentType = response.headers.get("content-type");
    const buffer = await response.arrayBuffer();
    let binary = "";
    const bytes = new Uint8Array(buffer);
    const chunkSize = 0x8000;
    for (let index = 0; index < bytes.length; index += chunkSize) {
      binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
    }
    return { base64: btoa(binary), contentType };
  })()`);
}

function buildConfig(found, downloaded, opts, warnings) {
  const config = {};

  for (const record of [...found.values()].sort((left, right) => left.name.localeCompare(right.name))) {
    const directName = resolveDirectName(record.name, found);
    const file = downloaded[directName];
    if (!file) {
      warnings.push(`skipped ${record.name}: no downloaded file found`);
      continue;
    }

    config[`:${record.name}:`] = {
      path: file.path,
      mode: emoteMode(file.ext, opts.mode),
      send: opts.send
    };
  }

  return config;
}

function resolveDirectName(name, found, seen = new Set()) {
  if (seen.has(name)) return null;
  seen.add(name);

  const record = found.get(name);
  if (!record) return null;
  if (isUrl(record.urlOrAlias)) return name;
  if (!record.urlOrAlias.startsWith("alias:")) return null;

  return resolveDirectName(record.urlOrAlias.slice("alias:".length), found, seen);
}

function extensionFrom(url, contentType) {
  const pathname = new URL(url).pathname;
  const ext = path.extname(pathname).replace(".", "").toLowerCase();
  if (supportedExtensions.has(ext)) return ext;

  const normalizedContentType = String(contentType || "").split(";")[0].trim();
  return contentTypeExtensions.get(normalizedContentType) || "png";
}

function emoteMode(ext, requestedMode) {
  if (requestedMode !== "auto") return requestedMode;
  return ext === "gif" ? "file" : "image";
}

function safeFilename(name) {
  const safe = name.replace(/[^A-Za-z0-9_-]/g, "_");
  if (safe) return safe;
  return createHash("sha256").update(name).digest("hex").slice(0, 12);
}

async function writeJson(filePath, value) {
  await mkdir(path.dirname(filePath), { recursive: true });
  await writeFile(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

main().catch(error => {
  console.error(`error: ${error.message}`);
  process.exit(1);
});
