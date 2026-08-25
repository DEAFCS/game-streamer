// Exported so raw (non-sendJson) handlers -- e.g. camera.mjs's snapshot
// proxy, which streams a JPEG rather than JSON -- can spread these into
// their own res.writeHead() calls. Every status code needs them, not
// just 200: the hud-manager overlay window's fetch() (a different
// origin, http://localhost:1349, than spec-server's http://127.0.0.1:1350)
// fails the whole request outright ("Failed to fetch", never resolving
// to a Response at all) if the origin sending it back is missing this,
// regardless of what status code came back. See DEAFCS/deafcs-web#91.
export const CORS_HEADERS = {
  "Access-Control-Allow-Origin":  "*",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

export function sendJson(res, code, obj) {
  const body = Buffer.from(JSON.stringify(obj));
  res.writeHead(code, {
    "Content-Type":   "application/json",
    "Content-Length": String(body.length),
    ...CORS_HEADERS,
  });
  res.end(body);
}

export function readJsonBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      const raw = Buffer.concat(chunks).toString("utf8");
      if (!raw) return resolve({});
      try { resolve(JSON.parse(raw)); }
      catch { reject(new Error("invalid json")); }
    });
    req.on("error", reject);
  });
}
