import { createElement } from "lwc";
import AgentSystemMap from "c/agentSystemMap";

const recent = new Date(Date.now() - 5 * 60000).toISOString();
const DATA = {
  squad: [
    { name: "Scout", lastAt: recent },
    { name: "Engineer", lastAt: "2026-01-01T00:00:00.000Z" }
  ],
  events: [
    { id: "e1", agent: "Scout", message: "Picked acme/widgets#7", at: recent }
  ],
  lastRun: { status: "Success", stage: "Shipped", questTitle: "Add clamp" },
  contributions: [
    {
      id: "c1",
      repo: "acme/widgets",
      issueNumber: 7,
      status: "Forked",
      issueUrl: "https://github.com/acme/widgets/issues/7"
    }
  ]
};

const flush = () => Promise.resolve();

describe("c-agent-system-map", () => {
  beforeAll(() => {
    global.requestAnimationFrame = () => 1;
    global.cancelAnimationFrame = () => {};
  });
  afterEach(() => {
    while (document.body.firstChild)
      document.body.removeChild(document.body.firstChild);
  });

  it("highlights active agents and shows the live caption", async () => {
    const el = createElement("c-agent-system-map", { is: AgentSystemMap });
    el.data = DATA;
    document.body.appendChild(el);
    await flush();
    const root = el.shadowRoot;
    expect(root.querySelectorAll("g.node").length).toBe(18);
    expect(root.querySelectorAll("g.node-live").length).toBe(1);
    expect(root.querySelectorAll("path.edge-on").length).toBeGreaterThan(0);
    expect(root.querySelectorAll("circle.packet").length).toBeGreaterThan(0);
    expect(root.querySelector(".cap-msg").textContent).toContain(
      "acme/widgets#7"
    );
  });

  it("switches to the guided tour and steps through scenes", async () => {
    const el = createElement("c-agent-system-map", { is: AgentSystemMap });
    el.data = DATA;
    document.body.appendChild(el);
    await flush();
    el.shadowRoot.querySelectorAll(".seg")[1].click();
    await flush();
    expect(el.shadowRoot.querySelector(".cap-label").textContent).toBe(
      "1 / 12"
    );
    el.shadowRoot.querySelectorAll(".ctl")[2].click();
    await flush();
    expect(el.shadowRoot.querySelector(".cap-label").textContent).toBe(
      "2 / 12"
    );
    expect(el.shadowRoot.querySelectorAll(".dot").length).toBe(12);
  });
});
