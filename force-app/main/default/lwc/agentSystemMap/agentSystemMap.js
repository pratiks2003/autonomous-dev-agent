import { LightningElement, api } from "lwc";
import { computeSchedule } from "c/agentSchedule";

const IST_MS = 330 * 60000;
const ACTIVE_WINDOW_MS = 20 * 60000;
const SCENE_MS = 3800;

/* ------------------------------------------------------------------ the map */
const NODES = [
  // triggers
  {
    key: "scheduler",
    x: 115,
    y: 130,
    emoji: "⏰",
    label: "Daily Scheduler",
    sub: "13:30 IST · Apex Schedulable",
    zone: "trigger"
  },
  {
    key: "heartbeat",
    x: 115,
    y: 330,
    emoji: "💓",
    label: "Squad Heartbeat",
    sub: "every 30 min",
    zone: "trigger"
  },
  {
    key: "you",
    x: 115,
    y: 600,
    emoji: "🧑‍💻",
    label: "You",
    sub: "dashboard + chat",
    zone: "trigger"
  },
  // salesforce
  {
    key: "maintainer",
    x: 330,
    y: 130,
    emoji: "🧰",
    label: "Maintainer",
    sub: "daily mission",
    zone: "sf",
    agent: "Maintainer"
  },
  {
    key: "concierge",
    x: 510,
    y: 130,
    emoji: "🧭",
    label: "Concierge",
    sub: "briefings",
    zone: "sf",
    agent: "Concierge"
  },
  {
    key: "scout",
    x: 690,
    y: 130,
    emoji: "🔎",
    label: "Scout",
    sub: "finds issues",
    zone: "sf",
    agent: "Scout"
  },
  {
    key: "engineer",
    x: 330,
    y: 280,
    emoji: "🛠️",
    label: "Engineer",
    sub: "RAG + edits",
    zone: "sf",
    agent: "Engineer"
  },
  {
    key: "brain",
    x: 510,
    y: 280,
    emoji: "🧠",
    label: "Einstein Models API",
    sub: "Claude Sonnet 4 · Trust Layer",
    zone: "sf",
    big: true
  },
  {
    key: "reviewer",
    x: 690,
    y: 280,
    emoji: "🔍",
    label: "Reviewer",
    sub: "quality gate",
    zone: "sf",
    agent: "Reviewer"
  },
  {
    key: "verifier",
    x: 330,
    y: 430,
    emoji: "🧪",
    label: "Verifier",
    sub: "real test suites",
    zone: "sf",
    agent: "Verifier"
  },
  {
    key: "mission",
    x: 510,
    y: 430,
    emoji: "🛰️",
    label: "Mission Control",
    sub: "Agentforce · Agent Script",
    zone: "sf",
    big: true
  },
  {
    key: "publisher",
    x: 690,
    y: 430,
    emoji: "🚀",
    label: "Publisher",
    sub: "opens & tracks PRs",
    zone: "sf",
    agent: "Publisher"
  },
  {
    key: "records",
    x: 400,
    y: 590,
    emoji: "🗄️",
    label: "Salesforce Records",
    sub: "quests · runs · events",
    zone: "sf"
  },
  {
    key: "dashboard",
    x: 620,
    y: 590,
    emoji: "📡",
    label: "This Website",
    sub: "Experience Cloud LWR",
    zone: "sf"
  },
  // github
  {
    key: "forge",
    x: 1000,
    y: 130,
    emoji: "📦",
    label: "agent-forge",
    sub: "daily PR · auto-merge",
    zone: "gh"
  },
  {
    key: "actions",
    x: 1000,
    y: 300,
    emoji: "⚙️",
    label: "GitHub Actions",
    sub: "CI · Verifier · Watchdog",
    zone: "gh",
    agent: "Watchdog"
  },
  {
    key: "oss",
    x: 1000,
    y: 460,
    emoji: "🌍",
    label: "Public OSS repos",
    sub: "forks · upstream PRs",
    zone: "gh"
  },
  {
    key: "profile",
    x: 1000,
    y: 600,
    emoji: "🪪",
    label: "Profile README",
    sub: "live status block",
    zone: "gh"
  }
];

