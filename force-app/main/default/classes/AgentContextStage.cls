/**
 * Stage 1: sweep yesterday's auto-merge PRs, load repo context via one GraphQL call,
 * sync open `agent-quest` issues into Agent_Quest__c, self-generate a quest when the
 * backlog is thin, and pick today's quest. All callouts happen before any DML.
 */
public with sharing class AgentContextStage implements Queueable, Database.AllowsCallouts {
  private AgentPipelineState state;

  public AgentContextStage(AgentPipelineState state) {
    this.state = state;
  }

  public void execute(QueueableContext qc) {
    System.attachFinalizer(new AgentStageFinalizer(state, 'Context'));
    AgentConfig cfg = AgentConfig.get();
    String repoName = cfg.fullRepo();

    // ---------- reads (SOQL is allowed before callouts)
    List<Agent_Quest__c> pending = [
      SELECT Id, PR_Number__c, Status__c, LastModifiedDate
      FROM Agent_Quest__c
      WHERE
        Status__c = 'Reviewed'
        AND PR_Number__c != NULL
        AND Repository_Name__c = :repoName
      WITH SECURITY_ENFORCED
      ORDER BY LastModifiedDate ASC
      LIMIT 5
    ];
    Map<Integer, Agent_Quest__c> byIssue = new Map<Integer, Agent_Quest__c>();
    for (Agent_Quest__c q : [
      SELECT
        Id,
        GitHub_Issue_Number__c,
        Status__c,
        Priority__c,
        Title__c,
        Self_Generated__c,
        Description__c,
        Quest_Type__c,
        RAG_Context_Tags__c
      FROM Agent_Quest__c
      WHERE Repository_Name__c = :repoName AND GitHub_Issue_Number__c != NULL
      WITH SECURITY_ENFORCED
    ]) {
      byIssue.put(q.GitHub_Issue_Number__c.intValue(), q);
    }
    List<String> recentTitles = new List<String>();
    for (Agent_Quest__c q : [
      SELECT Title__c
      FROM Agent_Quest__c
      WHERE Status__c IN ('Shipped', 'Reviewed')
      WITH SECURITY_ENFORCED
      ORDER BY LastModifiedDate DESC
      LIMIT 25
    ]) {
      recentTitles.add(q.Title__c);
    }

    // ---------- callouts
    GitHubLifecycleService.sweep(pending);
    GitHubGraphQLService.RepoContext ctx = GitHubGraphQLService.fetchRepoContext(
      cfg.owner,
      cfg.repo
    );
    state.defaultBranch = ctx.defaultBranch;
    state.baseSha = ctx.headSha;
    state.readme = AgentHttp.abbreviate(ctx.readme, 4000);
    state.guide = AgentHttp.abbreviate(ctx.guide, 4000);
    state.filePaths = ctx.filePaths;
    state.note(
      'Context loaded: ' +
        ctx.filePaths.size() +
        ' files, ' +
        ctx.openQuests.size() +
        ' open agent-quest issues.'
    );

    List<Agent_Quest__c> newQuests = new List<Agent_Quest__c>();
    Map<Integer, GitHubGraphQLService.IssueInfo> openByNumber = new Map<Integer, GitHubGraphQLService.IssueInfo>();
    for (GitHubGraphQLService.IssueInfo issue : ctx.openQuests) {
      openByNumber.put(issue.num, issue);
      if (!byIssue.containsKey(issue.num)) {
        Agent_Quest__c q = new Agent_Quest__c(
          Title__c = AgentHttp.abbreviate(issue.title, 240),
          Description__c = AgentHttp.abbreviate(issue.body, 32000),
          GitHub_Issue_Number__c = issue.num,
          Repository_Name__c = repoName,
          Quest_Type__c = typeFromLabels(issue.labels),
          Status__c = 'Queued',
          Priority__c = 3
        );
        newQuests.add(q);
        byIssue.put(issue.num, q);
      }
    }

    Integer available = 0;
    for (Integer num : openByNumber.keySet()) {
      String st = byIssue.get(num).Status__c;
      if (st != 'Reviewed' && st != 'Shipped') {
        available++;
      }
    }
    if (AutonomousQuestGenerator.needsQuest(available)) {
      Agent_Quest__c generated = AutonomousQuestGenerator.generate(
        ctx,
        recentTitles
      );
      newQuests.add(generated);
      byIssue.put(generated.GitHub_Issue_Number__c.intValue(), generated);
      openByNumber.put(generated.GitHub_Issue_Number__c.intValue(), null);
      state.note(
        'Backlog thin (' +
          available +
          ' open) — self-generated quest #' +
          generated.GitHub_Issue_Number__c.intValue() +
          ': ' +
          generated.Title__c
      );
    }

    // ---------- pick today's quest: lowest priority number, then oldest issue
    Agent_Quest__c pick;
    for (Integer num : openByNumber.keySet()) {
      Agent_Quest__c q = byIssue.get(num);
      if (q.Status__c == 'Reviewed' || q.Status__c == 'Shipped') {
        continue;
      }
      Decimal p = q.Priority__c == null ? 3 : q.Priority__c;
      Decimal best = pick == null
        ? null
        : (pick.Priority__c == null ? 3 : pick.Priority__c);
      if (
        pick == null ||
        p < best ||
        (p == best &&
        q.GitHub_Issue_Number__c < pick.GitHub_Issue_Number__c)
      ) {
        pick = q;
      }
    }
    if (pick == null) {
      throw new AgentStageFinalizer.StageException(
        'No actionable agent-quest issue found.'
      );
    }
    GitHubGraphQLService.IssueInfo info = openByNumber.get(
      pick.GitHub_Issue_Number__c.intValue()
    );
    state.issueNumber = pick.GitHub_Issue_Number__c.intValue();
    state.issueTitle = pick.Title__c;
    state.issueBody = info != null ? info.body : pick.Description__c;
    state.questType = pick.Quest_Type__c;
    state.ragTags = pick.RAG_Context_Tags__c;
    state.selfGenerated = pick.Self_Generated__c == true;
    state.note(
      'Selected quest #' + state.issueNumber + ': ' + state.issueTitle
    );

    // ---------- DML
    update pending;
    insert newQuests;
    pick.Status__c = 'In Progress';
    update pick;
    state.questId = pick.Id;
    update new Agent_Run_Log__c(
      Id = state.runLogId,
      Stage__c = 'Context',
      Agent_Quest__c = pick.Id
    );

    DailyAgentOrchestrator.chain(new AgentCodeGenStage(state));
  }

  @TestVisible
  private static String typeFromLabels(List<String> labels) {
    for (String l : labels) {
      if (l.startsWith('type:')) {
        String raw = l.substring(5);
        for (String t : AutonomousQuestGenerator.QUEST_TYPES) {
          if (t.equalsIgnoreCase(raw)) {
            return t;
          }
        }
      }
    }
    return 'Feature';
  }
}
