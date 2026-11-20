import { LightningElement, api, wire } from "lwc";
import { refreshApex } from "@salesforce/apex";
import isGuest from "@salesforce/user/isGuest";
import getDashboard from "@salesforce/apex/AgentCommandCenterController.getDashboard";
import triggerManualRun from "@salesforce/apex/AgentCommandCenterController.triggerManualRun";
import enqueueCustomQuest from "@salesforce/apex/AgentCommandCenterController.enqueueCustomQuest";
import askMissionControl from "@salesforce/apex/AgentCommandCenterController.askMissionControl";

const STAGES = [
  { key: "context", label: "Context", hint: "GraphQL repo scan" },
  { key: "quest", label: "Quest", hint: "Plan / self-generate" },
  { key: "code", label: "Code", hint: "RAG + Einstein LLM" },
  { key: "pr", label: "Pull Request", hint: "Branch · 2 commits" },
  { key: "review", label: "Review", hint: "AI code review" },
  { key: "merge", label: "Merge", hint: "CI-gated squash" }
];
const DONE_BY_STAGE = { Queued: 0, Context: 2, CodeGen: 3, Shipped: 6 };
const FAIL_INDEX = { Queued: 0, Context: 0, CodeGen: 2, Ship: 3 };
const LEVELS = ["#161b22", "#0e4429", "#006d32", "#26a641", "#39d353"];
const MONTHS = [
  "Jan",
  "Feb",
  "Mar",
  "Apr",
  "May",
  "Jun",
  "Jul",
  "Aug",
  "Sep",
  "Oct",
  "Nov",
  "Dec"
];
const QUEST_TYPES = ["Feature", "Unit_Test", "Refactor", "Docs", "Challenge"];
const CELL = 13;
const AGENT_META = {
  Concierge: { emoji: "🧭", color: "#f0b429" },
  Scout: { emoji: "🔎", color: "#58a6ff" },
  Engineer: { emoji: "🛠️", color: "#39d353" },
  Verifier: { emoji: "🧪", color: "#2dd4bf" },
  Reviewer: { emoji: "🔍", color: "#f778ba" },
  Publisher: { emoji: "🚀", color: "#a371f7" },
  Maintainer: { emoji: "🧰", color: "#ff8a00" },
  Watchdog: { emoji: "🛟", color: "#8b949e" }
};
const OSS_STEPS = ["Scout", "Fork", "Fix", "Tests", "Review", "PR", "Merged"];
const OSS_INDEX = {
  Discovered: 0,
  Selected: 1,
  Forked: 2,
  Fix_Ready: 3,
  Verifying: 3,
  Verified: 4,
  Review_Passed: 5,
  PR_Open: 6,
  Merged: 7,
  Closed: 6,
  Failed: -1
};
const OSS_LABEL = {
  Discovered: "On the radar",
  Selected: "Selected by Scout",
  Forked: "Engineer working",
  Fix_Ready: "Fix committed",
  Verifying: "Tests running",
  Verified: "Tests passed",
  Review_Passed: "Approved · queued to publish",
  PR_Open: "PR open upstream",
  Merged: "Merged 🎉",
  Closed: "Closed by maintainer",
  Failed: "Abandoned"
};
const REFRESH_MS = 60000;
const IST_OFFSET_MS = 330 * 60000; // India Standard Time = UTC+05:30 (no DST)

/** ISO-like string shifted to IST: "yyyy-MM-ddTHH:mm:ss". */
function istIso(value) {
  return new Date(new Date(value).getTime() + IST_OFFSET_MS).toISOString();
}

export default class AgentCommandCenter extends LightningElement {
  @api githubUsername = "pratiks2003";
  @api repoName = "agent-forge";