const EDGES = [
  ["scheduler", "maintainer"],
  ["heartbeat", "scout"],
  ["heartbeat", "concierge"],
  ["maintainer", "brain"],
  ["concierge", "brain"],
  ["scout", "brain"],
  ["engineer", "brain"],
  ["reviewer", "brain"],
  ["maintainer", "forge"],
  ["scout", "oss"],
  ["engineer", "oss"],
  ["verifier", "actions"],
  ["publisher", "oss"],
  ["publisher", "forge"],
  ["reviewer", "forge"],
  ["actions", "forge"],
  ["maintainer", "profile"],
  ["publisher", "records"],
  ["verifier", "records"],
  ["records", "dashboard"],
  ["dashboard", "you"],
  ["you", "mission"],
  ["mission", "concierge"]
].map(([from, to]) => ({ id: `${from}-${to}`, from, to }));

const SCENES = [
  {
    t: "13:30 IST · the day begins",
    c: "A scheduled Apex job wakes the Maintainer for the daily mission.",
    n: ["scheduler", "maintainer"],
    e: ["scheduler-maintainer"]
  },
  {
    t: "Read the repo",
    c: "One GitHub GraphQL call pulls open quests, the file tree, README and style guide from agent-forge.",
    n: ["maintainer", "forge"],
    e: ["maintainer-forge"]
  },
  {
    t: "Plan with Einstein",
    c: "Backlog thin? The Einstein Models API (Claude Sonnet 4) invents a useful quest and opens a GitHub issue.",
    n: ["maintainer", "brain", "forge"],
    e: ["maintainer-brain", "maintainer-forge"]
  },
  {
    t: "Write the code",
    c: "The Engineer retrieves similar code (RAG) and Einstein writes the implementation plus unit tests.",
    n: ["engineer", "brain"],
    e: ["engineer-brain"]
  },
  {
    t: "Open the PR, review it",
    c: "Branch, commits and a pull request — then the Reviewer posts a code review: complexity, edge cases, security.",
    n: ["publisher", "reviewer", "forge"],
    e: ["publisher-forge", "reviewer-forge"]
  },
  {
    t: "CI is the gate",
    c: "GitHub Actions typechecks and runs the tests. Only green CI auto-merges — and the contribution square turns green.",
    n: ["actions", "forge"],
    e: ["actions-forge"]
  },
  {
    t: "Every 30 minutes",
    c: "The heartbeat sends the Scout across public GitHub for good-first issues in active, well-starred repos.",
    n: ["heartbeat", "scout", "oss", "brain"],
    e: ["heartbeat-scout", "scout-oss", "scout-brain"]
  },
  {
    t: "Fork and fix",
    c: "The Engineer forks the project, lets Einstein pick the files it needs, and commits precise search/replace edits.",
    n: ["engineer", "oss", "brain"],
    e: ["engineer-oss", "engineer-brain"]
  },
  {
    t: "Prove it works",
    c: "The Verifier runs the project's own test suite in GitHub Actions — with no secrets exposed to third-party code.",
    n: ["verifier", "actions"],
    e: ["verifier-actions"]
  },
  {
    t: "Ship upstream",
    c: "The Reviewer must approve; then the Publisher opens the pull request upstream and tracks it until it merges.",
    n: ["reviewer", "publisher", "oss"],
    e: ["reviewer-brain", "publisher-oss"]
  },
  {
    t: "Everything is recorded",
    c: "Every step lands in Salesforce records; the Concierge writes a daily briefing and the profile README updates.",
    n: [
      "publisher",
      "verifier",
      "records",
      "concierge",
      "profile",
      "maintainer"
    ],
    e: [
      "publisher-records",
      "verifier-records",
      "concierge-brain",
      "maintainer-profile"
    ]
  },
  {
    t: "You, in the loop",
    c: "This site reads the records live, and Mission Control — an Agentforce agent — answers your questions in chat.",
    n: ["records", "dashboard", "you", "mission", "concierge"],
    e: [
      "records-dashboard",
      "dashboard-you",
      "you-mission",
      "mission-concierge"
    ]
  }
];

const W = 1200;
const H = 700;
const NODE_W = 156;
const NODE_H = 58;

function nodeByKey(key) {
  return NODES.find((n) => n.key === key);
}

/** Cubic bezier between two node centers, bending along the dominant axis. */
function curve(a, b) {
  const dx = b.x - a.x;
  const dy = b.y - a.y;
  if (Math.abs(dx) >= Math.abs(dy)) {
    return [a.x, a.y, a.x + dx * 0.5, a.y, b.x - dx * 0.5, b.y, b.x, b.y];
  }
  return [a.x, a.y, a.x, a.y + dy * 0.5, b.x, b.y - dy * 0.5, b.x, b.y];
}

