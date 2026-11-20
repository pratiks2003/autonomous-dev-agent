/** Queueable half of the squad heartbeat (Schedulable classes cannot also be Queueable). */
public with sharing class OssHeartbeatJob implements Queueable, Database.AllowsCallouts {
  public void execute(QueueableContext qc) {
    try {
      DailyBriefingService.generateIfDue();
    } catch (Exception e) {
      AgentEventLogger.warn(
        'Concierge',
        'Briefing skipped',
        'Could not write the briefing: ' +
        AgentHttp.abbreviate(e.getMessage(), 150),
        e.getStackTraceString()
      );
    }
    try {
      OssContributionEngine.tick();
    } catch (Exception e) {
      AgentEventLogger.error(
        'Scout',
        'Heartbeat error',
        AgentHttp.abbreviate(e.getMessage(), 200),
        e.getStackTraceString()
      );
    }
    AgentEventLogger.flush();
    try {
      AgentDataJanitor.run();
    } catch (Exception e) {
      System.debug(LoggingLevel.WARN, 'Janitor skipped: ' + e.getMessage());
    }
  }
}
