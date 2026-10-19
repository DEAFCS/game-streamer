// node --test motion/src/avatar-url.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";

import { renderableAvatarUrl } from "./avatar-url.ts";

test("steam and uploaded avatars render", () => {
  for (const url of [
    "https://avatars.steamstatic.com/abc_full.jpg",
    "https://api.5stack.gg/avatars/players/76561198000000009-a1b2c3.png",
    "http://api.lan:5585/avatars/players/76561198000000009-a1b2c3.png",
  ]) {
    assert.equal(renderableAvatarUrl(url), url);
  }
});

test("anything but a web URL falls back to the initial", () => {
  for (const url of [
    "file:///etc/passwd",
    "javascript:alert(1)",
    "data:image/svg+xml,<svg/>",
    "ftp://example.com/a.png",
    "avatars/players/76561198000000009-a1b2c3.png",
    "",
    null,
  ]) {
    assert.equal(renderableAvatarUrl(url), null, String(url));
  }
});
