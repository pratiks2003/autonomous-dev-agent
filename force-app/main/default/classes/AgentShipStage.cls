/**
 * Stage 3: branch -> 2 commits -> PR -> AI review -> auto-merge, then the weekly
 * semantic release, the contribution snapshot and the living profile README.
 */
public with sharing class AgentShipStage implements Queueable, Database.AllowsCallouts {
  private AgentPipelineState state;

  public AgentShipStage(AgentPipelineState state) {
    this.state = state;
  }

  public void execute(QueueableContext qc) {
    System.attachFinalizer(new AgentStageFinalizer(state, 'Ship'));
    AgentConfig cfg = AgentConfig.get();
    Map<String, Object> gen = state.generated();

    // ---------- reads
    String today = AgentPipelineState.todayKey();
    Integer priorSuccess = [
      SELECT COUNT()
      FROM Agent_Run_Log__c
      WHERE
        Agent_Status__c IN ('Success', 'Self_Generated_Quest')
        AND Run_Key__c != :today
      WITH SECURITY_ENFORCED
    ];
    Integer runNumber = priorSuccess + 1;
    Boolean releaseDue = Math.mod(runNumber, cfg.releaseEveryNRuns) == 0;
    List<Agent_Quest__c> recent = [
      SELECT Title__c, PR_Number__c, PR_Url__c, Quest_Type__c
      FROM Agent_Quest__c
      WHERE Status__c IN ('Shipped', 'Reviewed') AND PR_Number__c != NULL
      WITH SECURITY_ENFORCED
      ORDER BY LastModifiedDate DESC
      LIMIT :cfg.releaseEveryNRuns
    ];
    String lastTag;
    for (Agent_Run_Log__c l : [
      SELECT Release_Tag__c
      FROM Agent_Run_Log__c
      WHERE Release_Tag__c != NULL
      WITH SECURITY_ENFORCED
      ORDER BY Run_Date__c DESC
      LIMIT 1
    ]) {
      lastTag = l.Release_Tag__c;
    }

    // ---------- callouts
    GitHubLifecycleService.ShipResult r = GitHubLifecycleService.ship(
      state,
      gen
    );
    state.note(
      'PR #' +
        r.prNumber +
        ' opened, review posted, ' +
        (r.merged
          ? 'merged (squash).'
          : (r.autoMergeEnabled
              ? 'auto-merge armed (waits for CI).'
              : 'awaiting merge.'))
    );

    String releaseTag;
    if (releaseDue) {
      Integer week = runNumber / cfg.releaseEveryNRuns;
      String notes =
        '## 🚀 What shipped this week\n\n- ' +
        gen.get('prTitle') +
        ' (#' +
        r.prNumber +
        ')\n';
      for (Agent_Quest__c q : recent) {
        notes += '- ' + q.Title__c + ' (#' + q.PR_Number__c.intValue() + ')\n';
      }
      notes += '\n_All changes planned, written, tested and reviewed by the autonomous agent (Salesforce Apex + Einstein)._';
      releaseTag = GitHubLifecycleService.publishRelease(week, notes);
      if (releaseTag != null) {
        state.note('Published release ' + releaseTag);
      }
    }

    String snapshot;
    Integer streak = 0;
    try {
      snapshot = GitHubGraphQLService.fetchContributionSnapshot(cfg.owner);
      streak = GitHubLifecycleService.streakFromSnapshot(snapshot);
    } catch (Exception e) {
      state.note('Contribution snapshot skipped: ' + e.getMessage());
    }
    Boolean readmeOk = GitHubLifecycleService.updateProfileReadme(
      GitHubLifecycleService.buildProfileBlock(
        Math.max(streak, 1),
        (String) gen.get('prTitle'),
        r.prUrl,
        releaseTag != null ? releaseTag : lastTag,
        cfg.siteUrl
      )
    );
    state.note(
      readmeOk
        ? 'Profile README refreshed.'
        : 'Profile README update failed (check profile repo access).'
    );

    // ---------- DML
    update new Agent_Quest__c(
      Id = state.questId,
      Status__c = r.merged ? 'Shipped' : 'Reviewed',
      Branch_Name__c = r.branch,
      PR_Number__c = r.prNumber,
      PR_Url__c = r.prUrl,
      Commit_SHA__c = r.merged ? r.mergeSha : r.headSha,
      Shipped_At__c = r.merged ? Datetime.now() : null
    );
    update new Agent_Run_Log__c(
      Id = state.runLogId,
      Stage__c = 'Shipped',
      Agent_Status__c = state.selfGenerated
        ? 'Self_Generated_Quest'
        : 'Success',
      Daily_Summary__c = AgentHttp.abbreviate(
        '**' +
          gen.get('prTitle') +
          '** → PR #' +
          r.prNumber +
          ' for issue #' +
          state.issueNumber +
          '\n\n' +
          (String) gen.get('prBody'),
        32000
      ),
      Review_Comment_Summary__c = AgentHttp.abbreviate(
        (String) gen.get('codeReviewCritique'),
        32000
      ),
      AI_Reasoning_Notes__c = AgentHttp.abbreviate(
        (String) gen.get('reasoningNotes') +
          '\n\n---\n' +
          String.join(state.notes, '\n'),
        32000
      ),
      Release_Tag__c = releaseTag,
      Streak_Days__c = streak,
      Contribution_Snapshot__c = snapshot
    );
  }
}
