#!/usr/bin/env node
// CLI helpers used by batch-highlights.sh and inline-clip-render.sh in
// place of inline `python3 -c '...'` blocks. All variable values flow
// via argv (never interpolated into source), so player names with
// quotes / backslashes / regex metachars don't break parsing or escape
// into the running script.
//
// Each subcommand reads JSON from stdin (when applicable) and writes
// the extracted value as a plain string to stdout. Empty stdout is the
// canonical "missing" signal for the bash callers.
//
// Usage: node clip-helpers.mjs <subcommand> [args...]

import { readFileSync } from "node:fs";

import { nadeActTimeline } from "./nade-act.mjs";
import { nadeNext } from "./nade-next.mjs";

function readStdinJson() {
  try {
    return JSON.parse(readFileSync(0, "utf8"));
  } catch {
    return null;
  }
}

function readRoundTicks(path) {
  if (!path) return [];
  try {
    const rounds = JSON.parse(readFileSync(path, "utf8"));
    return Array.isArray(rounds) ? rounds : [];
  } catch {
    return [];
  }
}

const STEAMID64_BASE = 76561197960265728n;
const subcmd = process.argv[2];
const args = process.argv.slice(3);

switch (subcmd) {
  // [stdin: /demo/state] -> name of the player whose steam_id matches
  // argv[0], from gsi.spec_slots. Empty when missing.
  case "name-for-steamid": {
    const sid = args[0] ?? "";
    const d = readStdinJson();
    const slots = d?.gsi?.spec_slots ?? [];
    const m = slots.find((s) => s?.steam_id === sid);
    process.stdout.write(typeof m?.name === "string" ? m.name : "");
    break;
  }

  // [stdin: /demo/state] -> slot number (1..12) for argv[0] steam_id.
  case "slot-for-steamid": {
    const sid = args[0] ?? "";
    const d = readStdinJson();
    const slots = d?.gsi?.spec_slots ?? [];
    const m = slots.find((s) => s?.steam_id === sid);
    process.stdout.write(typeof m?.slot === "number" ? String(m.slot) : "");
    break;
  }

  // [stdin: /demo/state] -> one "slot=N steam=SID name=NAME" line per
  // spec_slot, marking the currently-spectated one. For POV debugging.
  case "slots-dump": {
    const d = readStdinJson();
    const slots = d?.gsi?.spec_slots ?? [];
    const spectated = d?.gsi?.spectated_steam_id ?? "";
    const out = slots
      .map((s) => `slot=${s.slot} steam=${s.steam_id} name=${s.name ?? "?"}`
        + (s.steam_id === spectated ? "  <-SPECTATED" : ""))
      .join("\n");
    process.stdout.write(out || "(no spec_slots)");
    break;
  }

  // [stdin: /demo/state] -> gsi.world_motion (sum of player positions),
  // or empty. Changes across polls iff the demo is actually advancing.
  case "world-motion": {
    const d = readStdinJson();
    const m = d?.gsi?.world_motion;
    process.stdout.write(Number.isFinite(m) ? String(m) : "");
    break;
  }

  // [stdin: /demo/state] -> count of populated spec_slots.
  case "state-slots": {
    const d = readStdinJson();
    const slots = d?.gsi?.spec_slots ?? [];
    process.stdout.write(String(Array.isArray(slots) ? slots.length : 0));
    break;
  }

  // [stdin: /demo/state] -> gsi.spectated_steam_id, or empty.
  case "spectated-steamid": {
    const d = readStdinJson();
    const sid = d?.gsi?.spectated_steam_id;
    process.stdout.write(typeof sid === "string" ? sid : "");
    break;
  }

  // [stdin: /demo/state] -> "1" if gsi.demoui_hidden truthy, else "0".
  case "demoui-hidden": {
    const d = readStdinJson();
    process.stdout.write(d?.gsi?.demoui_hidden ? "1" : "0");
    break;
  }

  // [stdin: /demo/state] -> tick (or "?" if missing).
  case "state-tick": {
    const d = readStdinJson();
    process.stdout.write(typeof d?.tick === "number" ? String(d.tick) : "?");
    break;
  }

  // [stdin: /demo/state; argv[0]=pov steamid] -> one pipe-delimited line of
  // every field the clip capture loop polls, so the bash loop spawns node ONCE
  // per tick instead of 7x (matters at the 150ms poll cadence). Field order:
  //   round_phase|phase_ends_in|world_motion|gsi_age_ms|map_phase|round_number|pov_round_kills
  // pov_round_kills = round_kills of the spec_slot whose steam_id == argv[0]
  // (the POV target), for kill-event detection. Missing values render empty.
  case "capture-fields": {
    const povSid = args[0] ?? "";
    const d = readStdinJson();
    const num = (v) => (typeof v === "number" && Number.isFinite(v) ? String(Math.floor(v)) : "");
    const str = (v) => (typeof v === "string" ? v : "");
    let wm = "";
    const m = d?.gsi?.world_motion;
    if (Number.isFinite(m)) wm = String(Math.round(m));
    let povKills = "";
    if (povSid) {
      const slot = (d?.gsi?.spec_slots ?? []).find((s) => s?.steam_id === povSid);
      if (slot && Number.isFinite(slot.round_kills)) povKills = String(slot.round_kills);
    }
    process.stdout.write([
      str(d?.gsi?.round_phase),
      str(d?.gsi?.phase_ends_in),
      wm,
      num(d?.gsi?.last_received_ms_ago),
      str(d?.gsi?.map_phase),
      num(d?.gsi?.round_number),
      povKills,
    ].join("|"));
    break;
  }

  // [stdin: /demo/state] -> total_ticks, or empty.
  case "state-total-ticks": {
    const d = readStdinJson();
    const ticks = d?.total_ticks;
    process.stdout.write(typeof ticks === "number" && ticks > 0 ? String(Math.floor(ticks)) : "");
    break;
  }

  // [stdin: /demo/state] -> "true" | "false" | "?"
  case "state-paused": {
    const d = readStdinJson();
    if (d?.paused === true) process.stdout.write("true");
    else if (d?.paused === false) process.stdout.write("false");
    else process.stdout.write("?");
    break;
  }

  // [stdin: /demo/state] -> "1" while a gototick is still settling, else "0".
  // Absent on a spec-server that predates the field; "0" then keeps the caller
  // on its old no-wait behaviour rather than blocking for the full timeout.
  case "state-seeking": {
    const d = readStdinJson();
    process.stdout.write(d?.seeking === true ? "1" : "0");
    break;
  }

  // [stdin: /demo/state] -> gsi.map_phase (live / gameover / ...), or empty.
  case "state-map-phase": {
    const d = readStdinJson();
    const phase = d?.gsi?.map_phase;
    process.stdout.write(typeof phase === "string" ? phase : "");
    break;
  }

  // [stdin: /demo/state] -> gsi.round_phase (freezetime / live / over), or empty.
  case "state-round-phase": {
    const d = readStdinJson();
    const phase = d?.gsi?.round_phase;
    process.stdout.write(typeof phase === "string" ? phase : "");
    break;
  }

  // [stdin: /demo/state] -> gsi.last_received_ms_ago, or empty.
  case "state-gsi-age-ms": {
    const d = readStdinJson();
    const ms = d?.gsi?.last_received_ms_ago;
    process.stdout.write(typeof ms === "number" ? String(Math.floor(ms)) : "");
    break;
  }

  // [stdin: title] -> rewrite leading "Player NNNN" prefix to argv[0].
  // Uses a function callback for the replacement so $1/$&/$$ in the
  // resolved name aren't interpreted as backreferences.
  case "patch-player-name": {
    const newName = args[0] ?? "";
    const title = readFileSync(0, "utf8");
    process.stdout.write(
      title.replace(/^Player [A-Za-z0-9_-]+/, () => newName),
    );
    break;
  }

  // [stdin: clip-render status JSON] -> .status field, or empty.
  case "status-field": {
    const d = readStdinJson();
    process.stdout.write(typeof d?.status === "string" ? d.status : "");
    break;
  }

  // [stdin: CLIP_BATCH_JOBS] -> number of jobs (0 if not an array).
  case "jobs-count": {
    const d = readStdinJson();
    process.stdout.write(String(Array.isArray(d) ? d.length : 0));
    break;
  }

  // [stdin: CLIP_BATCH_JOBS] -> one "<job_id>\t<token>" line per job.
  // Tabs/newlines in either field would mis-split the bash `read -r`
  // on the other side, so we reject malformed entries silently.
  case "jobs-credentials": {
    const d = readStdinJson();
    if (!Array.isArray(d)) break;
    const FORBIDDEN = /[\t\n\r]/;
    for (const job of d) {
      const id = job?.job_id;
      const token = job?.token;
      if (
        typeof id === "string" && typeof token === "string"
        && id && token
        && !FORBIDDEN.test(id) && !FORBIDDEN.test(token)
      ) {
        process.stdout.write(`${id}\t${token}\n`);
      }
    }
    break;
  }

  // [stdin: CLIP_BATCH_JOBS] -> JSON of jobs[argv[0]]. Exits 1 if oob.
  // [stdin: CLIP_BATCH_JOBS] -> the first job's output fps (60 when missing).
  case "jobs-fps": {
    const d = readStdinJson();
    const fps = parseInt((Array.isArray(d) ? d[0] : null)?.spec?.output?.fps, 10);
    process.stdout.write(String(Number.isFinite(fps) ? fps : 60));
    break;
  }

  case "jobs-at": {
    const idx = Number(args[0]);
    const d = readStdinJson();
    if (!Array.isArray(d) || !Number.isFinite(idx) || idx < 0 || idx >= d.length) {
      process.exit(1);
    }
    process.stdout.write(JSON.stringify(d[idx]));
    break;
  }

  // [stdin: job_json] -> every field batch_render_one_job needs, each
  // NUL-TERMINATED (one node spawn per job instead of 12; terminator,
  // not separator, so bash readarray keeps trailing EMPTY fields).
  // Free-text fields (title, names) can contain anything EXCEPT NUL — \u0000 is stripped
  // so a malicious value can't shift the field positions. Order:
  //   job_id token segments_json output_dims output_fps target_sid
  //   title target_name target_avatar_url kills_count map_name round
  // Semantics match the individual subcommands below.
  case "job-fields": {
    const d = readStdinJson();
    const S = (v) => (typeof v === "string" ? v.replaceAll("\u0000", "") : "");
    const segs = d?.spec?.segments;
    const res = d?.spec?.output?.resolution ?? "1080p";
    const fps = parseInt(d?.spec?.output?.fps, 10);
    const seg0sid = (Array.isArray(segs) ? segs : [])[0]?.pov_steam_id;
    const kills = d?.spec?.kills_count;
    const round = d?.spec?.round;
    process.stdout.write([
      S(d?.job_id),
      S(d?.token),
      JSON.stringify(Array.isArray(segs) ? segs : []),
      res === "720p" ? "1280x720" : "1920x1080",
      String(Number.isFinite(fps) ? fps : 60),
      S(seg0sid),
      S(d?.spec?.title),
      S(d?.spec?.target_name),
      S(d?.spec?.target_avatar_url),
      typeof kills === "number" && Number.isFinite(kills) && kills > 0
        ? String(Math.floor(kills)) : "",
      S(d?.spec?.map_name),
      typeof round === "number" && Number.isFinite(round) && round >= 0
        ? String(Math.floor(round)) : "",
    ].map((f) => f + "\u0000").join(""));
    break;
  }

  // [stdin: nade job_json] -> every field batch-nades.sh exports, each
  // NUL-TERMINATED (same shape as job-fields above). The spec keys mirror the
  // nade_lineups column names so the api can splat a row into it. Order:
  //   job_id token lineup_id lineup_name map_name nade_type side
  //   origin(x,y,z) eye_z view_yaw view_pitch flight_time_ms has_seed
  //   confidence plugin_runtime output_dims output_fps
  // has_seed follows the plugin's own rule (all six initial_* present AND a
  // non-zero velocity) unless the api states it outright — a lineup without it
  // cannot be re-emitted exactly and gets skipped rather than approximated.
  case "nade-fields": {
    const d = readStdinJson();
    const s = d?.spec ?? {};
    const S = (v) => (typeof v === "string" ? v.replaceAll("\u0000", "") : "");
    const N = (v) => (typeof v === "number" && Number.isFinite(v) ? String(v) : "");
    const seedKeys = [
      "initial_pos_x", "initial_pos_y", "initial_pos_z",
      "initial_vel_x", "initial_vel_y", "initial_vel_z",
    ];
    let hasSeed = s.has_seed === true;
    if (!hasSeed && s.has_seed !== false) {
      const vals = seedKeys.map((k) => s[k]);
      const complete = vals.every((v) => typeof v === "number" && Number.isFinite(v));
      const speed = complete
        ? Math.hypot(s.initial_vel_x, s.initial_vel_y, s.initial_vel_z)
        : 0;
      hasSeed = complete && speed > 0;
    }
    const origin = ["origin_x", "origin_y", "origin_z"].map((k) => N(s[k]));
    const fps = parseInt(s?.output?.fps, 10);
    const flight = Number(s.flight_time_ms);
    process.stdout.write([
      S(d?.job_id),
      S(d?.token),
      S(s.lineup_id),
      S(s.lineup_name ?? s.name),
      S(s.map_name),
      S(s.nade_type),
      S(s.side),
      origin.every(Boolean) ? origin.join(",") : "",
      N(s.eye_z),
      N(s.view_yaw),
      N(s.view_pitch),
      Number.isFinite(flight) && flight > 0 ? String(Math.round(flight)) : "0",
      hasSeed ? "1" : "0",
      S(s.confidence),
      S(s.plugin_runtime),
      s?.output?.resolution === "720p" ? "1280x720" : "1920x1080",
      String(Number.isFinite(fps) ? fps : 60),
      S(s.technique),
      S(s.throw_strength),
      s.jump_throw_bind === true ? "1" : "0",
    ].map((f) => f + "\u0000").join(""));
    break;
  }

  // [stdin: the api's answer to nade-render-queue/:match_id/next]
  //   -> action, map, seconds, jobs (JSON array), each NUL-terminated. A body
  //      that cannot be read comes out as "done".
  case "nade-next": {
    const next = nadeNext(readStdinJson());
    const out = [next.action, next.map, String(next.seconds), JSON.stringify(next.jobs)];
    process.stdout.write(out.map((value) => `${value}\0`).join(""));
    break;
  }

  // [stdin: nade job_json] -> spec.approach as JSON, or nothing for a throw
  // made standing still.
  case "nade-approach": {
    const approach = readStdinJson()?.spec?.approach;
    if (Array.isArray(approach) && approach.length > 0) {
      process.stdout.write(JSON.stringify(approach));
    }
    break;
  }

  // [stdin: spec.approach JSON, or nothing]
  // argv: <technique> <strength> <jump_bind 0|1> <pin_pull_ms>
  //   -> one "<ms>\t<console action>" line per step of the throw
  case "nade-timeline": {
    const timeline = nadeActTimeline({
      approach: readStdinJson(),
      technique: args[0],
      strength: args[1],
      jumpBind: args[2] === "1",
      pinPullMs: args[3],
    });
    process.stdout.write(timeline.map(({ at, cmd }) => `${at}\t${cmd}\n`).join(""));
    break;
  }

  // [stdin: job_json] -> top-level job_id.
  case "job-id": {
    const d = readStdinJson();
    process.stdout.write(typeof d?.job_id === "string" ? d.job_id : "");
    break;
  }

  // [stdin: job_json] -> top-level token.
  case "job-token": {
    const d = readStdinJson();
    process.stdout.write(typeof d?.token === "string" ? d.token : "");
    break;
  }

  // [stdin: job_json] -> spec.title (or empty).
  case "job-title": {
    const d = readStdinJson();
    const t = d?.spec?.title;
    process.stdout.write(typeof t === "string" ? t : "");
    break;
  }

  case "job-target-name": {
    const d = readStdinJson();
    const n = d?.spec?.target_name;
    process.stdout.write(typeof n === "string" ? n : "");
    break;
  }

  case "job-target-avatar-url": {
    const d = readStdinJson();
    const a = d?.spec?.target_avatar_url;
    process.stdout.write(typeof a === "string" ? a : "");
    break;
  }

  case "job-kills-count": {
    const d = readStdinJson();
    const k = d?.spec?.kills_count;
    if (typeof k === "number" && Number.isFinite(k) && k > 0) {
      process.stdout.write(String(Math.floor(k)));
    }
    break;
  }

  case "job-map-name": {
    const d = readStdinJson();
    const m = d?.spec?.map_name;
    process.stdout.write(typeof m === "string" ? m : "");
    break;
  }

  case "job-round": {
    const d = readStdinJson();
    const r = d?.spec?.round;
    if (typeof r === "number" && Number.isFinite(r) && r >= 0) {
      process.stdout.write(String(Math.floor(r)));
    }
    break;
  }

  // [stdin: job_json] -> spec.segments as a JSON string.
  case "job-segments": {
    const d = readStdinJson();
    const segs = d?.spec?.segments;
    process.stdout.write(JSON.stringify(Array.isArray(segs) ? segs : []));
    break;
  }

  // [stdin: job_json] -> "1280x720" | "1920x1080" from spec.output.resolution.
  case "job-output-dims": {
    const d = readStdinJson();
    const res = d?.spec?.output?.resolution ?? "1080p";
    process.stdout.write(res === "720p" ? "1280x720" : "1920x1080");
    break;
  }

  // [stdin: job_json] -> spec.output.fps (default 60).
  case "job-output-fps": {
    const d = readStdinJson();
    const raw = d?.spec?.output?.fps;
    const fps = parseInt(raw, 10);
    process.stdout.write(String(Number.isFinite(fps) ? fps : 60));
    break;
  }

  // [stdin: job_json] -> first segment's pov_steam_id (or empty).
  case "job-first-pov-steamid": {
    const d = readStdinJson();
    const seg = (d?.spec?.segments ?? [])[0];
    const sid = seg?.pov_steam_id;
    process.stdout.write(typeof sid === "string" ? sid : "");
    break;
  }

  // [stdin: CLIP_SEGMENTS] -> number of segments.
  case "segs-count": {
    const d = readStdinJson();
    process.stdout.write(String(Array.isArray(d) ? d.length : 0));
    break;
  }

  // [stdin: CLIP_SEGMENTS] -> sum of (end_tick - start_tick) >=0.
  case "segs-total-ticks": {
    const d = readStdinJson();
    let total = 0;
    if (Array.isArray(d)) {
      for (const s of d) {
        const start = Number(s?.start_tick);
        const end = Number(s?.end_tick);
        if (Number.isFinite(start) && Number.isFinite(end)) {
          total += Math.max(0, end - start);
        }
      }
    }
    process.stdout.write(String(total));
    break;
  }

  // [stdin: CLIP_SEGMENTS] -> one "start|end|accountid|killtick" line per
  // segment, so the segment loop spawns node ONCE up front instead of 3x per
  // segment. All values numeric (accountid/killtick empty when missing or
  // invalid), so the line protocol is injection-safe.
  case "segs-table": {
    const d = readStdinJson();
    if (!Array.isArray(d)) break;
    for (const s of d) {
      const start = typeof s?.start_tick === "number" ? String(Math.floor(s.start_tick)) : "";
      const end = typeof s?.end_tick === "number" ? String(Math.floor(s.end_tick)) : "";
      const kill = typeof s?.kill_tick === "number" ? String(Math.floor(s.kill_tick)) : "";
      let aid = "";
      const sid = s?.pov_steam_id;
      if (typeof sid === "string" && /^\d+$/.test(sid)) {
        const a = BigInt(sid) - STEAMID64_BASE;
        if (a > 0n) aid = a.toString();
      }
      process.stdout.write(`${start}|${end}|${aid}|${kill}\n`);
    }
    break;
  }

  // [stdin: CLIP_SEGMENTS] -> segments[argv[0]].start_tick (or empty).
  case "seg-start-tick": {
    const idx = Number(args[0]);
    const d = readStdinJson();
    const v = Array.isArray(d) ? d[idx]?.start_tick : null;
    process.stdout.write(typeof v === "number" ? String(v) : "");
    break;
  }

  // [stdin: CLIP_SEGMENTS] -> segments[argv[0]].end_tick (or empty).
  case "seg-end-tick": {
    const idx = Number(args[0]);
    const d = readStdinJson();
    const v = Array.isArray(d) ? d[idx]?.end_tick : null;
    process.stdout.write(typeof v === "number" ? String(v) : "");
    break;
  }


  // argv[0]=round_ticks JSON path -> highest end_tick, or empty.
  case "rounds-last-end-tick": {
    const rounds = readRoundTicks(args[0]);
    let max = 0;
    for (const r of rounds) {
      const end = Number(r?.end_tick);
      if (Number.isFinite(end) && end > max) max = end;
    }
    if (max > 0) process.stdout.write(String(Math.floor(max)));
    break;
  }

  // argv[0]=round_ticks JSON path -> the final round's end_tick when that round
  // was decided (it has a winner), or empty. The match ends with that round, so
  // nothing after it can be played without running into gameover.
  case "rounds-match-end-tick": {
    const rounds = readRoundTicks(args[0]);
    const last = rounds[rounds.length - 1];
    const end = Number(last?.end_tick);
    if (last?.winner && Number.isFinite(end) && end > 0) {
      process.stdout.write(String(Math.floor(end)));
    }
    break;
  }

  // [stdin: CLIP_SEGMENTS] -> accountid for segments[argv[0]].pov_steam_id
  // (steamid64 - 76561197960265728), or empty if missing/invalid.
  case "seg-pov-accountid": {
    const idx = Number(args[0]);
    const d = readStdinJson();
    const sid = Array.isArray(d) ? d[idx]?.pov_steam_id : null;
    if (typeof sid !== "string" || !/^\d+$/.test(sid)) {
      process.stdout.write("");
      break;
    }
    const aid = BigInt(sid) - STEAMID64_BASE;
    process.stdout.write(aid > 0n ? aid.toString() : "");
    break;
  }

  // Build a status-body JSON object from "k=v" args. Numeric fields
  // are coerced (and dropped if NaN); other keys stay strings.
  case "status-body": {
    const NUMERIC = new Set(["progress", "boot_progress", "duration_ms"]);
    const out = {};
    for (const kv of args) {
      const i = kv.indexOf("=");
      if (i < 0) continue;
      const k = kv.slice(0, i);
      const v = kv.slice(i + 1);
      if (NUMERIC.has(k)) {
        const f = Number(v);
        if (Number.isFinite(f)) out[k] = f;
      } else {
        out[k] = v;
      }
    }
    process.stdout.write(JSON.stringify(out));
    break;
  }

  default:
    process.stderr.write(`clip-helpers: unknown subcommand: ${subcmd}\n`);
    process.exit(2);
}
