import { createElement } from "lwc";
import AgentCommandCenter from "c/agentCommandCenter";
import getDashboard from "@salesforce/apex/AgentCommandCenterController.getDashboard";

jest.mock(
  "@salesforce/apex/AgentCommandCenterController.getDashboard",
  () => {
    const { createApexTestWireAdapter } = require("@salesforce/sfdx-lwc-jest");
    return { default: createApexTestWireAdapter(jest.fn()) };
  },
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/AgentCommandCenterController.triggerManualRun",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/AgentCommandCenterController.enqueueCustomQuest",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock("@salesforce/user/isGuest", () => ({ default: true }), {
  virtual: true
});

const DATA = {
  owner: "pratiks2003",
  repo: "agent-forge",
  repoUrl: "https://github.com/pratiks2003/agent-forge",
  model: "sfdc_ai__DefaultBedrockAnthropicClaude4Sonnet",
  streak: 42,
  commits: 120,
  prs: 40,
  reviews: 35,
  issues: 30,
  totalContributions: 225,
  days: [
    ["2026-11-18", 2],
    ["2026-11-19", 4],
    ["2026-11-20", 1]
  ],
  latestRelease: "v1.6.0",
  shippedTotal: 37,
  successRate: 97,
  lastRun: {
    id: "r1",
    status: "Success",
    stage: "Shipped",
    runDate: "2026-11-20T08:03:00.000Z"
  },
  runs: [
    {
      id: "r1",
      status: "Success",
      stage: "Shipped",
      runDate: "2026-11-20T08:03:00.000Z",
      questTitle: "Add debounce"
    }
  ],
  shipped: [
    {
      id: "q1",
      title: "Add debounce helper",
      questType: "Feature",
      status: "Shipped",
      prNumber: 7,
      reasoning: "why",
      review: "ok"
    }
  ],
  active: [],
  planned: [
    {
      id: "q2",
      title: "Add LRU cache",
      questType: "Challenge",
      status: "Queued",
      priority: 1,
      issueNumber: 9
    }
  ],
  isAdmin: false
};

const flush = () => Promise.resolve();

describe("c-agent-command-center", () => {
  afterEach(() => {
    while (document.body.firstChild)
      document.body.removeChild(document.body.firstChild);
    jest.clearAllMocks();
  });

  it("renders telemetry, pipeline, heatmap and kanban from Apex data", async () => {
    const el = createElement("c-agent-command-center", {
      is: AgentCommandCenter
    });
    document.body.appendChild(el);
    getDashboard.emit(DATA);
    await flush();

    const root = el.shadowRoot;
    expect(root.querySelector(".streak-num").textContent).toBe("42");
    expect(root.querySelectorAll(".node-done").length).toBe(6);
    expect(root.querySelectorAll(".axes li").length).toBe(4);
    expect(root.querySelectorAll("rect.cell").length).toBe(3);
    expect(root.querySelector(".rb-r").textContent).toBe("v1.6.0");
    expect(root.querySelectorAll(".card").length).toBe(2);
    expect(root.querySelector(".admin")).toBeNull();
  });

  it("expands AI reasoning logs on demand", async () => {
    const el = createElement("c-agent-command-center", {
      is: AgentCommandCenter
    });
    document.body.appendChild(el);
    getDashboard.emit(DATA);
    await flush();
    el.shadowRoot.querySelector(".toggle").click();
    await flush();
    expect(el.shadowRoot.querySelectorAll(".logs pre").length).toBe(2);
  });

  it("shows an error banner when Apex fails", async () => {
    const el = createElement("c-agent-command-center", {
      is: AgentCommandCenter
    });
    document.body.appendChild(el);
    getDashboard.error({ message: "boom" });
    await flush();
    expect(el.shadowRoot.querySelector(".banner-fail")).not.toBeNull();
  });
});
