import { demouiBarVisible } from "../cs2/demoui.mjs";

// "visible|score|mean" from a fresh screen grab; "?|?|?" when the screen can't be read.
export async function demouiScoreHandler(_req, res) {
  const bar = await demouiBarVisible();
  const line = bar
    ? `${bar.visible ? 1 : 0}|${bar.score.toFixed(2)}|${bar.mean.toFixed(0)}`
    : "?|?|?";
  const body = Buffer.from(line);
  res.writeHead(200, { "Content-Type": "text/plain", "Content-Length": String(body.length) });
  res.end(body);
}
