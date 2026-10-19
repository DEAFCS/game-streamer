// node --test src/spectator/routes/auth.test.mjs
import { after, before, test } from "node:test";
import assert from "node:assert/strict";
import { createServer, request } from "node:http";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import process from "node:process";
import { setTimeout as sleep } from "node:timers/promises";

import { gsiState } from "../state/gsi.mjs";

const TOKEN = "pod-token-0123456789abcdefghijklmnopqrstuv";
const SPECTATED = "76561198000000001";
const OTHER_PLAYER = "76561198000000002";

let apiServer;
let hudServer;
let specServer;
let specBase;
let dispatch;
const hudBodies = [];
const whepPaths = [];

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, "127.0.0.1", () => resolve(server.address().port));
  });
}

function call(method, path, { body, token } = {}) {
  return new Promise((resolve, reject) => {
    const headers = token === undefined ? {} : { authorization: `Bearer ${token}` };
    const req = request(`${specBase}${path}`, { method, headers, agent: false }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => resolve({ status: res.statusCode, body: Buffer.concat(chunks).toString("utf8") }));
    });
    req.on("error", reject);
    req.end(body);
  });
}

// What a caller off the node looks like: the same request, from another address.
async function callFrom(remoteAddress, method, path, headers = {}) {
  const res = {
    statusCode: 0,
    headersSent: false,
    writeHead(status) { this.statusCode = status; this.headersSent = true; },
    end(body) { this.body = body; },
  };
  await dispatch(
    { method, url: path, headers, socket: { remoteAddress } },
    res,
  );
  return res;
}

before(async () => {
  apiServer = createServer((req, res) => {
    whepPaths.push(req.url);
    req.resume();
    req.on("end", () => {
      res.writeHead(201, { "Content-Type": "application/sdp" });
      res.end("v=0\r\n");
    });
  });
  hudServer = createServer((req, res) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      hudBodies.push(JSON.parse(Buffer.concat(chunks).toString("utf8")));
      res.end();
    });
  });
  const apiPort = await listen(apiServer);
  const hudPort = await listen(hudServer);
  Object.assign(process.env, {
    LOG_DIR: mkdtempSync(join(tmpdir(), "spec-auth-")),
    MATCH_ID: "match-1",
    MATCH_PASSWORD: "secret",
    STATUS_API_BASE: `http://127.0.0.1:${apiPort}`,
    HUD_HOST: "127.0.0.1",
    HUD_GSI_PORT: String(hudPort),
    SPEC_SERVER_TOKEN: TOKEN,
  });
  ({ dispatch } = await import("./index.mjs"));
  specServer = createServer((req, res) => { void dispatch(req, res); });
  specBase = `http://127.0.0.1:${await listen(specServer)}`;
});

after(() => {
  apiServer.close();
  hudServer.close();
  specServer.close();
});

test("a call without the pod's token is refused before its handler runs", async () => {
  const r = await call("POST", "/demo/exec", { body: "{}" });
  assert.equal(r.status, 401);
});

test("a call with the wrong token is refused", async () => {
  assert.equal((await call("POST", "/demo/exec", { body: "{}", token: `${TOKEN.slice(0, -1)}x` })).status, 401);
  assert.equal((await call("POST", "/demo/exec", { body: "{}", token: "short" })).status, 401);
  assert.equal((await call("POST", "/demo/exec", { body: "{}", token: "" })).status, 401);
});

test("a call with the pod's token reaches its handler", async () => {
  const r = await call("POST", "/demo/exec", { body: "{}", token: TOKEN });
  assert.equal(r.status, 400);
  assert.deepEqual(JSON.parse(r.body), { error: "cmd (string) required" });
});

test("the health route needs the token too", async () => {
  assert.equal((await call("GET", "/health")).status, 401);
});

test("an unknown route without the token is refused rather than reported missing", async () => {
  assert.equal((await call("GET", "/nope")).status, 401);
});

test("the api, calling from off the node, gets in with the token", async () => {
  const r = await callFrom("10.42.0.7", "GET", "/nade/self", {
    authorization: `Bearer ${TOKEN}`,
  });
  assert.equal(r.statusCode, 200);
});

test("a GSI post carrying the token in its auth block is accepted", async () => {
  const r = await call("POST", "/gsi", { body: JSON.stringify({ auth: { token: TOKEN }, provider: {} }) });
  assert.equal(r.status, 200);
});

test("a GSI post with no or the wrong auth block is refused", async () => {
  assert.equal((await call("POST", "/gsi", { body: JSON.stringify({ provider: {} }) })).status, 401);
  assert.equal((await call("POST", "/gsi", { body: JSON.stringify({ auth: { token: "5stack-spec" } }) })).status, 401);
  assert.equal((await call("POST", "/gsi", { body: JSON.stringify({ auth: TOKEN }) })).status, 401);
});

test("the HUD is forwarded GSI without the token", async () => {
  hudBodies.length = 0;
  await call("POST", "/gsi", { body: JSON.stringify({ auth: { token: TOKEN }, provider: { name: "cs2" } }) });
  for (let i = 0; i < 100 && hudBodies.length === 0; i++) {
    await sleep(20);
  }
  assert.equal(hudBodies.length, 1);
  assert.deepEqual(hudBodies[0], { provider: { name: "cs2" } });
});

test("the HUD overlay's camera calls need no token from loopback", async () => {
  gsiState.spectatedSteamId = SPECTATED;
  assert.equal((await call("GET", "/camera/state")).status, 200);
  const whep = await call("POST", `/camera/${SPECTATED}/whep`, { body: "v=0\r\n" });
  assert.equal(whep.status, 200);
});

test("a WHEP call for a player the broadcast is not on is refused before the api is asked", async () => {
  gsiState.spectatedSteamId = SPECTATED;
  whepPaths.length = 0;
  const r = await call("POST", `/camera/${OTHER_PLAYER}/whep`, { body: "v=0\r\n" });
  assert.equal(r.status, 409);
  assert.deepEqual(whepPaths, []);
});

test("with nobody spectated, no camera is handed out", async () => {
  gsiState.spectatedSteamId = null;
  whepPaths.length = 0;
  const r = await call("POST", `/camera/${SPECTATED}/whep`, { body: "v=0\r\n" });
  assert.equal(r.status, 409);
  assert.deepEqual(whepPaths, []);
});

test("the spectated player's camera is proxied for that player", async () => {
  gsiState.spectatedSteamId = SPECTATED;
  whepPaths.length = 0;
  const r = await call("POST", `/camera/${SPECTATED}/whep`, { body: "v=0\r\n" });
  assert.equal(r.status, 200);
  assert.deepEqual(whepPaths, [`/matches/camera/broadcast/match-1/${SPECTATED}/whep`]);
});

test("the camera calls are refused from any other address", async () => {
  assert.equal((await callFrom("10.42.0.7", "GET", "/camera/state")).statusCode, 403);
  assert.equal((await callFrom("10.42.0.7", "POST", "/camera/76561198000000001/whep")).statusCode, 403);
});

test("a forwarded-for header does not make a remote caller loopback", async () => {
  const r = await callFrom("203.0.113.9", "GET", "/camera/state", { "x-forwarded-for": "127.0.0.1" });
  assert.equal(r.statusCode, 403);
});

test("IPv6 and IPv4-mapped loopback count as loopback", async () => {
  assert.equal((await callFrom("::1", "GET", "/camera/state")).statusCode, 200);
  assert.equal((await callFrom("::ffff:127.0.0.1", "GET", "/camera/state")).statusCode, 200);
});
