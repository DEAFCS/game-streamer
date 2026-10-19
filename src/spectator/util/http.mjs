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

const JSON_BODY_LIMIT = 1024 * 1024;

class BodyError extends Error {
  constructor(status, message) {
    super(message);
    this.status = status;
  }
}

export function readBody(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on("data", (c) => {
      size += c.length;
      if (size > limit) {
        req.pause();
        reject(new BodyError(413, "request body too large"));
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", () => reject(new BodyError(400, "request aborted")));
  });
}

// Handlers read fields straight off the body, so anything but a JSON object
// (a literal `null` included) reaches them as an empty one.
export async function readJsonBody(req) {
  const raw = await readBody(req, JSON_BODY_LIMIT);
  if (!raw) {
    return {};
  }
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new BodyError(400, "invalid json");
  }
  return parsed !== null && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
}

export function sendBodyError(req, res, err) {
  if (err.status === 413) {
    res.on("finish", () => req.destroy());
  }
  sendJson(res, err.status, { error: err.message });
}
