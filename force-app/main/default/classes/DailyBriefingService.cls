/**
 * The Concierge's daily briefing: a short, human summary of what every agent did today,
 * written by the Einstein LLM and shown at the top of the Command Center.
 * Due once after the 13:30 IST mission and once in the evening (after 21:00 IST).
 */
public with sharing class DailyBriefingService {
  public static final String EVENT_TYPE = 'Daily Briefing';

  public static Boolean generateIfDue() {
    Datetime nowIst = Datetime.now().addMinutes(330);
    Integer hourIst = nowIst.hourGmt();
    Date todayIst = nowIst.dateGmt();
    Datetime startIstUtc = Datetime.newInstanceGmt(
        todayIst,
        Time.newInstance(0, 0, 0, 0)
      )
      .addMinutes(-330);
    Integer written = [
      SELECT COUNT()
      FROM Agent_Event__c
      WHERE Event_Type__c = :EVENT_TYPE AND Occurred_At__c >= :startIstUtc
      WITH SECURITY_ENFORCED
    ];
    Boolean due =
      (hourIst >= 14 && written == 0) || (hourIst >= 21 && written == 1);
    if (!due) {
      return false;
    }
    write(startIstUtc);
    return true;
  }

  public static void write(Datetime sinceUtc) {
    String feed = '';
    for (Agent_Event__c e : [
      SELECT Agent__c, Message__c, Occurred_At__c, Severity__c
      FROM Agent_Event__c
      WHERE Occurred_At__c >= :sinceUtc AND Event_Type__c != :EVENT_TYPE
      WITH SECURITY_ENFORCED
      ORDER BY Occurred_At__c ASC
      LIMIT 80
    ]) {
      feed +=
        '- ' +
        e.Occurred_At__c.addMinutes(330).formatGmt('HH:mm') +
        ' IST · ' +
        e.Agent__c +
        ': ' +
        e.Message__c +
        '\n';
    }
    Integer openPrs = [
      SELECT COUNT()
      FROM OSS_Contribution__c
      WHERE Status__c = 'PR_Open'
      WITH SECURITY_ENFORCED
    ];
    Integer merged = [
      SELECT COUNT()
      FROM OSS_Contribution__c
      WHERE Status__c = 'Merged'
      WITH SECURITY_ENFORCED
    ];
    Decimal streak;
    for (Agent_Run_Log__c l : [
      SELECT Streak_Days__c
      FROM Agent_Run_Log__c
      WHERE Streak_Days__c != NULL
      WITH SECURITY_ENFORCED
      ORDER BY Run_Date__c DESC
      LIMIT 1
    ]) {
      streak = l.Streak_Days__c;
    }
    Map<String, Object> out = AgentLLMClient.createJson(
      'You are the Concierge of an autonomous AI engineering squad (Scout, Engineer, Verifier, Reviewer, Publisher, Maintainer) ' +
        'that works on GitHub for its owner. Write the owner\'s daily briefing: warm, confident, specific, no fluff, no invented facts. ' +
        'Use only the activity log provided.',
      'Today\'s activity log (IST):\n' +
        (String.isBlank(feed) ? '(quiet so far)\n' : feed) +
        '\nStats: contribution streak ' +
        (streak == null ? 'unknown' : String.valueOf(streak.intValue())) +
        ' days, ' +
        openPrs +
        ' open upstream PRs, ' +
        merged +
        ' merged upstream PRs.' +
        '\n\nReturn "headline" (max 90 chars, punchy) and "briefing" (markdown, 3-5 short bullet points, max 110 words).',
      new List<String>{ 'headline', 'briefing' }
    );
    AgentEventLogger.addPublic(
      'Concierge',
      EVENT_TYPE,
      (String) out.get('headline'),
      (String) out.get('briefing')
    );
  }
}
