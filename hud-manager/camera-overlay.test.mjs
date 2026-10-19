// node --test hud-manager/camera-overlay.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { setImmediate as settle } from "node:timers/promises";

const SOURCE = readFileSync(new URL("./camera-overlay.js", import.meta.url), "utf8");

const PLAYER_A = "76561198000000001";
const PLAYER_B = "76561198000000002";

// The overlay in a page with no HUD markup, a peer connection whose ICE
// gathering is already complete, and a spec-server answering from `spec`.
// The poll interval is driven by hand through `poll`.
function loadOverlay(spec) {
  let poll;
  let now = 0;
  const whepCalls = [];

  const body = {
    appendChild(child) {
      child.parentElement = body;
    },
  };

  const video = {
    style: { removeProperty() {} },
    parentElement: null,
    removeAttribute() {},
    remove() {},
    play: async () => {},
  };

  class RTCPeerConnection {
    iceGatheringState = "complete";
    connectionState = "new";
    localDescription = { sdp: "v=0\r\n" };
    addTransceiver() {}
    addEventListener() {}
    async createOffer() {
      return {};
    }
    async setLocalDescription() {}
    async setRemoteDescription() {}
    close() {}
  }

  async function fetch(url) {
    const path = new URL(url).pathname;

    if (path === "/camera/state") {
      return { ok: true, status: 200, json: async () => ({ enabled: true, steam_id: spec.spectated }) };
    }

    const steamId = path.split("/")[2];
    whepCalls.push(steamId);
    const status = spec.whep(steamId);

    return { ok: status >= 200 && status < 300, status, text: async () => "v=0\r\n" };
  }

  const page = {
    document: { createElement: () => video, querySelector: () => null, body },
    MutationObserver: class {
      observe() {}
      disconnect() {}
    },
    requestAnimationFrame() {},
    RTCPeerConnection,
    fetch,
    Date: { now: () => now },
    setInterval(fn) {
      poll = fn;
      return 1;
    },
    clearInterval() {},
    setTimeout() {},
  };
  page.window = page;

  runInNewContext(SOURCE, page);

  return {
    whepCalls,
    poll: async () => {
      await poll();
      await settle();
    },
    advance(ms) {
      now += ms;
    },
  };
}

test("a camera refused because the director moved on is asked for again as soon as it is spectated", async () => {
  const spec = { spectated: PLAYER_A, whep: () => 409 };
  const overlay = loadOverlay(spec);
  await settle();
  assert.deepEqual(overlay.whepCalls, [PLAYER_A]);

  spec.spectated = PLAYER_B;
  spec.whep = () => 201;
  await overlay.poll();
  assert.deepEqual(overlay.whepCalls, [PLAYER_A, PLAYER_B]);

  spec.spectated = PLAYER_A;
  await overlay.poll();
  assert.deepEqual(overlay.whepCalls, [PLAYER_A, PLAYER_B, PLAYER_A]);
});

for (const status of [404, 502]) {
  test(`a camera that fails with ${status} is not asked for again until the backoff passes`, async () => {
    const spec = { spectated: PLAYER_A, whep: () => status };
    const overlay = loadOverlay(spec);
    await settle();
    assert.deepEqual(overlay.whepCalls, [PLAYER_A]);

    overlay.advance(14_999);
    await overlay.poll();
    assert.deepEqual(overlay.whepCalls, [PLAYER_A]);

    overlay.advance(1);
    await overlay.poll();
    assert.deepEqual(overlay.whepCalls, [PLAYER_A, PLAYER_A]);
  });
}
