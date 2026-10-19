// node --test src/lib/spec-server-token.test.mjs
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";

const LIB_DIR = dirname(new URL(import.meta.url).pathname);
const SRC_DIR = dirname(LIB_DIR);

// `last` is the function's closing line, preceded by whatever ends it when a
// heredoc inside it has a `}` of its own at the start of a line.
function fn(file, name, last = "\\}") {
  const text = readFileSync(join(LIB_DIR, file), "utf8");
  const m = text.match(new RegExp(`^${name}\\(\\) \\{\\n[\\s\\S]*?^${last}$`, "m"));
  assert.ok(m, `${name}() not found in ${file}`);
  return m[0];
}

function shellScripts(dir) {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) {
      return shellScripts(path);
    }
    return entry.name.endsWith(".sh") ? [path] : [];
  });
}

test("spec_curl sends the pod's token", () => {
  const bin = mkdtempSync(join(tmpdir(), "spec-curl-"));
  writeFileSync(join(bin, "curl"), "#!/usr/bin/env bash\nprintf '%s\\n' \"$@\"\n");
  chmodSync(join(bin, "curl"), 0o755);
  const r = spawnSync(
    "bash",
    ["-c", `${fn("common.sh", "spec_curl")}\nspec_curl --silent http://127.0.0.1:1350/demo/state`],
    {
      encoding: "utf8",
      env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, SPEC_SERVER_TOKEN: "pod-token" },
    },
  );
  assert.equal(r.status, 0, r.stderr);
  const args = r.stdout.trim().split("\n");
  assert.ok(args.includes("Authorization: Bearer pod-token"), args.join(" "));
  assert.equal(args.at(-1), "http://127.0.0.1:1350/demo/state");
});

// Continuation lines are joined so a curl and the spec-server URL it is handed
// on a later line read as one command.
test("every in-pod call to the spec-server goes through spec_curl", () => {
  const bare = [];
  let calls = 0;
  for (const script of shellScripts(SRC_DIR)) {
    const commands = readFileSync(script, "utf8").replace(/\\\n/g, " ").split("\n");
    for (const command of commands) {
      if (/^\s*#/.test(command) || !/SPEC_SERVER_URL|SPEC_BASE|SPEC_SERVER_PORT|:1350\b/.test(command)) {
        continue;
      }
      if (/(?<![\w-])curl(?![\w-])/.test(command)) {
        bare.push(`${relative(SRC_DIR, script)}: ${command.trim()}`);
      }
      if (/\bspec_curl\b/.test(command)) {
        calls++;
      }
    }
  }
  assert.deepEqual(bare, []);
  assert.ok(calls > 20, `only ${calls} spec_curl calls found; the scan is not seeing them`);
});

test("the GSI cfg carries the pod's token, which cs2 posts back in every body", () => {
  const cs2Dir = mkdtempSync(join(tmpdir(), "gsi-cfg-"));
  const r = spawnSync("bash", ["-c", `${fn("hud-manager.sh", "write_gsi_cfg", "EOF\\n\\}")}\nwrite_gsi_cfg`], {
    encoding: "utf8",
    env: { ...process.env, CS2_DIR: cs2Dir, SPEC_SERVER_TOKEN: "pod-token" },
  });
  assert.equal(r.status, 0, r.stderr);
  const cfg = readFileSync(join(cs2Dir, "game/csgo/cfg/gamestate_integration_5stack.cfg"), "utf8");
  assert.match(cfg, /"auth" \{ "token" "pod-token" \}/);
});
