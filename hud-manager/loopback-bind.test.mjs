// node --test hud-manager/loopback-bind.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";

const PATCH = readFileSync(new URL("./auto-overlay.patch", import.meta.url), "utf8");

const LOOPBACK_LISTEN = /\.listen\([^,]+, '127\.0\.0\.1', /;

// A file's hunks split into the lines the patch takes out and the lines it
// leaves in their place (context plus additions).
function hunks(file) {
  const section = PATCH.split(/^diff --git /m).find((s) => s.startsWith(`a/${file} `));
  assert.ok(section, `${file} is not in auto-overlay.patch`);
  const lines = section.slice(section.indexOf("\n@@") + 1).split("\n").filter((l) => !l.startsWith("@@"));
  return {
    removed: lines.filter((l) => l.startsWith("-")).map((l) => l.slice(1)),
    after: lines.filter((l) => !l.startsWith("-")).map((l) => l.slice(1)),
  };
}

test("upstream's two listens on every interface are taken out", () => {
  const { removed } = hunks("src/main/server/server.ts");
  assert.ok(removed.includes("  httpServer.listen(HUD_PORT, () => {"), "the HUD/socket.io listen is not replaced");
  assert.ok(removed.includes("  const gsiServer = gsiApp.listen(GSI_PORT, () => {"), "the GSI listen is not replaced");
});

test("the HUD/socket.io and GSI servers both bind loopback", () => {
  const listens = hunks("src/main/server/server.ts").after.filter((l) => /\.listen\(/.test(l));
  assert.equal(listens.length, 2, listens.join("\n"));
  for (const line of listens) {
    assert.match(line, LOOPBACK_LISTEN);
  }
  assert.ok(listens.some((l) => l.includes("httpServer.listen(Number(HUD_PORT), ")));
  assert.ok(listens.some((l) => l.includes("gsiApp.listen(Number(GSI_PORT), ")));
});

test("nothing the patch adds listens beyond loopback", () => {
  const added = PATCH.split("\n").filter((l) => /^\+(?!\+\+)/.test(l) && /\.listen\(/.test(l));
  assert.ok(added.length >= 2, "the scan is not seeing the patch's listens");
  for (const line of added) {
    assert.match(line, LOOPBACK_LISTEN);
  }
});

// ::1 is left unbound, so a URL naming localhost could reach whatever else on
// the node takes it.
test("the overlay loads its HUD from 127.0.0.1, not localhost", () => {
  const urls = PATCH.split("\n").filter((l) => /^\+(?!\+\+)/.test(l) && /hudUrl = `/.test(l));
  assert.equal(urls.length, 2, urls.join("\n"));
  for (const line of urls) {
    assert.match(line, /hudUrl = `http:\/\/127\.0\.0\.1:\$\{/);
  }
});
