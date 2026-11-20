/**
 * Keeps the org inside Developer Edition's 5 MB data storage (~2 KB per record) for years.
 * Runs on the squad heartbeat (cheap no-op unless something is past retention).
 *
 *   Agent_Event__c        7 days (daily briefings 30 days), hard cap 500
 *   OSS_Contribution__c   Skipped / Failed / Discovered: 14 days; Closed: 90 days (PR_Open / Merged kept)
 *   Agent_Run_Log__c      90 days
 *   Agent_Quest__c        Shipped / Failed: 120 days (history lives on GitHub)
 *
 * Deleted rows are also purged from the Recycle Bin. Steady state is ~1,000 records (~2 MB).
 */
public with sharing class AgentDataJanitor {
  public static final Integer EVENT_DAYS = 7;
  public static final Integer BRIEFING_DAYS = 30;
  public static final Integer EVENT_CAP = 500;

  public static Integer run() {
    Datetime now = Datetime.now();
    List<SObject> doomed = new List<SObject>();
    doomed.addAll(
      [
        SELECT Id
        FROM Agent_Event__c
        WHERE
          (Occurred_At__c < :now.addDays(-EVENT_DAYS)
          AND Event_Type__c != :DailyBriefingService.EVENT_TYPE)
          OR Occurred_At__c < :now.addDays(-BRIEFING_DAYS)
        LIMIT 2000
      ]
    );
    Integer events = [SELECT COUNT() FROM Agent_Event__c];
    if (events - doomed.size() > EVENT_CAP) {
      doomed.addAll(
        [
          SELECT Id
          FROM Agent_Event__c
          WHERE Id NOT IN :doomed
          ORDER BY Occurred_At__c ASC
          LIMIT :Math.min(2000, events - doomed.size() - EVENT_CAP)
        ]
      );
    }
    doomed.addAll(
      [
        SELECT Id
        FROM OSS_Contribution__c
        WHERE
          (Status__c IN ('Skipped', 'Failed', 'Discovered')
          AND LastModifiedDate < :now.addDays(-14))
          OR (Status__c = 'Closed'
          AND LastModifiedDate < :now.addDays(-90))
        LIMIT 1000
      ]
    );
    doomed.addAll(
      [
        SELECT Id
        FROM Agent_Run_Log__c
        WHERE Run_Date__c < :now.addDays(-90)
        LIMIT 1000
      ]
    );
    doomed.addAll(
      [
        SELECT Id
        FROM Agent_Quest__c
        WHERE
          Status__c IN ('Shipped', 'Failed')
          AND LastModifiedDate < :now.addDays(-120)
        LIMIT 1000
      ]
    );
    if (doomed.isEmpty()) {
      return 0;
    }
    Database.delete(doomed, false);
    Database.emptyRecycleBin(doomed);
    return doomed.size();
  }
}
