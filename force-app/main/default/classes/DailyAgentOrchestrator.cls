/**
 * Entry point. Scheduled daily at 08:00 UTC and chains three Queueable stages
 * (Developer Edition caps chained Queueable depth at 5, so stages are merged):
 *
 *   AgentContextStage  -> sweep yesterday's PRs, GraphQL repo context, sync/generate quests
 *   AgentCodeGenStage  -> RAG retrieval + Einstein Models API code generation
 *   AgentShipStage     -> branch, commits, PR, AI review, auto-merge, release, profile README
 *
 * IMPORTANT: Salesforce cron runs in the scheduling user's time zone. scheduleDaily()
 * refuses to schedule unless that user is on GMT/UTC so the job fires at 08:00 UTC.
 */
public with sharing class DailyAgentOrchestrator implements Schedulable {
  public static final String CRON = '0 0 8 * * ?';
  public static final String JOB_NAME = 'Autonomous Dev Agent - Daily 08:00 UTC';
  private static final Set<String> UTC_ZONES = new Set<String>{
    'GMT',
    'UTC',
    'Etc/UTC',
    'Etc/GMT',
    'Europe/London'
  };

  @TestVisible
  private static List<Queueable> chainedInTest = new List<Queueable>();

  public class ScheduleException extends Exception {
  }

  public void execute(SchedulableContext sc) {
    start(false);
  }

  /** Creates today's run log and enqueues stage 1. Returns the run log Id (null if skipped). */
  public static Id start(Boolean manual) {
    AgentConfig cfg = AgentConfig.get();
    if (!cfg.enabled && !manual) {
      return null;
    }
    String key = AgentPipelineState.todayKey();
    if (!manual) {
      Integer doneToday = [
        SELECT COUNT()
        FROM Agent_Run_Log__c
        WHERE
          Run_Key__c = :key
          AND Agent_Status__c IN ('Success', 'Self_Generated_Quest', 'Running')
        WITH SECURITY_ENFORCED
      ];
      if (doneToday > 0) {
        return null;
      }
    }
    Agent_Run_Log__c log = new Agent_Run_Log__c(
      Run_Date__c = Datetime.now(),
      Run_Key__c = key,
      Agent_Status__c = 'Running',
      Stage__c = 'Queued',
      Manual_Run__c = manual
    );
    insert log;
    AgentPipelineState state = new AgentPipelineState();
    state.runLogId = log.Id;
    state.manual = manual;
    state.note(
      manual
        ? 'Manual run triggered from the Command Center.'
        : 'Scheduled run started (08:00 UTC).'
    );
    chain(new AgentContextStage(state));
    return log.Id;
  }

  public static void chain(Queueable job) {
    if (Test.isRunningTest()) {
      chainedInTest.add(job);
      return;
    }
    System.enqueueJob(job);
  }

  public static String scheduleDaily() {
    String tz = UserInfo.getTimeZone().getID();
    if (
      !UTC_ZONES.contains(tz) ||
      UserInfo.getTimeZone().getOffset(Datetime.now()) != 0
    ) {
      throw new ScheduleException(
        'Scheduling user time zone is ' +
          tz +
          '. Set it to GMT so "' +
          CRON +
          '" fires at 08:00 UTC.'
      );
    }
    for (CronTrigger ct : [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name = :JOB_NAME
    ]) {
      System.abortJob(ct.Id);
    }
    return System.schedule(JOB_NAME, CRON, new DailyAgentOrchestrator());
  }
}
