/**
 * Transaction Finalizer attached to every stage. If a stage throws (callout error,
 * invalid LLM output, governor limit), the run log is marked Failed with the error
 * and the quest is returned to the queue so tomorrow's run (or the GitHub watchdog) retries.
 */
public with sharing class AgentStageFinalizer implements Finalizer {
  public class StageException extends Exception {
  }

  private AgentPipelineState state;
  private String stage;

  public AgentStageFinalizer(AgentPipelineState state, String stage) {
    this.state = state;
    this.stage = stage;
  }

  public void execute(FinalizerContext ctx) {
    if (ctx.getResult() == ParentJobResult.SUCCESS) {
      return;
    }
    Exception e = ctx.getException();
    recordFailure(
      e == null
        ? 'Unknown failure'
        : e.getTypeName() +
          ': ' +
          e.getMessage() +
          '\n' +
          e.getStackTraceString()
    );
  }

  @TestVisible
  private void recordFailure(String detail) {
    AgentEventLogger.error(
      'Maintainer',
      'Mission failed',
      'Daily mission failed at ' +
        stage +
        ' — the watchdog will cover today if needed.',
      detail
    );
    AgentEventLogger.flush();
    if (state.runLogId != null) {
      update new Agent_Run_Log__c(
        Id = state.runLogId,
        Agent_Status__c = 'Failed',
        Stage__c = stage,
        Error_Detail__c = AgentHttp.abbreviate(detail, 32000),
        AI_Reasoning_Notes__c = AgentHttp.abbreviate(
          String.join(state.notes, '\n'),
          32000
        )
      );
    }
    if (state.questId != null) {
      List<Agent_Quest__c> qs = [
        SELECT Id, Status__c
        FROM Agent_Quest__c
        WHERE Id = :state.questId
        WITH SECURITY_ENFORCED
      ];
      if (!qs.isEmpty() && qs[0].Status__c == 'In Progress') {
        qs[0].Status__c = 'Queued';
        update qs;
      }
    }
  }
}
