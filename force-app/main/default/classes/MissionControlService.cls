/**
 * Plain-language answers for the Mission Control Agentforce agent. Every method returns
 * text the agent can relay directly; the invocable McAction* classes are thin wrappers.
 */
public with sharing class MissionControlService {
  public static String status() {
    AgentCommandCenterController.Dashboard d = AgentCommandCenterController.getDashboard();
    String s =
      '🔥 Streak: ' +
      d.streak +
      ' days · ' +
      d.totalContributions +
      ' contributions in the last year.\n' +
      '📊 Activity: ' +
      d.commits +
      ' commits, ' +
      d.prs +
      ' PRs, ' +
      d.reviews +
      ' reviews, ' +
      d.issues +
      ' issues.\n' +
      '🏷️ Latest release: ' +
      (d.latestRelease == null ? 'none yet' : d.latestRelease) +
      '.\n';
    if (d.lastRun != null) {
      s +=
        '🤖 Last daily mission: ' +
        d.lastRun.status +
        ' at stage ' +
        d.lastRun.stage +
        ' (' +
        d.lastRun.runDate.addMinutes(330).formatGmt('dd MMM HH:mm') +
        ' IST)';
      s += d.lastRun.questTitle == null
        ? '.\n'
        : ' — "' + d.lastRun.questTitle + '".\n';
    }
    s += '🌍 Open source: ' + contributionsLine() + '\n';
    for (Agent_Event__c b : [
      SELECT Message__c
      FROM Agent_Event__c
      WHERE Event_Type__c = :DailyBriefingService.EVENT_TYPE
      WITH SECURITY_ENFORCED
      ORDER BY Occurred_At__c DESC
      LIMIT 1
    ]) {
      s += '📰 Latest briefing: ' + b.Message__c;
    }
    return s;
  }

  public static String contributionsLine() {
    Map<String, Integer> counts = new Map<String, Integer>();
    for (AggregateResult ar : [
      SELECT Status__c st, COUNT(Id) n
      FROM OSS_Contribution__c
      WITH SECURITY_ENFORCED
      GROUP BY Status__c
    ]) {
      counts.put((String) ar.get('st'), (Integer) ar.get('n'));
    }
    Integer inFlight = 0;
    for (String st : OssContributionEngine.IN_FLIGHT) {
      inFlight += counts.containsKey(st) ? counts.get(st) : 0;
    }
    return inFlight +
      ' in progress, ' +
      nz(counts.get('PR_Open')) +
      ' PRs open, ' +
      nz(counts.get('Merged')) +
      ' merged, ' +
      nz(counts.get('Discovered')) +
      ' on the radar.';
  }

  public static String contributions(Integer max) {
    String s = '';
    for (OSS_Contribution__c c : [
      SELECT
        Name,
        Repo__c,
        Issue_Number__c,
        Issue_Title__c,
        Status__c,
        PR_Url__c,
        Test_Result__c,
        Skip_Reason__c,
        Stars__c
      FROM OSS_Contribution__c
      WITH SECURITY_ENFORCED
      ORDER BY LastModifiedDate DESC
      LIMIT :max
    ]) {
      s +=
        '• ' +
        c.Repo__c +
        '#' +
        c.Issue_Number__c.intValue() +
        ' (★' +
        nz(c.Stars__c == null ? null : c.Stars__c.intValue()) +
        ') — ' +
        c.Issue_Title__c +
        ' → ' +
        c.Status__c.replace('_', ' ') +
        (c.PR_Url__c != null ? ' · ' + c.PR_Url__c : '') +
        (c.Skip_Reason__c != null ? ' (' + c.Skip_Reason__c + ')' : '') +
        '\n';
    }
    return String.isBlank(s)
      ? 'No open-source contributions yet — the Scout scans every 30 minutes when nothing is in flight.'
      : s;
  }

  public static String activity(Integer hours) {
    Integer h = hours == null || hours <= 0 ? 24 : Math.min(hours, 168);
    Datetime since = Datetime.now().addHours(-h);
    String s = '';
    for (Agent_Event__c e : [
      SELECT Agent__c, Message__c, Occurred_At__c
      FROM Agent_Event__c
      WHERE Occurred_At__c >= :since
      WITH SECURITY_ENFORCED
      ORDER BY Occurred_At__c DESC
      LIMIT 25
    ]) {
      s +=
        '• ' +
        e.Occurred_At__c.addMinutes(330).formatGmt('dd MMM HH:mm') +
        ' IST — ' +
        e.Agent__c +
        ': ' +
        e.Message__c +
        '\n';
    }
    return String.isBlank(s)
      ? 'No agent activity in the last ' + h + ' hours.'
      : s;
  }

  public static String runMission() {
    Id logId = DailyAgentOrchestrator.start(true);
    AgentEventLogger.info(
      'Concierge',
      'Mission requested',
      'Owner asked Mission Control to run the daily mission now.',
      null
    );
    AgentEventLogger.flush();
    return logId == null
      ? 'The mission is disabled in configuration.'
      : 'Daily mission started (run ' +
        logId +
        '). The Maintainer will pick a quest, write code, open and review a PR in about a minute — watch the Command Center.';
  }

  public static String queueQuest(
    String title,
    String details,
    String questType
  ) {
    if (String.isBlank(title)) {
      return 'I need a title for the quest.';
    }
    Id questId = AgentCommandCenterController.enqueueCustomQuest(
      title,
      details,
      questType,
      1
    );
    return 'Queued quest "' +
      title +
      '" at top priority (record ' +
      questId +
      '). It is being published as a GitHub issue and will be picked up by the next mission.';
  }

  public static String scoutNow() {
    if (!Test.isRunningTest()) {
      System.enqueueJob(new OssHeartbeatJob());
    }
    return 'The Scout is on it. ' +
      contributionsLine() +
      ' New finds will appear in the Command Center within a few minutes.';
  }

  public static String contributeTo(String issueUrl) {
    Matcher m = Pattern.compile(
        'github\\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/issues/(\\d+)'
      )
      .matcher(issueUrl == null ? '' : issueUrl);
    if (!m.find()) {
      return 'Please give me a GitHub issue URL like https://github.com/owner/repo/issues/123.';
    }
    String repo = m.group(1);
    Integer num = Integer.valueOf(m.group(2));
    Integer existing = [
      SELECT COUNT()
      FROM OSS_Contribution__c
      WHERE Repo__c = :repo AND Issue_Number__c = :num
      WITH SECURITY_ENFORCED
    ];
    if (existing > 0) {
      return 'That issue is already being tracked.';
    }
    insert new OSS_Contribution__c(
      Repo__c = repo,
      Issue_Number__c = num,
      Issue_Url__c = 'https://github.com/' + repo + '/issues/' + num,
      Issue_Title__c = 'Requested by owner: ' + repo + '#' + num,
      Language__c = 'TypeScript',
      Status__c = 'Discovered',
      Feasibility_Score__c = 10,
      Test_Result__c = 'Pending',
      Review_Verdict__c = 'Pending',
      Attempts__c = 0,
      Last_Step_At__c = Datetime.now()
    );
    AgentEventLogger.info(
      'Concierge',
      'Issue requested',
      'Owner asked the squad to take on ' + repo + '#' + num,
      'https://github.com/' + repo + '/issues/' + num
    );
    AgentEventLogger.flush();
    return 'Added ' +
      repo +
      '#' +
      num +
      ' to the top of the radar. The Scout will vet it and the Engineer will start on the next heartbeat.';
  }

  private static Integer nz(Integer i) {
    return i == null ? 0 : i;
  }
}
