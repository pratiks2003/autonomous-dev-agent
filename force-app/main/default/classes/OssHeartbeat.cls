/**
 * Squad heartbeat — runs every 30 minutes (:15 and :45). Each beat:
 *   1. Concierge writes the daily briefing when it is due (after the 13:30 IST run, and an evening update).
 *   2. The open-source engine advances one step (see OssContributionEngine).
 */
public with sharing class OssHeartbeat implements Schedulable {
  public static final List<String> CRONS = new List<String>{
    '0 15 * * * ?',
    '0 45 * * * ?'
  };
  public static final String JOB_PREFIX = 'Agent Squad Heartbeat';

  public void execute(SchedulableContext sc) {
    if (!Test.isRunningTest()) {
      System.enqueueJob(new OssHeartbeatJob());
    }
  }

  public static List<String> scheduleAll() {
    for (CronTrigger ct : [
      SELECT Id
      FROM CronTrigger
      WHERE CronJobDetail.Name LIKE :(JOB_PREFIX + '%')
    ]) {
      System.abortJob(ct.Id);
    }
    List<String> ids = new List<String>();
    for (Integer i = 0; i < CRONS.size(); i++) {
      ids.add(
        System.schedule(
          JOB_PREFIX + ' ' + (i + 1),
          CRONS[i],
          new OssHeartbeat()
        )
      );
    }
    return ids;
  }
}