  data;
  error;
  wiredResult;
  istTime = "--:--:--";
  istDate = "";
  utcShort = "";
  countdown = "";
  expanded = {};
  busy = false;
  toast;
  questTitle = "";
  questDescription = "";
  questType = "Feature";
  questPriority = "1";
  chatOpen = false;
  chatInput = "";
  chatBusy = false;
  chatSession;
  chatMessages = [
    {
      id: "w",
      cls: "msg msg-agent",
      text: "Mission Control online. Ask me for a status briefing, to run today's mission, queue a quest, or take on an open-source issue."
    }
  ];
  _clock;
  _refresh;

  @wire(getDashboard)
  wired(result) {
    this.wiredResult = result;
    if (result.data) {
      this.data = result.data;
      this.error = undefined;
    } else if (result.error) {
      this.error = result.error;
    }
  }

  connectedCallback() {
    this.tick();
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._clock = setInterval(() => this.tick(), 1000);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._refresh = setInterval(() => this.refresh(), REFRESH_MS);
  }

  disconnectedCallback() {
    clearInterval(this._clock);
    clearInterval(this._refresh);
  }

  tick() {
    const now = new Date();
    const ist = istIso(now);
    this.istTime = ist.substring(11, 19);
    this.istDate = ist.substring(0, 10);
    this.utcShort = now.toISOString().substring(11, 16);
    const next = new Date(
      Date.UTC(
        now.getUTCFullYear(),
        now.getUTCMonth(),
        now.getUTCDate(),
        8,
        0,
        0
      )
    );
    if (next <= now) next.setUTCDate(next.getUTCDate() + 1);
    const s = Math.floor((next - now) / 1000);
    const pad = (n) => String(n).padStart(2, "0");
    this.countdown = `${pad(Math.floor(s / 3600))}:${pad(Math.floor((s % 3600) / 60))}:${pad(s % 60)}`;
  }

  refresh() {
    return this.wiredResult ? refreshApex(this.wiredResult) : Promise.resolve();
  }

  // ------------------------------------------------------------ identity
  get owner() {
    return this.data?.owner || this.githubUsername;
  }
  get repo() {
    return this.data?.repo || this.repoName;
  }
  get repoUrl() {
    return (
      this.data?.repoUrl || `https://github.com/${this.owner}/${this.repo}`
    );
  }
  get profileUrl() {
    return `https://github.com/${this.owner}`;
  }
  get modelLabel() {
    const m = this.data?.model || "";
    return (
      m.replace("sfdc_ai__Default", "").replace(/([a-z])([A-Z])/g, "$1 $2") ||
      "Einstein"
    );
  }
  get isLoading() {
    return !this.data && !this.error;
  }
  get errorMessage() {
    return this.error?.body?.message || "Unable to load telemetry.";
  }

  // ------------------------------------------------------------ status
  get lastRun() {
    return this.data?.lastRun;
  }
  get isRunning() {
    return this.lastRun?.status === "Running";
  }
  get statusLabel() {
    if (!this.lastRun) return "Awaiting first run";
    if (this.isRunning) return `Running · ${this.lastRun.stage || "starting"}`;
    if (this.lastRun.status === "Failed")
      return "Last run failed · watchdog armed";
    return "Autonomous · Online";
  }
  get statusClass() {
    if (!this.lastRun) return "pill pill-idle";
    if (this.isRunning) return "pill pill-run";
    if (this.lastRun.status === "Failed") return "pill pill-fail";
    return "pill pill-ok";
  }
  get lastRunAgo() {
    return this.lastRun?.runDate ? this.ago(this.lastRun.runDate) : "never";
  }

  // ------------------------------------------------------------ hero
  get streak() {
    return this.data?.streak || 0;
  }
  get streakLabel() {
    return this.streak === 1 ? "day streak" : "day streak";
  }
  get flameClass() {
    return this.streak >= 30 ? "flame flame-hot" : "flame";
  }
  get totalContributions() {
    return this.fmt(this.data?.totalContributions || 0);
  }
  get shippedTotal() {
    return this.data?.shippedTotal || 0;
  }
  get successRate() {
    return this.data?.successRate ?? 0;
  }
  get successStyle() {
    return `--pct:${this.successRate}`;
  }
  get latestRelease() {
    return this.data?.latestRelease || "pre-release";
  }
  get releaseUrl() {
    return this.data?.latestRelease
      ? `${this.repoUrl}/releases/tag/${this.data.latestRelease}`
      : `${this.repoUrl}/releases`;
  }
  get releaseAgo() {
    return this.data?.latestReleaseDate
      ? this.ago(this.data.latestReleaseDate)
      : "weekly cadence";
  }

