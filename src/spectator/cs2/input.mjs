import { run } from "../util/run.mjs";
import { findCs2Window } from "./window.mjs";

// XTest keystrokes land on whatever currently holds X input focus -- xdotool's
// `--window` (XSendEvent) is filtered by cs2 and dropped, so targeting is not
// an option. The whole spectator input path therefore silently no-ops the
// moment focus leaves cs2, while anything driven over HTTP (the hud) keeps
// working -- which is exactly how this presents.
//
// Observed on a live pod: focus had moved to Steam's Friends List and cs2's
// window was IsUnMapped, so it could not be focused back at all. Recovery is
// map-then-focus, and windowfocus is XSetInputFocus so it does NOT restack --
// unlike windowactivate, which would raise cs2 above the HUD overlay.
let lastFocusWarning = "";

async function isMapped(win) {
  const info = await run(["xwininfo", "-id", win]);
  return /Map State:\s*IsViewable/.test(info.stdout);
}

async function focusCs2(win) {
  const current = await run(["xdotool", "getwindowfocus"]);
  const focused = current.code === 0 ? current.stdout.trim() : "";

  if (focused === win) {
    lastFocusWarning = "";
    return;
  }

  // Logged once per distinct value: a persistent thief would otherwise write a
  // line for every key we send.
  if (lastFocusWarning !== focused) {
    lastFocusWarning = focused;
    process.stderr.write(
      `[spec-input] focus was ${focused || "unset"}, expected cs2 ${win} — recovering\n`,
    );
  }

  // cs2 runs -noborder at exactly screen size, so it behaves as borderless
  // fullscreen and withdraws its own window when it loses focus. Nothing maps
  // it back -- there is no window manager -- and XSetInputFocus on an unmapped
  // window is a BadMatch, so focus can never return on its own and every key
  // after that goes to whatever stole it. Map it first, then focus.
  if (!(await isMapped(win))) {
    process.stderr.write(`[spec-input] cs2 window ${win} unmapped — remapping\n`);
    await run(["xdotool", "windowmap", "--sync", win]);
  }

  await run(["xdotool", "windowfocus", "--sync", win]);
}

// Map + focus cs2's window without sending a key. Anything that only LOOKS at the
// screen (the demo-bar watcher) otherwise sees the empty root window for as long
// as cs2 stays withdrawn. False when there's no cs2 window.
export async function revealCs2() {
  const win = await findCs2Window();
  if (win === null) return false;
  await focusCs2(win);
  return true;
}

export async function focusState() {
  const win = await findCs2Window();
  const current = await run(["xdotool", "getwindowfocus"]);
  const focused = current.code === 0 ? current.stdout.trim() : null;

  let focusedName = null;
  if (focused) {
    const name = await run(["xdotool", "getwindowname", focused]);
    focusedName = name.code === 0 ? name.stdout.trim() : null;
  }

  return {
    cs2_window: win,
    cs2_mapped: win === null ? null : await isMapped(win),
    focused_window: focused,
    focused_name: focusedName,
    cs2_has_focus: win !== null && focused === win,
  };
}

export async function sendKey(key) {
  if ((await findCs2Window()) === null) return false;
  await run(["xdotool", "key", "--clearmodifiers", key]);
  return true;
}

export async function sendConsoleCommand(cmd) {
  if ((await findCs2Window()) === null) return false;
  await run(["xdotool", "key", "--clearmodifiers", "grave"]);
  await new Promise((r) => setTimeout(r, 80));
  await run(["xdotool", "type", "--delay", "20", cmd]);
  await new Promise((r) => setTimeout(r, 40));
  await run(["xdotool", "key", "--clearmodifiers", "Return"]);
  await new Promise((r) => setTimeout(r, 60));
  await run(["xdotool", "key", "--clearmodifiers", "grave"]);
  return true;
}
