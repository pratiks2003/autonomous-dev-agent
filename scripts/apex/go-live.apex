// Run as the admin who owns the agent (their time zone must be GMT):
//   sf apex run -o watchitbuild -f scripts/apex/go-live.apex
System.debug('Scheduled job: ' + DailyAgentOrchestrator.scheduleDaily());
