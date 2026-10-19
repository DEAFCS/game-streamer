// node --test src/spectator/routes/index.test.mjs
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { createServer, request } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";

import { gsiState } from "../state/gsi.mjs";

const STEAM_ID = "76561198000000001";

let apiServer;
let specServer;
let specBase;
let dispatch;

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve(`http://127.0.0.1:${server.address().port}`));
  });
}

function post(path, body) {
  return new Promise((resolve, reject) => {
    let answered = false;
    const req = request(`${specBase}${path}`, { method: "POST", agent: false }, (res) => {
      answered = true;
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString("utf8") }));
      res.on("error", () => resolve({ status: res.statusCode, body: "" }));
    });
    req.on("error", (err) => {
      if (!answered) {
        reject(err);
      }
    });
    req.end(body);
  });
}

before(async () => {
  apiServer = createServer((req, res) => {
    req.resume();
    req.on("end", () => {
      res.writeHead(201, { "Content-Type": "application/sdp" });
      res.end("v=0\r\n");
    });
  });
  const apiBase = await listen(apiServer);
  delete process.env.SPEC_SERVER_TOKEN;
  Object.assign(process.env, {
    LOG_DIR: mkdtempSync(join(tmpdir(), "spec-routes-")),
    MATCH_ID: "match-1",
    MATCH_PASSWORD: "secret",
    STATUS_API_BASE: apiBase,
  });
  ({ dispatch } = await import("./index.mjs"));
  gsiState.spectatedSteamId = STEAM_ID;
  specServer = createServer((req, res) => { void dispatch(req, res); });
  specBase = await listen(specServer);
});

after(() => {
  apiServer.close();
  specServer.close();
});

test("a literal null body gets the handler's 400, not a 500", async () => {
  const r = await post("/demo/seek", "null");
  assert.equal(r.status, 400);
  assert.deepEqual(JSON.parse(r.body), { error: "tick (non-negative int) required" });
});

// One byte over, so the server has read every byte it was sent and the 413 is not
// lost to a reset.
test("a JSON body over 1 MiB is refused with 413", async () => {
  const body = `{"pad":"${"x".repeat(1024 * 1024 - 9)}"}`;
  assert.equal(Buffer.byteLength(body), 1024 * 1024 + 1);
  const r = await post("/demo/exec", body);
  assert.equal(r.status, 413);
});

test("a WHEP offer over 64 KiB is refused with 413", async () => {
  const r = await post(`/camera/${STEAM_ID}/whep`, "x".repeat(64 * 1024 + 1));
  assert.equal(r.status, 413);
});

test("a normal WHEP offer is still proxied", async () => {
  const r = await post(`/camera/${STEAM_ID}/whep`, "a=candidate:1 1 udp 2113937151 10.0.0.2 50000 typ host\r\n".repeat(80));
  assert.equal(r.status, 200);
  assert.equal(r.body, "v=0\r\n");
});

// A pod started by an api that predates SPEC_SERVER_TOKEN keeps working as before.
test("with no SPEC_SERVER_TOKEN a call without a token still reaches its handler", async () => {
  const r = await post("/demo/exec", "{}");
  assert.equal(r.status, 400);
  assert.deepEqual(JSON.parse(r.body), { error: "cmd (string) required" });
});

test("with no SPEC_SERVER_TOKEN the camera calls are still served off loopback", async () => {
  const res = {
    writeHead(status) { this.statusCode = status; },
    end() {},
  };
  await dispatch({ method: "GET", url: "/camera/state", headers: {}, socket: { remoteAddress: "10.42.0.7" } }, res);
  assert.equal(res.statusCode, 200);
});

test("with no SPEC_SERVER_TOKEN a GSI post with the old fixed token is accepted", async () => {
  const r = await post("/gsi", JSON.stringify({ auth: { token: "5stack-spec" }, provider: {} }));
  assert.equal(r.status, 200);
});