function pointAt(c, t) {
  const u = 1 - t;
  const x =
    u * u * u * c[0] +
    3 * u * u * t * c[2] +
    3 * u * t * t * c[4] +
    t * t * t * c[6];
  const y =
    u * u * u * c[1] +
    3 * u * u * t * c[3] +
    3 * u * t * t * c[5] +
    t * t * t * c[7];
  return [x, y];
}

function istIso(value) {
  return new Date(new Date(value).getTime() + IST_MS).toISOString();
}

export default class AgentSystemMap extends LightningElement {
  @api data;

  mode = "live";
  scene = 0;
  playing = true;
  now = Date.now();
  _sceneTimer;
  _clock;
  _raf;
  _packetEls = [];
  _frame = (ts) => this.loop(ts);

  connectedCallback() {
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._clock = setInterval(() => {
      this.now = Date.now();
    }, 1000);
    this.startScenes();
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._raf = requestAnimationFrame(this._frame);
  }

  disconnectedCallback() {
    clearInterval(this._clock);
    clearInterval(this._sceneTimer);
    cancelAnimationFrame(this._raf);
  }

  renderedCallback() {
    this._packetEls = Array.from(
      this.template.querySelectorAll("circle[data-edge]")
    );
  }

  /* ------------------------------------------------------------ animation loop */
  loop(ts) {
    for (const el of this._packetEls) {
      const c = this._curves?.[el.dataset.edge];
      if (c) {
        const dur = 2200;
        const t = ((ts + Number(el.dataset.offset) * dur) % dur) / dur;
        const [x, y] = pointAt(c, t);
        el.setAttribute("cx", x.toFixed(1));
        el.setAttribute("cy", y.toFixed(1));
      }
    }
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._raf = requestAnimationFrame(this._frame);
  }

  startScenes() {
    clearInterval(this._sceneTimer);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this._sceneTimer = setInterval(() => {
      if (this.mode === "tour" && this.playing) {
        this.scene = (this.scene + 1) % SCENES.length;
      }
    }, SCENE_MS);
  }

  /* ------------------------------------------------------------ live state */
  get activeAgents() {
    const set = new Set();
    for (const a of this.data?.squad || []) {
      if (
        a.lastAt &&
        this.now - new Date(a.lastAt).getTime() < ACTIVE_WINDOW_MS
      )
        set.add(a.name);
    }
    return set;
  }

  get liveFocus() {
    const nodes = new Set();
    const edges = new Set();
    const active = this.activeAgents;
    for (const n of NODES) {
      if (n.agent && active.has(n.agent)) nodes.add(n.key);
    }
    if (this.data?.lastRun?.status === "Running")
      nodes.add("maintainer").add("scheduler");
    for (const e of EDGES) {
      if (nodes.has(e.from) || nodes.has(e.to)) {
        if (nodes.has(e.from) && nodes.has(e.to)) edges.add(e.id);
        else if (
          nodes.has(e.from) &&
          ["brain", "forge", "oss", "actions", "records"].includes(e.to)
        )
          edges.add(e.id);
      }
    }
    // light up whatever the active agents are talking to
    for (const id of edges) {
      const e = EDGES.find((x) => x.id === id);
      nodes.add(e.to);
    }
    if (nodes.size === 0) {
      // calm state: the always-on loop (records -> website -> you)
      ["records-dashboard", "dashboard-you"].forEach((id) => edges.add(id));
    }
    return { nodes, edges };
  }

  get focus() {
    if (this.mode === "tour") {
      const s = SCENES[this.scene];
      return { nodes: new Set(s.n), edges: new Set(s.e) };
    }
    return this.liveFocus;
  }

  /* ------------------------------------------------------------ svg model */
  get viewBox() {
    return `0 0 ${W} ${H}`;
  }

  get zones() {
    return [
      {
        key: "z1",
        x: 20,
        y: 40,
        w: 190,
        h: 640,
        label: "TRIGGERS",
        cls: "zone zone-trigger",
        lx: 34,
        ly: 64
      },
      {
        key: "z2",
        x: 232,
        y: 40,
        w: 556,
        h: 640,
        label: "SALESFORCE · AGENTFORCE ORG",
        cls: "zone zone-sf",
        lx: 246,
        ly: 64
      },
      {
        key: "z3",
        x: 836,
        y: 40,
        w: 344,
        h: 640,
        label: "GITHUB",
        cls: "zone zone-gh",
        lx: 850,
        ly: 64
      }
    ];
  }

