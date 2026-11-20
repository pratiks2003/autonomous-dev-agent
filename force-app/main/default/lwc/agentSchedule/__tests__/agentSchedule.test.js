import {
  computeSchedule,
  nextHeartbeat,
  formatCountdown
} from "c/agentSchedule";

const at = (iso) => new Date(iso).getTime();

describe("c-agent-schedule", () => {
  it("finds the next :15/:45 UTC heartbeat", () => {
    expect(
      new Date(nextHeartbeat(at("2026-11-20T17:33:00Z"))).toISOString()
    ).toBe("2026-11-20T17:45:00.000Z");
    expect(
      new Date(nextHeartbeat(at("2026-11-20T17:50:00Z"))).toISOString()
    ).toBe("2026-11-20T18:15:00.000Z");
  });

  it("formats countdowns", () => {
    expect(formatCountdown(65000)).toBe("01:05");
    expect(formatCountdown(2 * 3600000 + 5 * 60000)).toBe("2h 05m");
  });

  it("assigns the in-flight step to its owner and schedules everyone else", () => {
    const now = at("2026-11-20T17:33:00Z");
    const data = {
      squad: [{ name: "Engineer", lastAt: "2026-11-20T17:15:00Z" }],
      contributions: [{ repo: "acme/w", issueNumber: 7, status: "Forked" }],
      lastRun: { status: "Success", stage: "Shipped" }
    };
    const s = computeSchedule(data, now);
    expect(s.Engineer.state).toBe("working");
    expect(s.Engineer.doing).toContain("write the fix for acme/w#7");
    expect(s.Engineer.at).toBe("23:15 IST");
    expect(s.Scout.state).toBe("waiting");
    expect(s.Maintainer.at).toBe("13:30 IST");
    expect(s.Watchdog.at).toBe("01:30 IST");
    expect(s.Concierge.at).toBe("14:15 IST"); // 23:03 IST: tonight's 21:15 briefing already happened
    expect(s.Verifier.doing).toContain("Waiting for the Engineer");
  });

  it("paces the Publisher to one upstream PR per day", () => {
    const now = at("2026-11-21T10:00:00Z");
    const s = computeSchedule(
      {
        contributions: [
          { repo: "a/b", issueNumber: 1, status: "Review_Passed" }
        ],
        lastPrOpenedAt: "2026-11-21T06:00:00Z"
      },
      now
    );
    expect(s.Publisher.doing).toContain("one upstream PR per 24h");
    expect(s.Publisher.at).toBe("11:45 IST");
  });
});
