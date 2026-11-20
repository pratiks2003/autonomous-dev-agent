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
    // Release cadence without relying on old records (the janitor prunes logs after 90 days):
    // due when the last N days had successful runs and no release was published in that window.
    Datetime windowStart = Datetime.now().addDays(-cfg.releaseEveryNRuns);
    Integer recentSuccess = [
      SELECT COUNT()
      FROM Agent_Run_Log__c
      WHERE
        Agent_Status__c IN ('Success', 'Self_Generated_Quest')
        AND Run_Key__c != :today
        AND Run_Date__c >= :windowStart
      WITH SECURITY_ENFORCED
    ];
    Integer recentReleases = [
      SELECT COUNT()
      FROM Agent_Run_Log__c
      WHERE Release_Tag__c != NULL AND Run_Date__c >= :windowStart
      WITH SECURITY_ENFORCED
    ];
    Boolean releaseDue =
      recentSuccess >= cfg.releaseEveryNRuns - 1 &&
      recentReleases == 0;
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
      Integer week = GitHubLifecycleService.nextReleaseWeek();
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
    AgentEventLogger.success(
      'Publisher',
      r.merged ? 'PR merged' : 'PR opened',
      (r.merged ? 'Merged PR #' : 'Opened PR #') +
        r.prNumber +
        ' in ' +
        cfg.repo +
        ' — ' +
        gen.get('prTitle') +
        (r.autoMergeEnabled ? ' (auto-merge armed, waiting for CI)' : ''),
      r.prUrl
    );
    AgentEventLogger.info(
      'Reviewer',
      'Code reviewed',
      'Posted a code review on PR #' +
        r.prNumber +
        ' (complexity, edge cases, security).',
      r.prUrl
    );
    if (releaseTag != null) {
      AgentEventLogger.success(
        'Maintainer',
        'Release published',
        'Published release ' + releaseTag,
        'https://github.com/' + cfg.fullRepo() + '/releases/tag/' + releaseTag
      );
    }
    AgentEventLogger.flush();
  }
}