  get edges() {
    const focus = this.focus;
    const any = focus.nodes.size > 0 || focus.edges.size > 0;
    this._curves = {};
    return EDGES.map((e) => {
      const c = curve(nodeByKey(e.from), nodeByKey(e.to));
      this._curves[e.id] = c;
      const on = focus.edges.has(e.id);
      return {
        id: e.id,
        d: `M${c[0]},${c[1]} C${c[2]},${c[3]} ${c[4]},${c[5]} ${c[6]},${c[7]}`,
        cls: on ? "edge edge-on" : any ? "edge edge-dim" : "edge"
      };
    });
  }

  get packets() {
    const out = [];
    for (const id of this.focus.edges) {
      for (let i = 0; i < 3; i++)
        out.push({ key: `${id}-${i}`, edge: id, offset: String(i / 3) });
    }
    return out;
  }

  get schedule() {
    return computeSchedule(this.data, this.now);
  }

  get nodes() {
    const sched = this.schedule;
    const focus = this.focus;
    const any = focus.nodes.size > 0;
    const active = this.activeAgents;
    return NODES.map((n) => {
      const w = n.big ? NODE_W + 34 : NODE_W;
      const h = n.big ? NODE_H + 10 : NODE_H;
      const on = focus.nodes.has(n.key);
      const live = this.mode === "live" && n.agent && active.has(n.agent);
      return {
        ...n,
        transform: `translate(${n.x},${n.y})`,
        rx: -w / 2,
        ry: -h / 2,
        w,
        h,
        haloR: Math.max(w, h) / 2 + 14,
        cls: `node node-${n.zone}${on ? " node-on" : any ? " node-dim" : ""}${live ? " node-live" : ""}${n.big ? " node-big" : ""}`,
        emojiX: -w / 2 + 22,
        textX: -w / 2 + 42,
        showHalo: on,
        ...this.pill(n, sched, w, h)
      };
    });
  }

  pill(n, sched, w, h) {
    const sc = n.agent ? sched[n.agent] : null;
    if (!sc) return { hasPill: false };
    const live = sc.state === "working";
    const label = live
      ? "● running"
      : sc.nextAt
        ? `⏱ ${sc.countdown}`
        : "waiting";
    const pw = Math.max(64, label.length * 7 + 16);
    return {
      hasPill: true,
      pillLabel: label,
      pillX: -pw / 2,
      pillY: h / 2 + 6,
      pillW: pw,
      pillTextY: h / 2 + 19,
      pillCls: live ? "pill pill-live" : sc.nextAt ? "pill" : "pill pill-idle",
      clickable: true
    };
  }

  handleNodeClick(event) {
    const name = event.currentTarget.dataset.agent;
    if (name) {
      this.dispatchEvent(new CustomEvent("agentselect", { detail: { name } }));
    }
  }

  /* ------------------------------------------------------------ captions & cards */
  get isLive() {
    return this.mode === "live";
  }
  get liveBtnClass() {
    return this.mode === "live" ? "seg seg-on" : "seg";
  }
  get tourBtnClass() {
    return this.mode === "tour" ? "seg seg-on" : "seg";
  }
  get playLabel() {
    return this.playing ? "❚❚ Pause" : "▶ Play";
  }
  get sceneTitle() {
    return SCENES[this.scene].t;
  }
  get sceneCaption() {
    return SCENES[this.scene].c;
  }
  get sceneCounter() {
    return `${this.scene + 1} / ${SCENES.length}`;
  }
  get sceneDots() {
    return SCENES.map((s, i) => ({
      key: `d${i}`,
      idx: String(i),
      cls: i === this.scene ? "dot dot-on" : "dot",
      label: s.t
    }));
  }

  get latest() {
    const e = (this.data?.events || [])[0];
    if (!e) return null;
    return {
      agent: e.agent,
      message: e.message,
      link: e.link,
      when: `${istIso(e.at).substring(11, 16)} IST · ${this.ago(e.at)}`
    };
  }
  get activeCount() {
    return this.activeAgents.size;
  }
  get activeLabel() {
    const names = Array.from(this.activeAgents);
    return names.length
      ? names.join(" · ")
      : "All agents idle — waiting for the next trigger";
  }

  get missionCard() {
    const run = this.data?.lastRun;
    const status = !run
      ? "No run yet"
      : run.status === "Running"
        ? `Running · ${run.stage}`
        : `${run.status.replace(/_/g, " ")} · ${run.stage || ""}`;
    return {
      status,
      next: this.countdownTo(8, 0),
      quest: run?.questTitle || "—"
    };
  }