  // ------------------------------------------------------------ pipeline
  get pipeline() {
    const run = this.lastRun;
    const done = run ? (DONE_BY_STAGE[run.stage] ?? 0) : 0;
    const failAt =
      run?.status === "Failed" ? (FAIL_INDEX[run.stage] ?? done) : -1;
    return STAGES.map((s, i) => {
      let state = "todo";
      if (failAt === i) state = "fail";
      else if (i < done && failAt < 0) state = "done";
      else if (failAt > i) state = "done";
      else if (this.isRunning && i === done) state = "live";
      return {
        ...s,
        index: i + 1,
        nodeClass: `node node-${state}`,
        linkClass:
          i < STAGES.length - 1
            ? `link link-${state === "done" ? "done" : state === "live" ? "live" : "todo"}`
            : "link-none",
        showLink: i < STAGES.length - 1
      };
    });
  }

  // ------------------------------------------------------------ 4-axis activity
  get axes() {
    const d = this.data || {};
    const raw = [
      {
        key: "commits",
        label: "Commits",
        value: d.commits || 0,
        color: "#39d353"
      },
      {
        key: "prs",
        label: "Pull requests",
        value: d.prs || 0,
        color: "#a371f7"
      },
      {
        key: "reviews",
        label: "Code review",
        value: d.reviews || 0,
        color: "#f778ba"
      },
      { key: "issues", label: "Issues", value: d.issues || 0, color: "#58a6ff" }
    ];
    const total = raw.reduce((a, b) => a + b.value, 0) || 1;
    return raw.map((a) => {
      const pct = Math.round((100 * a.value) / total);
      return {
        ...a,
        pct,
        display: this.fmt(a.value),
        barStyle: `width:${Math.max(pct, 2)}%;background:${a.color}`,
        dotStyle: `background:${a.color}`
      };
    });
  }

  /** GitHub-style activity overview cross: review (top), issues (right), PRs (bottom), commits (left). */
  get radar() {
    const by = {};
    this.axes.forEach((a) => (by[a.key] = a.pct / 100));
    const c = 90;
    const r = 70;
    const s = (v) => Math.max(v, 0.04) * r;
    const pts = [
      [c, c - s(by.reviews)],
      [c + s(by.issues), c],
      [c, c + s(by.prs)],
      [c - s(by.commits), c]
    ];
    return {
      polygon: pts.map((p) => p.join(",")).join(" "),
      dots: pts.map((p, i) => ({ id: i, cx: p[0], cy: p[1] }))
    };
  }

  // ------------------------------------------------------------ heatmap
  get heatmap() {
    const days = (this.data?.days || []).map((d) => ({
      date: d[0],
      count: Number(d[1]) || 0
    }));
    const series = days.length ? days : this.placeholderDays();
    const max = Math.max(1, ...series.map((d) => d.count));
    const firstDow = new Date(series[0].date + "T00:00:00Z").getUTCDay();
    const cells = [];
    const months = [];
    let lastMonth = -1;
    series.forEach((d, i) => {
      const idx = i + firstDow;
      const col = Math.floor(idx / 7);
      const row = idx % 7;
      const level =
        d.count === 0 ? 0 : Math.min(4, Math.ceil((4 * d.count) / max));
      cells.push({
        key: d.date,
        x: col * CELL,
        y: row * CELL,
        fill: days.length ? LEVELS[level] : "#161b22",
        title: `${d.count} contribution${d.count === 1 ? "" : "s"} on ${d.date}`
      });
      const m = Number(d.date.substring(5, 7)) - 1;
      if (row === 0 && m !== lastMonth) {
        months.push({ key: `${d.date}-m`, x: col * CELL, label: MONTHS[m] });
        lastMonth = m;
      }
    });
    const cols = Math.ceil((series.length + firstDow) / 7);
    return {
      cells,
      months,
      width: cols * CELL,
      viewBox: `0 -16 ${cols * CELL} ${7 * CELL + 16}`
    };
  }

