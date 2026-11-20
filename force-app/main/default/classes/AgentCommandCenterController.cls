/**
 * Serves the Experience Cloud "Agent Command Center".
 *  - getDashboard(): cacheable, guest-safe (WITH SECURITY_ENFORCED, read-only fields, no error internals for guests).
 *  - triggerManualRun() / enqueueCustomQuest(): require the Agent_Command_Admin custom permission.
 */
public with sharing class AgentCommandCenterController {
  public class QuestCard {
    @AuraEnabled
    public String id;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String title;
    @AuraEnabled
    public String questType;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public Integer issueNumber;
    @AuraEnabled
    public Integer prNumber;
    @AuraEnabled
    public String prUrl;
    @AuraEnabled
    public String issueUrl;
    @AuraEnabled
    public String branch;
    @AuraEnabled
    public String commitSha;
    @AuraEnabled
    public Integer priority;
    @AuraEnabled
    public Boolean selfGenerated;
    @AuraEnabled
    public Datetime shippedAt;
    @AuraEnabled
    public String reasoning;
    @AuraEnabled
    public String review;
    @AuraEnabled
    public String summary;
  }

  public class RunRow {
    @AuraEnabled
    public String id;
    @AuraEnabled
    public Datetime runDate;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String stage;
    @AuraEnabled
    public String releaseTag;
    @AuraEnabled
    public Integer streak;
    @AuraEnabled
    public String questTitle;
    @AuraEnabled
    public String error;
    @AuraEnabled
    public Boolean manual;
  }

  public class EventRow {
    @AuraEnabled
    public String id;
    @AuraEnabled
    public String agent;
    @AuraEnabled
    public String eventType;
    @AuraEnabled
    public String message;
    @AuraEnabled
    public String link;
    @AuraEnabled
    public String severity;
    @AuraEnabled
    public Datetime at;
  }

  public class AgentCard {
    @AuraEnabled
    public String key;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String role;
    @AuraEnabled
    public String lastMessage;
    @AuraEnabled
    public Datetime lastAt;
    @AuraEnabled
    public Integer actions24h = 0;
    @AuraEnabled
    public List<EventRow> recent = new List<EventRow>();
  }

  public class OssCard {
    @AuraEnabled
    public String id;
    @AuraEnabled
    public String repo;
    @AuraEnabled
    public Integer issueNumber;
    @AuraEnabled
    public String issueUrl;
    @AuraEnabled
    public String title;
    @AuraEnabled
    public String language;
    @AuraEnabled
    public Integer stars;
    @AuraEnabled
    public String status;
    @AuraEnabled
    public String prUrl;
    @AuraEnabled
    public Integer prNumber;
    @AuraEnabled
    public String testResult;
    @AuraEnabled
    public String summary;
    @AuraEnabled
    public Integer score;
    @AuraEnabled
    public Datetime updatedAt;
    @AuraEnabled
    public String reviewVerdict;
    @AuraEnabled
    public String reviewNotes;
    @AuraEnabled
    public String verifyRunUrl;
    @AuraEnabled
    public String fork;
    @AuraEnabled
    public String branch;
    @AuraEnabled
    public Integer attempts;
    @AuraEnabled
    public String skipReason;
  }

  public class ChatReply {
    @AuraEnabled
    public String message;
    @AuraEnabled
    public String sessionId;
  }

  public class Dashboard {
    @AuraEnabled
    public String owner;
    @AuraEnabled
    public String repo;
    @AuraEnabled
    public String repoUrl;
    @AuraEnabled
    public String model;
    @AuraEnabled
    public Integer streak = 0;
    @AuraEnabled
    public Integer commits = 0;
    @AuraEnabled
    public Integer prs = 0;
    @AuraEnabled
    public Integer issues = 0;
    @AuraEnabled
    public Integer reviews = 0;
    @AuraEnabled
    public Integer totalContributions = 0;
    @AuraEnabled
    public List<List<Object>> days = new List<List<Object>>();
    @AuraEnabled
    public String latestRelease;
    @AuraEnabled
    public Datetime latestReleaseDate;
    @AuraEnabled
    public Integer shippedTotal = 0;
    public Integer lifetimeShipped;
    @AuraEnabled
    public Integer successRate = 0;
    @AuraEnabled
    public RunRow lastRun;
    @AuraEnabled
    public List<RunRow> runs = new List<RunRow>();
    @AuraEnabled
    public List<QuestCard> shipped = new List<QuestCard>();
    @AuraEnabled
    public List<QuestCard> active = new List<QuestCard>();
    @AuraEnabled
    public List<QuestCard> planned = new List<QuestCard>();
    @AuraEnabled
    public Boolean isAdmin = false;
    @AuraEnabled
    public String briefingHeadline;
    @AuraEnabled
    public String briefingBody;
    @AuraEnabled
    public Datetime briefingAt;
    @AuraEnabled
    public List<EventRow> events = new List<EventRow>();
    @AuraEnabled
    public List<AgentCard> squad = new List<AgentCard>();
    @AuraEnabled
    public List<OssCard> contributions = new List<OssCard>();
    @AuraEnabled
    public Integer ossInFlight = 0;
    @AuraEnabled
    public Integer ossOpen = 0;
    @AuraEnabled
    public Integer ossMerged = 0;
    @AuraEnabled
    public Integer ossRepos = 0;
    @AuraEnabled
    public Datetime lastPrOpenedAt;
    @AuraEnabled
    public Datetime generatedAt;
  }

  @AuraEnabled(cacheable=true)
  public static Dashboard getDashboard() {
    AgentConfig cfg = AgentConfig.get();
    Boolean admin = isAdmin();
    Dashboard d = new Dashboard();
    d.owner = cfg.owner;
    d.repo = cfg.repo;
    d.repoUrl = 'https://github.com/' + cfg.fullRepo();
    d.model = cfg.model;
    d.isAdmin = admin;
    d.generatedAt = Datetime.now();

    // ---- runs + telemetry
    List<Agent_Run_Log__c> logs = [
      SELECT
        Id,
        Run_Date__c,
        Agent_Status__c,
        Stage__c,
        Release_Tag__c,
        Streak_Days__c,
        Manual_Run__c,
        Agent_Quest__r.Title__c
      FROM Agent_Run_Log__c
      WITH SECURITY_ENFORCED
      ORDER BY Run_Date__c DESC
      LIMIT 30
    ];
    Map<Id, String> errors = new Map<Id, String>();
    if (admin) {
      for (Agent_Run_Log__c l : [
        SELECT Id, Error_Detail__c
        FROM Agent_Run_Log__c
        WHERE Id IN :logs
        WITH SECURITY_ENFORCED
      ]) {
        if (String.isNotBlank(l.Error_Detail__c)) {
          errors.put(l.Id, AgentHttp.abbreviate(l.Error_Detail__c, 400));
        }
      }
    }
    Integer ok = 0;
    for (Agent_Run_Log__c l : logs) {
      RunRow row = new RunRow();
      row.id = l.Id;
      row.runDate = l.Run_Date__c;
      row.status = l.Agent_Status__c;
      row.stage = l.Stage__c;
      row.releaseTag = l.Release_Tag__c;
      row.streak = l.Streak_Days__c == null
        ? null
        : l.Streak_Days__c.intValue();
      row.questTitle = l.Agent_Quest__r?.Title__c;
      row.manual = l.Manual_Run__c;
      row.error = errors.get(l.Id);
      d.runs.add(row);
      if (
        l.Agent_Status__c == 'Success' ||
        l.Agent_Status__c == 'Self_Generated_Quest'
      ) {
        ok++;
      }
      if (d.latestRelease == null && l.Release_Tag__c != null) {
        d.latestRelease = l.Release_Tag__c;
        d.latestReleaseDate = l.Run_Date__c;
      }
    }
    if (!d.runs.isEmpty()) {
      d.lastRun = d.runs[0];
      d.successRate = Math.round(100.0 * ok / d.runs.size());
    }

    for (Agent_Run_Log__c l : [
      SELECT Contribution_Snapshot__c, Streak_Days__c
      FROM Agent_Run_Log__c
      WHERE Agent_Status__c IN ('Success', 'Self_Generated_Quest')
      WITH SECURITY_ENFORCED
      ORDER BY Run_Date__c DESC
      LIMIT 10
    ]) {
      if (String.isNotBlank(l.Contribution_Snapshot__c)) {
        applySnapshot(d, l.Contribution_Snapshot__c);
        d.streak = l.Streak_Days__c == null
          ? GitHubLifecycleService.streakFromSnapshot(
              l.Contribution_Snapshot__c
            )
          : l.Streak_Days__c.intValue();
        break;
      }
    }

    // ---- kanban
    d.shippedTotal = [
      SELECT COUNT()
      FROM Agent_Quest__c
      WHERE Status__c = 'Shipped'
      WITH SECURITY_ENFORCED
    ];
    for (Agent_Quest__c q : [
      SELECT
        Id,
        Name,
        Title__c,
        Quest_Type__c,
        Status__c,
        GitHub_Issue_Number__c,
        PR_Number__c,
        PR_Url__c,
        Branch_Name__c,
        Commit_SHA__c,
        Priority__c,
        Self_Generated__c,
        Shipped_At__c,
        Repository_Name__c,
        LastModifiedDate,
        (
          SELECT
            AI_Reasoning_Notes__c,
            Review_Comment_Summary__c,
            Daily_Summary__c
          FROM Run_Logs__r
          ORDER BY Run_Date__c DESC
          LIMIT 1
        )
      FROM Agent_Quest__c
      WITH SECURITY_ENFORCED
      ORDER BY LastModifiedDate DESC
      LIMIT 200
    ]) {
      QuestCard c = toCard(q);
      if (q.Status__c == 'Shipped' && d.shipped.size() < 6) {
        d.shipped.add(c);
      } else if (
        (q.Status__c == 'In Progress' || q.Status__c == 'Reviewed') &&
        d.active.size() < 6
      ) {
        d.active.add(c);
      } else if (q.Status__c == 'Queued' && d.planned.size() < 50) {
        d.planned.add(c);
      }
    }
    if (d.lifetimeShipped != null && d.lifetimeShipped > d.shippedTotal) {
      d.shippedTotal = d.lifetimeShipped;
    }
    sortPlanned(d.planned);
    while (d.planned.size() > 6) {
      d.planned.remove(d.planned.size() - 1);
    }
    loadSquad(d);
    loadOpenSource(d);
    return d;
  }

  @AuraEnabled
  public static Id triggerManualRun() {
    requireAdmin();
    return DailyAgentOrchestrator.start(true);
  }

  @AuraEnabled
  public static Id enqueueCustomQuest(
    String title,
    String description,
    String questType,
    Integer priority
  ) {
    requireAdmin();
    if (String.isBlank(title)) {
      throw new AuraHandledException('Title is required.');
    }
    String qt = AutonomousQuestGenerator.QUEST_TYPES.contains(questType)
      ? questType
      : 'Feature';
    Agent_Quest__c q = new Agent_Quest__c(
      Title__c = title.abbreviate(240),
      Description__c = description,
      Quest_Type__c = qt,
      Status__c = 'Queued',
      Priority__c = priority == null ? 1 : priority,
      Repository_Name__c = AgentConfig.get().fullRepo(),
      Self_Generated__c = false
    );
    insert q;
    if (!Test.isRunningTest()) {
      System.enqueueJob(new AutonomousQuestGenerator.PublishJob(q.Id));
    }
    return q.Id;
  }

  // ------------------------------------------------------------------ helpers

  public static final List<List<String>> SQUAD = new List<List<String>>{
    new List<String>{ 'Concierge', 'Squad lead · briefings & Agentforce chat' },
    new List<String>{ 'Scout', 'Finds good-first issues across public GitHub' },
    new List<String>{ 'Engineer', 'Forks, retrieves context, writes the fix' },
    new List<String>{ 'Verifier', 'Runs the project\'s real test suite' },
    new List<String>{ 'Reviewer', 'Independent code review gate' },
    new List<String>{ 'Publisher', 'Opens & tracks pull requests' },
    new List<String>{ 'Maintainer', 'Daily mission on agent-forge' },
    new List<String>{ 'Watchdog', 'GitHub Actions failover at 01:30 IST' }
  };

  private static void loadSquad(Dashboard d) {
    Map<String, AgentCard> byName = new Map<String, AgentCard>();
    for (List<String> a : SQUAD) {
      AgentCard c = new AgentCard();
      c.key = a[0].toLowerCase();
      c.name = a[0];
      c.role = a[1];
      byName.put(a[0], c);
      d.squad.add(c);
    }
    Datetime dayAgo = Datetime.now().addHours(-24);
    for (Agent_Event__c e : [
      SELECT
        Id,
        Agent__c,
        Event_Type__c,
        Message__c,
        Link__c,
        Severity__c,
        Occurred_At__c,
        Public_Detail__c
      FROM Agent_Event__c
      WITH SECURITY_ENFORCED
      ORDER BY Occurred_At__c DESC
      LIMIT 200
    ]) {
      if (e.Event_Type__c == DailyBriefingService.EVENT_TYPE) {
        if (d.briefingHeadline == null) {
          d.briefingHeadline = e.Message__c;
          d.briefingBody = e.Public_Detail__c;
          d.briefingAt = e.Occurred_At__c;
        }
        continue;
      }
      if (d.events.size() < 30) {
        EventRow r = new EventRow();
        r.id = e.Id;
        r.agent = e.Agent__c;
        r.eventType = e.Event_Type__c;
        r.message = e.Message__c;
        r.link = e.Link__c;
        r.severity = e.Severity__c;
        r.at = e.Occurred_At__c;
        d.events.add(r);
      }
      AgentCard c = byName.get(e.Agent__c);
      if (c != null && c.recent.size() < 6) {
        EventRow rr = new EventRow();
        rr.id = e.Id;
        rr.agent = e.Agent__c;
        rr.eventType = e.Event_Type__c;
        rr.message = e.Message__c;
        rr.link = e.Link__c;
        rr.severity = e.Severity__c;
        rr.at = e.Occurred_At__c;
        c.recent.add(rr);
      }
      if (c != null) {
        if (c.lastAt == null) {
          c.lastAt = e.Occurred_At__c;
          c.lastMessage = e.Message__c;
        }
        if (e.Occurred_At__c >= dayAgo) {
          c.actions24h++;
        }
      }
    }
  }

  private static void loadOpenSource(Dashboard d) {
    Set<String> repos = new Set<String>();
    for (OSS_Contribution__c c : [
      SELECT
        Id,
        Repo__c,
        Issue_Number__c,
        Issue_Url__c,
        Issue_Title__c,
        Language__c,
        Stars__c,
        Status__c,
        PR_Url__c,
        PR_Number__c,
        Test_Result__c,
        Fix_Summary__c,
        Feasibility_Score__c,
        LastModifiedDate,
        Review_Verdict__c,
        Review_Notes__c,
        Verify_Run_Url__c,
        Fork__c,
        Branch__c,
        Attempts__c,
        Skip_Reason__c,
        Opened_At__c
      FROM OSS_Contribution__c
      WITH SECURITY_ENFORCED
      ORDER BY LastModifiedDate DESC
      LIMIT 60
    ]) {
      if (OssContributionEngine.IN_FLIGHT.contains(c.Status__c)) {
        d.ossInFlight++;
      } else if (c.Status__c == 'PR_Open') {
        d.ossOpen++;
      } else if (c.Status__c == 'Merged') {
        d.ossMerged++;
      }
      if (c.Status__c == 'PR_Open' || c.Status__c == 'Merged') {
        repos.add(c.Repo__c);
      }
      if (
        c.Opened_At__c != null &&
        (d.lastPrOpenedAt == null ||
        c.Opened_At__c > d.lastPrOpenedAt)
      ) {
        d.lastPrOpenedAt = c.Opened_At__c;
      }
      if (d.contributions.size() >= 9 || c.Status__c == 'Skipped') {
        continue;
      }
      OssCard o = new OssCard();
      o.id = c.Id;
      o.repo = c.Repo__c;
      o.issueNumber = c.Issue_Number__c == null
        ? null
        : c.Issue_Number__c.intValue();
      o.issueUrl = c.Issue_Url__c;
      o.title = c.Issue_Title__c;
      o.language = c.Language__c;
      o.stars = c.Stars__c == null ? 0 : c.Stars__c.intValue();
      o.status = c.Status__c;
      o.prUrl = c.PR_Url__c;
      o.prNumber = c.PR_Number__c == null ? null : c.PR_Number__c.intValue();
      o.testResult = c.Test_Result__c;
      o.summary = c.Fix_Summary__c;
      o.score = c.Feasibility_Score__c == null
        ? null
        : c.Feasibility_Score__c.intValue();
      o.updatedAt = c.LastModifiedDate;
      o.reviewVerdict = c.Review_Verdict__c;
      o.reviewNotes = c.Review_Notes__c == null
        ? null
        : c.Review_Notes__c.abbreviate(2500);
      o.verifyRunUrl = c.Verify_Run_Url__c;
      o.fork = c.Fork__c;
      o.branch = c.Branch__c;
      o.attempts = c.Attempts__c == null ? 0 : c.Attempts__c.intValue();
      o.skipReason = c.Skip_Reason__c;
      d.contributions.add(o);
    }
    d.ossRepos = repos.size();
  }

  /** Admin-only: talk to the Mission Control Agentforce agent from the dashboard. */
  @AuraEnabled
  public static ChatReply askMissionControl(String message, String sessionId) {
    requireAdmin();
    if (String.isBlank(message)) {
      throw new AuraHandledException('Say something to Mission Control.');
    }
    ChatReply reply = new ChatReply();
    if (Test.isRunningTest()) {
      reply.message = 'Mission Control online.';
      reply.sessionId = 'test-session';
      return reply;
    }
    Invocable.Action action = Invocable.Action.createCustomAction(
      'generateAiAgentResponse',
      'Mission_Control'
    );
    action.setInvocationParameter('userMessage', message.abbreviate(2000));
    if (String.isNotBlank(sessionId)) {
      action.setInvocationParameter('sessionId', sessionId);
    }
    Invocable.Action.Result result = action.invoke()[0];
    if (!result.isSuccess()) {
      throw new AuraHandledException(
        'Mission Control is unavailable: ' +
        JSON.serialize(result.getErrors()).abbreviate(300)
      );
    }
    Map<String, Object> outputs = result.getOutputParameters();
    String raw = String.valueOf(outputs.get('agentResponse'));
    try {
      Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(
        raw
      );
      reply.message = String.valueOf(parsed.get('value'));
    } catch (Exception e) {
      reply.message = raw;
    }
    reply.sessionId = String.valueOf(outputs.get('sessionId'));
    return reply;
  }

  public static Boolean isAdmin() {
    return FeatureManagement.checkPermission('Agent_Command_Admin');
  }

  private static void requireAdmin() {
    if (!isAdmin()) {
      throw new AuraHandledException('Only Agent Command admins can do that.');
    }
  }

  @TestVisible
  private static void applySnapshot(Dashboard d, String snapshotJson) {
    Map<String, Object> snap = (Map<String, Object>) JSON.deserializeUntyped(
      snapshotJson
    );
    Map<String, Object> totals = (Map<String, Object>) snap.get('totals');
    d.commits = toInt(totals.get('commits'));
    d.prs = toInt(totals.get('prs'));
    d.issues = toInt(totals.get('issues'));
    d.reviews = toInt(totals.get('reviews'));
    d.totalContributions = toInt(totals.get('total'));
    if (totals.get('shipped') != null) {
      d.lifetimeShipped = toInt(totals.get('shipped'));
    }
    for (Object day : (List<Object>) snap.get('days')) {
      d.days.add((List<Object>) day);
    }
  }

  private static QuestCard toCard(Agent_Quest__c q) {
    QuestCard c = new QuestCard();
    c.id = q.Id;
    c.name = q.Name;
    c.title = q.Title__c;
    c.questType = q.Quest_Type__c;
    c.status = q.Status__c;
    c.issueNumber = q.GitHub_Issue_Number__c == null
      ? null
      : q.GitHub_Issue_Number__c.intValue();
    c.prNumber = q.PR_Number__c == null ? null : q.PR_Number__c.intValue();
    c.prUrl = q.PR_Url__c;
    c.issueUrl = c.issueNumber == null ||
      q.Repository_Name__c == null
      ? null
      : 'https://github.com/' +
        q.Repository_Name__c +
        '/issues/' +
        c.issueNumber;
    c.branch = q.Branch_Name__c;
    c.commitSha = q.Commit_SHA__c;
    c.priority = q.Priority__c == null ? 3 : q.Priority__c.intValue();
    c.selfGenerated = q.Self_Generated__c;
    c.shippedAt = q.Shipped_At__c != null
      ? q.Shipped_At__c
      : (q.Status__c == 'Shipped' ? q.LastModifiedDate : null);
    if (!q.Run_Logs__r.isEmpty()) {
      c.reasoning = q.Run_Logs__r[0].AI_Reasoning_Notes__c;
      c.review = q.Run_Logs__r[0].Review_Comment_Summary__c;
      c.summary = q.Run_Logs__r[0].Daily_Summary__c;
    }
    return c;
  }

  private static void sortPlanned(List<QuestCard> cards) {
    // simple insertion sort by priority asc, then issue number asc
    for (Integer i = 1; i < cards.size(); i++) {
      QuestCard key = cards[i];
      Integer j = i - 1;
      while (j >= 0 && compare(cards[j], key) > 0) {
        cards[j + 1] = cards[j];
        j--;
      }
      cards[j + 1] = key;
    }
  }

  private static Integer compare(QuestCard a, QuestCard b) {
    if (a.priority != b.priority) {
      return a.priority - b.priority;
    }
    Integer ai = a.issueNumber == null ? 0 : a.issueNumber;
    Integer bi = b.issueNumber == null ? 0 : b.issueNumber;
    return ai - bi;
  }

  private static Integer toInt(Object o) {
    return o == null ? 0 : Integer.valueOf(String.valueOf(o));
  }
}
