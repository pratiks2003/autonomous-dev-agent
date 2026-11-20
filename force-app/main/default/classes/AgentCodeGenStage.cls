/**
 * Stage 2: RAG retrieval (one GraphQL call) + Einstein Models API code generation.
 */
public with sharing class AgentCodeGenStage implements Queueable, Database.AllowsCallouts {
  private AgentPipelineState state;

  public AgentCodeGenStage(AgentPipelineState state) {
    this.state = state;
  }

  public void execute(QueueableContext qc) {
    System.attachFinalizer(new AgentStageFinalizer(state, 'CodeGen'));
    AgentConfig cfg = AgentConfig.get();

    List<String> paths = AgentRAGCodeEngine.selectContextFiles(state);
    Map<String, String> retrieved = GitHubGraphQLService.fetchFiles(
      cfg.owner,
      cfg.repo,
      paths
    );
    state.note(
      'RAG retrieved ' +
        retrieved.size() +
        ' files: ' +
        String.join(new List<String>(retrieved.keySet()), ', ')
    );

    Map<String, Object> gen = AgentRAGCodeEngine.generate(state, retrieved);
    state.generatedJson = JSON.serialize(gen);
    state.note(
      'Einstein LLM produced ' +
        gen.get('filePath') +
        ' + ' +
        gen.get('unitTestPath')
    );

    update new Agent_Run_Log__c(
      Id = state.runLogId,
      Stage__c = 'CodeGen',
      AI_Reasoning_Notes__c = AgentHttp.abbreviate(
        (String) gen.get('reasoningNotes'),
        32000
      )
    );
    AgentEventLogger.info(
      'Engineer',
      'Code written',
      'Wrote ' +
        gen.get('filePath') +
        ' + ' +
        gen.get('unitTestPath') +
        ' for quest #' +
        state.issueNumber,
      null
    );
    AgentEventLogger.flush();
    DailyAgentOrchestrator.chain(new AgentShipStage(state));
  }
}
