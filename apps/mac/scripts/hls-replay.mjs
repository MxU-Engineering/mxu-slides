#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const key = process.env.YT_KEY;
const dir = process.argv[2];
if (!key || !dir) {
  console.error("usage: YT_KEY=<studio stream key> node scripts/hls-replay.mjs <dump-dir>");
  process.exit(1);
}

const template = `https://a.upload.youtube.com/http_upload_hls?cid=${key}&copy=0&file=`;

const bySession = new Map();
for (const f of fs.readdirSync(dir)) {
  const match = /^seg-(\d+)-(\d+)\.ts$/.exec(f);
  if (!match) continue;
  const [, epoch, index] = match;
  if (!bySession.has(epoch)) bySession.set(epoch, []);
  bySession.get(epoch).push({ name: f, index: Number(index) });
}
if (bySession.size === 0) {
  console.error(`no seg-<epoch>-<n>.ts segments in ${dir}`);
  process.exit(1);
}
const latest = [...bySession.keys()].sort((a, b) => Number(a) - Number(b)).at(-1);
const segments = bySession.get(latest)
  .sort((a, b) => a.index - b.index)
  .map((s) => s.name);
console.log(`sessions in dump: ${bySession.size}; replaying session ${latest} (${segments.length} segments, 2s cadence)…`);

async function put(name, body, type) {
  const response = await fetch(template + name, {
    method: "PUT",
    headers: { "content-type": type },
    body,
  });
  return response.status;
}

const window = [];
let mediaSequence = 0;
for (const name of segments) {
  const body = fs.readFileSync(path.join(dir, name));
  const segStatus = await put(name, body, "video/mp2t");
  window.push(name);
  while (window.length > 5) { window.shift(); mediaSequence += 1; }
  const playlist = [
    "#EXTM3U",
    "#EXT-X-VERSION:3",
    "#EXT-X-TARGETDURATION:2",
    `#EXT-X-MEDIA-SEQUENCE:${mediaSequence}`,
    ...window.flatMap((n) => ["#EXTINF:2.000,", n]),
    "",
  ].join("\n");
  const listStatus = await put("playlist.m3u8", playlist, "application/vnd.apple.mpegurl");
  console.log(`${name}: segment=${segStatus} playlist=${listStatus}`);
  if (segStatus === 401 || listStatus === 401) {
    console.error("401 — the stream key is wrong or expired");
    process.exit(1);
  }
  await new Promise((r) => setTimeout(r, 2000));
}
console.log("replay complete — check Stream health in YouTube Studio");