  get hasHeatmapData() {
    return (this.data?.days || []).length > 0;
  }

  get legend() {
    return LEVELS.map((c, i) => ({ key: `l${i}`, style: `background:${c}` }));
  }

  placeholderDays() {
    const out = [];
    const end = new Date();
    for (let i = 364; i >= 0; i--) {
      const d = new Date(end.getTime() - i * 86400000);
      out.push({ date: d.toISOString().substring(0, 10), count: 0 });
    }
    return out;
  }

  // ------------------------------------------------------------ kanban
  decorate(cards, column) {
    return (cards || []).map((c) => ({
      ...c,
      typeLabel: (c.questType || "Feature").replace("_", " "),
      typeClass: `tag tag-${(c.questType || "Feature").toLowerCase()}`,
      issueLabel: c.issueNumber ? `#${c.issueNumber}` : "unpublished",
      prLabel: c.prNumber ? `PR #${c.prNumber}` : null,
      shortSha: c.commitSha ? c.commitSha.substring(0, 7) : null,
      when: c.shippedAt ? this.ago(c.shippedAt) : null,
      isOpen: !!this.expanded[c.id],
      toggleLabel: this.expanded[c.id]
        ? "Hide agent logs"
        : "Show AI reasoning & review",
      hasLogs: !!(c.reasoning || c.review),
      statusLabel: c.status === "Reviewed" ? "Auto-merge armed" : c.status,
      cardClass: `card card-${column}`,
      priorityLabel: `P${c.priority || 3}`
    }));
  }
  get shipped() {
    return this.decorate(this.data?.shipped, "shipped");
  }
  get active() {
    return this.decorate(this.data?.active, "active");
  }
  get planned() {
    return this.decorate(this.data?.planned, "planned");
  }
  get shippedCount() {
    return this.shipped.length;
  }
  get activeCount() {
    return this.active.length;
  }
  get plannedCount() {
    return this.planned.length;
  }
  get hasShipped() {
    return this.shipped.length > 0;
  }
  get hasActive() {
    return this.active.length > 0;
  }
  get hasPlanned() {
    return this.planned.length > 0;
  }

  handleToggle(event) {
    const id = event.currentTarget.dataset.id;
    this.expanded = { ...this.expanded, [id]: !this.expanded[id] };
  }

  // ------------------------------------------------------------ runs timeline
  get runs() {
    return (this.data?.runs || []).slice(0, 14).map((r) => ({
      ...r,
      dotClass: `run-dot run-${(r.status || "").toLowerCase()}`,
      label:
        r.status === "Self_Generated_Quest" ? "Shipped · self-quest" : r.status,
      date: r.runDate
        ? istIso(r.runDate).substring(0, 16).replace("T", " ") + " IST"
        : "",
      quest: r.questTitle || "—",
      hasError: !!r.error
    }));
  }
  get hasRuns() {
    return this.runs.length > 0;
  }

  // ------------------------------------------------------------ admin
  get showAdmin() {
    return !isGuest && this.data?.isAdmin;
  }
  get typeOptions() {
    return QUEST_TYPES.map((t) => ({
      value: t,
      label: t.replace("_", " "),
      selected: t === this.questType
    }));
  }
  get priorityOptions() {
    return ["1", "2", "3", "4", "5"].map((p) => ({
      value: p,
      label: `P${p}`,
      selected: p === this.questPriority
    }));
  }
  get runDisabled() {
    return this.busy || this.isRunning;
  }
  get queueDisabled() {
    return this.busy || !this.questTitle.trim();
  }

