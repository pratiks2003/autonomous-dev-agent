/**
 * Single source of truth for "when does each agent run next, and what is it doing?".
 * Mirrors the real triggers in Salesforce / GitHub:
 *   Maintainer  — DailyAgentOrchestrator, 08:00 UTC (13:30 IST)
 *   Concierge   — briefing on the first heartbeat after 14:00 IST and 21:00 IST
 *   Scout       — heartbeat, only when nothing is in flight, at most every 3h
 *   Engineer / Verifier / Reviewer / Publisher — heartbeat, when the in-flight contribution is at their step
 *   Watchdog    — GitHub Actions, 20:00 UTC (01:30 IST)
 * Heartbeats fire at :15 and :45 UTC (= :45 and :15 IST).
 */
const MIN = 60000;
const IST = 330 * MIN;
const ACTIVE_MS = 20 * MIN;
const SCOUT_COOLDOWN_MS = 3 * 60 * MIN;
const PR_PACE_MS = 24 * 60 * MIN;

const IN_FLIGHT = [
  "Selected",
  "Forked",
  "Fix_Ready",
  "Verifying",
  "Verified",
  "Review_Passed"
];
const OWNER = {
  Selected: "Engineer",
  Forked: "Engineer",
  Fix_Ready: "Verifier",
  Verifying: "Verifier",
  Verified: "Reviewer",
  Review_Passed: "Publisher"
};
const NEXT_STEP = {
  Selected: "fork the repository",
  Forked: "choose the files and write the fix",
  Fix_Ready: "start the project's test suite",
  Verifying: "collect the test results",
  Verified: "review the change",
  Review_Passed: "open the upstream pull request"
};

export function nextHeartbeat(now) {
  const d = new Date(now);
  const base = Date.UTC(
    d.getUTCFullYear(),
    d.getUTCMonth(),
    d.getUTCDate(),
    d.getUTCHours()
  );
  for (const m of [15, 45, 75]) {
    const t = base + m * MIN;
    if (t > now) return t;
  }
  return base + 75 * MIN;
}

export function heartbeatAtOrAfter(t) {
  return nextHeartbeat(t - 1);
}

export function nextDailyUtc(now, h, m) {
  const d = new Date(now);
  let t = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate(), h, m);
  if (t <= now) t += 24 * 60 * MIN;
  return t;
}

export function formatCountdown(ms) {
  if (ms <= 0) return "any moment";
  const s = Math.floor(ms / 1000);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) return `${h}h ${String(m).padStart(2, "0")}m`;
  return `${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
}

export function istTime(t) {
  return new Date(t + IST).toISOString().substring(11, 16) + " IST";
}

function inFlight(data) {
  return (data?.contributions || []).find((c) => IN_FLIGHT.includes(c.status));
}

/**
 * Returns { [agentName]: { state: 'working'|'scheduled'|'waiting', nextAt, countdown, at, doing } }
 */
export function computeSchedule(data, now) {
  const out = {};
  const lastAt = {};
  for (const a of data?.squad || [])
    lastAt[a.name] = a.lastAt ? new Date(a.lastAt).getTime() : null;
  const working = (name) => lastAt[name] && now - lastAt[name] < ACTIVE_MS;
  const hb = nextHeartbeat(now);
  const daily = nextDailyUtc(now, 8, 0);
  const flight = inFlight(data);
  const issue = flight ? `${flight.repo}#${flight.issueNumber}` : null;
  const owner = flight ? OWNER[flight.status] : null;

  const make = (name, nextAt, doing, forceState) => {
    let state = forceState || (nextAt ? "scheduled" : "waiting");
    if (!forceState && working(name)) state = "working";
    out[name] = {
      state,
      nextAt,
      countdown: nextAt ? formatCountdown(nextAt - now) : null,
      at: nextAt ? istTime(nextAt) : null,
      doing
    };
  };

  // Maintainer — the daily mission
  const running = data?.lastRun?.status === "Running";
  make(
    "Maintainer",
    daily,
    running
      ? `Running the daily mission (stage: ${data.lastRun.stage || "starting"}).`
      : "Daily mission on agent-forge: pick or invent a quest, then code, PR, review and auto-merge.",
    running ? "working" : null
  );

  // Concierge — briefing on the first heartbeat after 14:00 IST (08:45 UTC) and 21:00 IST (15:45 UTC)
  const morning = nextDailyUtc(now, 8, 45);
  const evening = nextDailyUtc(now, 15, 45);
  make(
    "Concierge",
    Math.min(morning, evening),
    evening < morning
      ? "Writes the evening briefing from today's activity log."
      : "Writes today's briefing after the 13:30 mission."
  );

  // Watchdog — GitHub Actions
  make(
    "Watchdog",
    nextDailyUtc(now, 20, 0),
    "Checks today's GitHub contributions; runs a backup quest only if the day is still empty."
  );

  // Scout
  if (flight) {
    make(
      "Scout",
      null,
      `Standing by — the squad is busy with ${issue}. Scouting resumes when it is done.`
    );
  } else {
    const radar = (data?.contributions || []).find(
      (c) => c.status === "Discovered"
    );
    let at = hb;
    if (!radar && lastAt.Scout)
      at = Math.max(hb, heartbeatAtOrAfter(lastAt.Scout + SCOUT_COOLDOWN_MS));
    make(
      "Scout",
      at,
      radar
        ? `Will promote ${radar.repo}#${radar.issueNumber} from the radar.`
        : "Will scan public GitHub for good-first issues in active, well-starred repos."
    );
  }

  // Pipeline roles (open source), with the daily mission as their fallback schedule
  const dailyDoing = {
    Engineer: "Next: writes code + tests in the 13:30 daily mission.",
    Reviewer: "Next: reviews the daily mission PR at 13:30.",
    Publisher: "Next: opens the daily mission PR at 13:30.",
    Verifier: null
  };
  for (const name of ["Engineer", "Verifier", "Reviewer", "Publisher"]) {
    if (owner === name) {
      let at = hb;
      let doing = `Will ${NEXT_STEP[flight.status]} for ${issue}.`;
      if (name === "Publisher" && data?.lastPrOpenedAt) {
        const allowed = new Date(data.lastPrOpenedAt).getTime() + PR_PACE_MS;
        if (allowed > now) {
          at = heartbeatAtOrAfter(allowed);
          doing = `Approved fix for ${issue} is queued — pacing allows one upstream PR per 24h.`;
        }
      }
      make(name, at, doing);
    } else if (dailyDoing[name]) {
      make(
        name,
        daily,
        flight
          ? `Waiting for the ${owner} on ${issue}. ${dailyDoing[name]}`
          : dailyDoing[name]
      );
    } else {
      make(
        name,
        null,
        flight
          ? `Waiting for the ${owner} to finish ${issue}.`
          : "Waiting for a fix to test."
      );
    }
  }
  return out;
}

export function ownerOfCurrentWork(data) {
  const f = inFlight(data);
  return f ? { owner: OWNER[f.status], contribution: f } : null;
}
