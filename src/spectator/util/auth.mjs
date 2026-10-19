import { createHash, timingSafeEqual } from "node:crypto";

function digest(value) {
  return createHash("sha256").update(value).digest();
}

export function tokenMatches(expected, presented) {
  if (typeof presented !== "string" || presented === "") {
    return false;
  }
  return timingSafeEqual(digest(expected), digest(presented));
}

export function bearerToken(req) {
  const match = /^Bearer (\S+)$/.exec(req.headers?.authorization ?? "");
  return match ? match[1] : null;
}

// The socket's own peer, never X-Forwarded-For, which says whatever the caller wrote.
export function fromLoopback(req) {
  const address = req.socket?.remoteAddress ?? "";
  return address === "::1" || /^(::ffff:)?127\./.test(address);
}