  handleInput(event) {
    this[event.target.dataset.field] = event.target.value;
  }

  async handleRunNow() {
    this.busy = true;
    try {
      await triggerManualRun();
      this.flash("Run started — watch the pipeline light up.", "ok");
      await this.refresh();
    } catch (e) {
      this.flash(e?.body?.message || "Could not start run.", "fail");
    } finally {
      this.busy = false;
    }
  }

  async handleQueueQuest() {
    this.busy = true;
    try {
      await enqueueCustomQuest({
        title: this.questTitle.trim(),
        description: this.questDescription,
        questType: this.questType,
        priority: Number(this.questPriority)
      });
      this.questTitle = "";
      this.questDescription = "";
      const area = this.template.querySelector(
        'textarea[data-field="questDescription"]'
      );
      if (area) area.value = "";
      this.flash("Quest queued — publishing to GitHub as an issue.", "ok");
      await this.refresh();
    } catch (e) {
      this.flash(e?.body?.message || "Could not queue quest.", "fail");
    } finally {
      this.busy = false;
    }
  }

  flash(message, kind) {
    this.toast = { message, cls: `toast toast-${kind}` };
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    setTimeout(() => {
      this.toast = undefined;
    }, 4500);
  }

  // ------------------------------------------------------------ briefing
  get hasBriefing() {
    return !!this.data?.briefingHeadline;
  }
  get briefingHeadline() {
    return this.data?.briefingHeadline;
  }
  get briefingBullets() {
    return (this.data?.briefingBody || "")
      .split("\n")
      .map((l) =>
        l
          .replace(/^\s*[-*•]\s*/, "")
          .replace(/\*\*/g, "")
          .trim()
      )
      .filter((l) => l.length)
      .map((text, i) => ({ id: `b${i}`, text }));
  }
  get briefingTime() {
    return this.data?.briefingAt
      ? `${istIso(this.data.briefingAt).substring(11, 16)} IST · ${this.ago(this.data.briefingAt)}`
      : "";
  }

  // ------------------------------------------------------------ squad
  get squad() {
    const now = Date.now();
    return (this.data?.squad || []).map((a) => {
      const meta = AGENT_META[a.name] || { emoji: "🤖", color: "#8b949e" };
      const working =
        a.lastAt && now - new Date(a.lastAt).getTime() < 20 * 60000;
      return {
        ...a,
        emoji: meta.emoji,
        avatarStyle: `--c:${meta.color}`,
        cardClass: working ? "agent agent-working" : "agent",
        statusLabel: working
          ? "Working"
          : a.lastAt
            ? `Idle · ${this.ago(a.lastAt)}`
            : "Standing by",
        statusClass: working ? "agent-status live" : "agent-status",
        last: a.lastMessage || "No actions yet.",
        countLabel: `${a.actions24h || 0} actions · 24h`
      };
    });
  }
  get workingCount() {
    return this.squad.filter((a) => a.cardClass.includes("working")).length;
  }

  // ------------------------------------------------------------ feed
  get feed() {
    return (this.data?.events || []).map((e) => {
      const meta = AGENT_META[e.agent] || { emoji: "🤖", color: "#8b949e" };
      return {
        ...e,
        emoji: meta.emoji,
        dotStyle: `--c:${meta.color}`,
        rowClass: `feed-row sev-${e.severity || "info"}`,
        time: e.at ? istIso(e.at).substring(11, 16) : "",
        day: e.at ? this.dayLabel(e.at) : "",
        hasLink: !!e.link
      };
    });
  }
  get hasFeed() {
    return this.feed.length > 0;
  }

