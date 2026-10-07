#!/usr/bin/env node

import http from "node:http";
import fs from "node:fs";
import path from "node:path";

const PORT = process.env.PORT ?? 8990;

const DUMP_DIR = process.env.HLS_SINK_DUMP;
if (DUMP_DIR) fs.mkdirSync(DUMP_DIR, { recursive: true });

const state = {
  segments: [],
  playlists: [],
  errors: [],
  lastMediaSequence: -1,
};

function recordError(message) {
  state.errors.push(message);
  console.error(`CONTRACT: ${message}`);
}

function validateSegment(name, body) {
  const tsAligned = body.length > 0 && body.length % 188 === 0;
  if (!tsAligned) recordError(`${name}: not 188-byte aligned (${body.length} bytes)`);
  if (body[0] !== 0x47) recordError(`${name}: does not start with TS sync byte`);
  const firstPID = ((body[1] & 0x1f) << 8) | body[2];
  const startsWithPAT = firstPID === 0;
  if (!startsWithPAT) recordError(`${name}: first packet PID ${firstPID}, expected PAT (0)`);

  if (state.segments.length === 0) {
    let hasParameterSets = false;
    for (let i = 0; i + 3 < body.length; i++) {
      if (body[i] === 0 && body[i + 1] === 0 && body[i + 2] === 1) {
        const nal = body[i + 3];

        const h264Type = nal & 0x1f;
        const hevcType = (nal >> 1) & 0x3f;
        if (h264Type === 7 || hevcType === 32 || hevcType === 33) {
          hasParameterSets = true;
          break;
        }
      }
    }
    if (!hasParameterSets) {
      recordError(`${name}: first segment has no parameter sets — stream opens undecodable`);
    }
  }
  state.segments.push({ name, bytes: body.length, tsAligned, startsWithPAT });
}

function validatePlaylist(body) {
  const text = body.toString("utf8");
  if (!text.startsWith("#EXTM3U")) recordError("playlist missing #EXTM3U");
  const sequence = Number(/#EXT-X-MEDIA-SEQUENCE:(\d+)/.exec(text)?.[1] ?? -1);
  if (sequence < state.lastMediaSequence) {
    recordError(`media sequence regressed ${state.lastMediaSequence} -> ${sequence}`);
  }
  state.lastMediaSequence = Math.max(state.lastMediaSequence, sequence);
  const names = [...text.matchAll(/^([^#\s].*\.ts)$/gm)].map((m) => m[1]);
  const known = new Set(state.segments.map((s) => s.name));
  const outstanding = names.filter((n) => !known.has(n));
  if (outstanding.length > 5) {
    recordError(`playlist lists ${outstanding.length} outstanding segments (max 5)`);
  }
  state.playlists.push({ mediaSequence: sequence, segmentNames: names });
}

http
  .createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host}`);
    if (req.method === "GET" && url.pathname === "/api/state") {
      res.setHeader("content-type", "application/json");
      res.end(JSON.stringify(state, null, 2));
      return;
    }
    if (req.method === "POST" && url.pathname === "/api/reset") {
      state.segments = [];
      state.playlists = [];
      state.errors = [];
      state.lastMediaSequence = -1;
      res.end();
      return;
    }
    if (req.method !== "PUT" && req.method !== "POST") {
      res.statusCode = 405;
      res.end();
      return;
    }
    const file = url.searchParams.get("file");
    if (!file) {
      res.statusCode = 400;
      res.end();
      return;
    }
    const chunks = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => {
      const body = Buffer.concat(chunks);
      if (DUMP_DIR) {
        fs.writeFileSync(path.join(DUMP_DIR, path.basename(file)), body);
      }
      if (file.endsWith(".ts")) {
        validateSegment(file, body);
        console.log(`segment ${file} (${body.length} bytes)`);
      } else if (file.endsWith(".m3u8") || file.endsWith(".m3u")) {
        validatePlaylist(body);
        console.log(`playlist seq=${state.lastMediaSequence}`);
      } else {
        recordError(`unexpected filename ${file}`);
      }
      res.statusCode = 200;
      res.end();
    });
  })
  .listen(PORT, "127.0.0.1", () => {
    console.log(`HLS sink on http://127.0.0.1:${PORT} — ingest template:`);
    console.log(`  http://127.0.0.1:${PORT}/http_upload_hls?cid=test&copy=0&file=`);
  });
