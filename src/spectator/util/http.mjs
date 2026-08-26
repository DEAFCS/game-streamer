const CORS_HEADERS = {
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
