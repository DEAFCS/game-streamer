// What the api tells a render pod to do between lineups
// (POST nade-render-queue/:match_id/next). The pod acts on whatever comes back,
// so anything it does not recognise reads as "stop": an api that has moved on
// must never leave a pod filming a queue it cannot understand.

const MAP_NAME = /^[A-Za-z0-9_][A-Za-z0-9_./-]{0,127}$/;
const FORBIDDEN = /[\t\n\r\0]/;

export const NEXT_WAIT_MIN_SECONDS = 1;
export const NEXT_WAIT_MAX_SECONDS = 30;

function validJob(job) {
  return (
    typeof job?.job_id === "string"
    && typeof job?.token === "string"
    && job.job_id.length > 0
    && job.token.length > 0
    && !FORBIDDEN.test(job.job_id)
    && !FORBIDDEN.test(job.token)
    && job.spec !== null
    && typeof job.spec === "object"
  );
}

// -> { action: "render"|"map"|"wait"|"done", map, seconds, jobs }
export function nadeNext(body) {
  const done = { action: "done", map: "", seconds: 0, jobs: [] };

  if (body === null || typeof body !== "object") {
    return done;
  }

  switch (body.action) {
    case "render": {
      const jobs = Array.isArray(body.jobs) ? body.jobs.filter(validJob) : [];
      // Nothing usable to film is not a reason to stop: ask again.
      return jobs.length > 0
        ? { action: "render", map: "", seconds: 0, jobs }
        : { action: "wait", map: "", seconds: NEXT_WAIT_MIN_SECONDS, jobs: [] };
    }
    case "map": {
      const map = typeof body.map_name === "string" ? body.map_name : "";
      return MAP_NAME.test(map)
        ? { action: "map", map, seconds: 0, jobs: [] }
        : done;
    }
    case "wait": {
      const asked = Number(body.seconds);
      const seconds = Number.isFinite(asked)
        ? Math.min(NEXT_WAIT_MAX_SECONDS, Math.max(NEXT_WAIT_MIN_SECONDS, Math.round(asked)))
        : NEXT_WAIT_MIN_SECONDS;
      return { action: "wait", map: "", seconds, jobs: [] };
    }
    default:
      return done;
  }
}