  // ------------------------------------------------------------ open source
  get oss() {
    return (this.data?.contributions || []).map((c) => {
      const idx = OSS_INDEX[c.status] ?? 0;
      const failed = c.status === "Failed" || c.status === "Closed";
      const owner = (c.repo || "").split("/")[0];
      return {
        ...c,
        avatar: `https://avatars.githubusercontent.com/${owner}?size=80`,
        repoUrl: `https://github.com/${c.repo}`,
        starLabel: this.fmt(c.stars || 0),
        statusLabel: OSS_LABEL[c.status] || c.status,
        statusClass: `oss-status oss-${(c.status || "").toLowerCase()}`,
        issueLabel: `#${c.issueNumber}`,
        prLabel: c.prNumber ? `PR #${c.prNumber}` : null,
        testLabel:
          c.testResult && c.testResult !== "Pending"
            ? c.testResult.replace("_", " ")
            : null,
        steps: OSS_STEPS.map((label, i) => ({
          key: `${c.id}-${i}`,
          label,
          cls:
            failed && i === Math.max(idx, 1) - 1
              ? "st st-fail"
              : i < idx
                ? "st st-done"
                : i === idx && !failed && c.status !== "Merged"
                  ? "st st-live"
                  : "st"
        }))
      };
    });
  }
  get hasOss() {
    return this.oss.length > 0;
  }
  get ossStats() {
    const d = this.data || {};
    return [
      { key: "f", label: "In flight", value: d.ossInFlight || 0 },
      { key: "o", label: "PRs open", value: d.ossOpen || 0 },
      { key: "m", label: "Merged", value: d.ossMerged || 0 },
      { key: "r", label: "Repos", value: d.ossRepos || 0 }
    ];
  }

  // ------------------------------------------------------------ chat (admin, Agentforce)
  get chatToggleLabel() {
    return this.chatOpen ? "✕" : "💬 Ask Mission Control";
  }
  get chatSendDisabled() {
    return this.chatBusy || !this.chatInput.trim();
  }
  toggleChat() {
    this.chatOpen = !this.chatOpen;
  }
  handleChatInput(event) {
    this.chatInput = event.target.value;
  }
  handleChatKey(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.sendChat();
    }
  }
  async sendChat() {
    const text = this.chatInput.trim();
    if (!text || this.chatBusy) return;
    const stamp = Date.now();
    this.chatMessages = [
      ...this.chatMessages,
      { id: `u${stamp}`, cls: "msg msg-user", text },
      {
        id: `t${stamp}`,
        cls: "msg msg-agent msg-typing",
        text: "Mission Control is thinking…"
      }
    ];
    this.chatInput = "";
    const box = this.template.querySelector(".chat-input");
    if (box) box.value = "";
    this.chatBusy = true;
    try {
      const reply = await askMissionControl({
        message: text,
        sessionId: this.chatSession
      });
      this.chatSession = reply.sessionId;
      this.chatMessages = [
        ...this.chatMessages.filter((m) => m.id !== `t${stamp}`),
        { id: `a${stamp}`, cls: "msg msg-agent", text: reply.message }
      ];
      this.refresh();
    } catch (e) {
      this.chatMessages = [
        ...this.chatMessages.filter((m) => m.id !== `t${stamp}`),
        {
          id: `e${stamp}`,
          cls: "msg msg-error",
          text: e?.body?.message || "Mission Control is unavailable."
        }
      ];
    } finally {
      this.chatBusy = false;
    }
  }

  dayLabel(value) {
    const d = istIso(value).substring(0, 10);
    const today = istIso(new Date()).substring(0, 10);
    const yday = istIso(new Date(Date.now() - 86400000)).substring(0, 10);
    return d === today ? "Today" : d === yday ? "Yesterday" : d.substring(5);
  }

  // ------------------------------------------------------------ utils
  fmt(n) {
    return Number(n).toLocaleString("en-US");
  }
  ago(value) {
    const diff = Date.now() - new Date(value).getTime();
    const m = Math.round(diff / 60000);
    if (m < 1) return "just now";
    if (m < 60) return `${m}m ago`;
    const h = Math.round(m / 60);
    if (h < 48) return `${h}h ago`;
    return `${Math.round(h / 24)}d ago`;
  }
}
