/**
 * Activity feed for the agent squad. Events are buffered in memory (so they can be
 * recorded during callout-heavy transactions) and written with flush() after the
 * last callout of the transaction.
 */
public with sharing class AgentEventLogger {
  @TestVisible
  private static List<Agent_Event__c> buffer = new List<Agent_Event__c>();

  public static void info(
    String agent,
    String eventType,
    String message,
    String link
  ) {
    add(agent, eventType, message, link, null, 'info', null);
  }

  public static void success(
    String agent,
    String eventType,
    String message,
    String link
  ) {
    add(agent, eventType, message, link, null, 'success', null);
  }

  public static void warn(
    String agent,
    String eventType,
    String message,
    String detail
  ) {
    add(agent, eventType, message, null, detail, 'warning', null);
  }

  public static void error(
    String agent,
    String eventType,
    String message,
    String detail
  ) {
    add(agent, eventType, message, null, detail, 'error', null);
  }

  public static void add(
    String agent,
    String eventType,
    String message,
    String link,
    String detail,
    String severity,
    Id relatedId
  ) {
    buffer.add(
      new Agent_Event__c(
        Agent__c = agent,
        Event_Type__c = AgentHttp.abbreviate(eventType, 58),
        Message__c = AgentHttp.abbreviate(message, 250),
        Link__c = link != null && link.length() <= 255 ? link : null,
        Detail__c = AgentHttp.abbreviate(detail, 32000),
        Severity__c = severity,
        Occurred_At__c = Datetime.now(),
        Related_Record_Id__c = relatedId
      )
    );
  }

  /** Event whose detail is safe for the public dashboard (e.g. the daily briefing). */
  public static void addPublic(
    String agent,
    String eventType,
    String message,
    String publicDetail
  ) {
    add(agent, eventType, message, null, null, 'info', null);
    buffer[buffer.size() - 1].Public_Detail__c = AgentHttp.abbreviate(
      publicDetail,
      32000
    );
  }

  /** Inserts buffered events. Safe to call multiple times. */
  public static void flush() {
    if (buffer.isEmpty()) {
      return;
    }
    List<Agent_Event__c> toInsert = buffer;
    buffer = new List<Agent_Event__c>();
    Database.insert(toInsert, false);
  }
}
