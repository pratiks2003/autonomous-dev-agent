import { LightningElement, api, wire } from "lwc";
import { refreshApex } from "@salesforce/apex";
import isGuest from "@salesforce/user/isGuest";
import getDashboard from "@salesforce/apex/AgentCommandCenterController.getDashboard";
import triggerManualRun from "@salesforce/apex/AgentCommandCenterController.triggerManualRun";
import enqueueCustomQuest from "@salesforce/apex/AgentCommandCenterController.enqueueCustomQuest";

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