  get ossCard() {
    const list = this.data?.contributions || [];
    const inflight = list.find((c) =>
      [
        "Selected",
        "Forked",
        "Fix_Ready",
        "Verifying",
        "Verified",
        "Review_Passed"
      ].includes(c.status)
    );
    const c = inflight || list[0];
    if (!c)
      return {
        repo: "Scout is searching",
        status: "No contribution in flight",
        url: null
      };
    return {
      repo: `${c.repo}#${c.issueNumber}`,
      status: c.status.replace(/_/g, " "),
      url: c.issueUrl
    };
  }

  get heartbeatIn() {
    const d = new Date(this.now);
    const m = d.getUTCMinutes();
    const s = d.getUTCSeconds();
    const target = m < 15 ? 15 : m < 45 ? 45 : 75;
    const secs = (target - m) * 60 - s;
    return `${String(Math.floor(secs / 60)).padStart(2, "0")}:${String(secs % 60).padStart(2, "0")}`;
  }

  countdownTo(utcHour, utcMin) {
    const now = new Date(this.now);
    const next = new Date(
      Date.UTC(
        now.getUTCFullYear(),
        now.getUTCMonth(),
        now.getUTCDate(),
        utcHour,
        utcMin,
        0
      )
    );
    if (next <= now) next.setUTCDate(next.getUTCDate() + 1);
    const s = Math.floor((next - now) / 1000);
    const pad = (n) => String(n).padStart(2, "0");
    return `${pad(Math.floor(s / 3600))}:${pad(Math.floor((s % 3600) / 60))}:${pad(s % 60)}`;
  }

  /* ------------------------------------------------------------ 24h IST day ring */
  get ring() {
    const cx = 150;
    const cy = 150;
    const r = 112;
    const polar = (minutes, radius) => {
      const a = (minutes / 1440) * 2 * Math.PI - Math.PI / 2;
      return [cx + radius * Math.cos(a), cy + radius * Math.sin(a)];
    };
    const ticks = [];
    for (let m = 0; m < 1440; m += 30) {
      // heartbeat at :15 and :45 IST
      const [x1, y1] = polar(m + 15, r - 6);
      const [x2, y2] = polar(m + 15, r + 2);
      ticks.push({ key: `t${m}`, x1, y1, x2, y2 });
    }
    const marks = [
      {
        key: "m1",
        min: 13 * 60 + 30,
        label: "Mission",
        cls: "mark mark-mission"
      },
      { key: "m2", min: 90, label: "Watchdog", cls: "mark mark-watchdog" },
      { key: "m3", min: 14 * 60, label: "Briefing", cls: "mark mark-brief" },
      { key: "m4", min: 21 * 60, label: "Evening", cls: "mark mark-brief" }
    ].map((m) => {
      const [x, y] = polar(m.min, r);
      const [lx, ly] = polar(m.min, m.cls.includes("brief") ? r - 26 : r + 24);
      return { ...m, x, y, lx, ly };
    });
    const nowIst = new Date(this.now + IST_MS);
    const minutes =
      nowIst.getUTCHours() * 60 +
      nowIst.getUTCMinutes() +
      nowIst.getUTCSeconds() / 60;
    const [nx, ny] = polar(minutes, r - 18);
    const hours = [0, 6, 12, 18].map((h) => {
      const [x, y] = polar(h * 60, r - 30);
      return { key: `h${h}`, x, y, label: String(h).padStart(2, "0") };
    });
    return {
      cx,
      cy,
      r,
      ticks,
      marks,
      nx,
      ny,
      hours,
      time: nowIst.toISOString().substring(11, 16)
    };
  }

  /* ------------------------------------------------------------ handlers */
  setLive() {
    this.mode = "live";
  }
  setTour() {
    this.mode = "tour";
    this.playing = true;
  }
  togglePlay() {
    this.playing = !this.playing;
  }
  nextScene() {
    this.mode = "tour";
    this.scene = (this.scene + 1) % SCENES.length;
  }
  prevScene() {
    this.mode = "tour";
    this.scene = (this.scene - 1 + SCENES.length) % SCENES.length;
  }
  jumpScene(event) {
    this.mode = "tour";
    this.scene = Number(event.currentTarget.dataset.idx);
  }

  ago(value) {
    const m = Math.round((this.now - new Date(value).getTime()) / 60000);
    if (m < 1) return "just now";
    if (m < 60) return `${m}m ago`;
    const h = Math.round(m / 60);
    return h < 48 ? `${h}h ago` : `${Math.round(h / 24)}d ago`;
  }
}
