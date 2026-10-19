// node --test src/lib/batch-highlights.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";

const LIB_DIR = dirname(new URL(import.meta.url).pathname);
const STEAM_ID = "76561198000000001";

const CURL_STUB = `#!/usr/bin/env bash
url="\${*: -1}"
case "$url" in
  */demo/state) printf '%s' "$STUB_STATE" ;;
  */title)
    while [ $# -gt 0 ]; do
      if [ "$1" = --data ]; then printf '%s' "$2" >"$TITLE_BODY"; fi
      shift
    done
    ;;
esac
`;

// batch-highlights.sh runs after common.sh, which is where spec_curl comes from.
const SPEC_CURL = readFileSync(join(LIB_DIR, "common.sh"), "utf8").match(/^spec_curl\(\) \{\n[\s\S]*?^\}$/m)[0];

function patchTitle(gsiName, currentTitle) {
  const dir = mkdtempSync(join(tmpdir(), "batch-highlights-"));
  writeFileSync(join(dir, "curl"), CURL_STUB);
  chmodSync(join(dir, "curl"), 0o755);
  const titleBody = join(dir, "title.json");
  const r = spawnSync(
    "bash",
    ["-c", `${SPEC_CURL}\n. "$LIB_DIR/batch-highlights.sh"; say() { :; }; patch_title_from_gsi job-1 token "$1" "$2"`, "_", STEAM_ID, currentTitle],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        PATH: `${dir}:${process.env.PATH}`,
        LIB_DIR,
        STATUS_API_BASE: "http://api.invalid",
        SPEC_SERVER_URL: "http://spec.invalid",
        STUB_STATE: JSON.stringify({ gsi: { spec_slots: [{ steam_id: STEAM_ID, name: gsiName }] } }),
        TITLE_BODY: titleBody,
      },
    },
  );
  assert.equal(r.status, 0, r.stderr);
  return JSON.parse(readFileSync(titleBody, "utf8"));
}

test("a player name with a quote, tab or trailing backslash patches the title as valid JSON", () => {
  assert.deepEqual(patchTitle('"clu\tch\\', "Player 1234 · 3K"), { title: '"clu\tch\\ · 3K' });
});
