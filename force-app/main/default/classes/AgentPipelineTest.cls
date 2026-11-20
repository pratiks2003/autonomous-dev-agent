@IsTest
private class AgentPipelineTest {
  private static AgentPipelineState baseState(Id logId, Id questId) {
    AgentPipelineState s = new AgentPipelineState();
    s.runLogId = logId;
    s.questId = questId;
    s.issueNumber = 42;
    s.issueTitle = 'Add debounce helper';
    s.issueBody = 'Implement debounce';
    s.questType = 'Feature';
    s.ragTags = 'async,slugify';
    s.defaultBranch = 'main';
    s.baseSha = 'a'.repeat(40);
    s.filePaths = new List<String>{
      'src/index.ts',
      'src/strings/slugify.ts',
      'tests/slugify.test.ts',
      'README.md'
    };
    return s;
  }

  @IsTest
  static void startCreatesRunLogAndChainsContextStage() {
    Id logId = DailyAgentOrchestrator.start(true);
    Agent_Run_Log__c log = [
      SELECT Agent_Status__c, Run_Key__c, Manual_Run__c
      FROM Agent_Run_Log__c
      WHERE Id = :logId
    ];
    Assert.areEqual('Running', log.Agent_Status__c);
    Assert.isTrue(log.Manual_Run__c);
    Assert.isTrue(
      DailyAgentOrchestrator.chainedInTest[0] instanceof AgentContextStage
    );
    // Scheduled run on the same day is skipped (idempotent)
    Assert.isNull(DailyAgentOrchestrator.start(false));
  }

  @IsTest
  static void schedulableExecuteStartsRun() {
    new DailyAgentOrchestrator().execute(null);
    Assert.areEqual(1, [SELECT COUNT() FROM Agent_Run_Log__c]);
  }

  @IsTest
  static void contextStageSweepsSyncsGeneratesAndPicks() {
    Agent_Quest__c reviewed = new Agent_Quest__c(
      Title__c = 'Old',
      Status__c = 'Reviewed',
      PR_Number__c = 5,
      GitHub_Issue_Number__c = 3,
      Repository_Name__c = AgentConfig.get().fullRepo()
    );
    insert reviewed;
    Agent_Run_Log__c log = new Agent_Run_Log__c(
      Agent_Status__c = 'Running',
      Run_Key__c = AgentPipelineState.todayKey()
    );
    insert log;
    AgentPipelineState s = new AgentPipelineState();
    s.runLogId = log.Id;
    AgentMockRouter router = new AgentMockRouter();
    Test.setMock(HttpCalloutMock.class, router);
    AgentLLMClient.provider = router;

    Test.startTest();
    System.enqueueJob(new AgentContextStage(s));
    Test.stopTest();

    Assert.areEqual(
      'Shipped',
      [SELECT Status__c FROM Agent_Quest__c WHERE Id = :reviewed.Id].Status__c,
      'sweep marks merged PR shipped'
    );
    Agent_Quest__c generated = [
      SELECT Status__c, Self_Generated__c, Quest_Type__c
      FROM Agent_Quest__c
      WHERE GitHub_Issue_Number__c = 42
    ];
    Assert.isTrue(generated.Self_Generated__c);
    Assert.areEqual(
      'In Progress',
      generated.Status__c,
      'priority 2 self-generated quest beats priority 3 synced issue'
    );
    Assert.areEqual(
      'Unit_Test',
      [
        SELECT Quest_Type__c
        FROM Agent_Quest__c
        WHERE GitHub_Issue_Number__c = 10
      ]
      .Quest_Type__c
    );
    Assert.areEqual(
      'Context',
      [SELECT Stage__c FROM Agent_Run_Log__c WHERE Id = :log.Id].Stage__c
    );
    Assert.isTrue(
      DailyAgentOrchestrator.chainedInTest[0] instanceof AgentCodeGenStage
    );
  }

  @IsTest
  static void codeGenStageProducesValidatedOutput() {
    Agent_Quest__c q = new Agent_Quest__c(
      Title__c = 'Add debounce helper',
      Status__c = 'In Progress',
      GitHub_Issue_Number__c = 42
    );
    insert q;
    Agent_Run_Log__c log = new Agent_Run_Log__c(Agent_Status__c = 'Running');
    insert log;
    AgentMockRouter router = new AgentMockRouter();
    Test.setMock(HttpCalloutMock.class, router);
    AgentLLMClient.provider = router;

    Test.startTest();
    System.enqueueJob(new AgentCodeGenStage(baseState(log.Id, q.Id)));
    Test.stopTest();

    Agent_Run_Log__c after = [
      SELECT Stage__c, AI_Reasoning_Notes__c
      FROM Agent_Run_Log__c
      WHERE Id = :log.Id
    ];
    Assert.areEqual('CodeGen', after.Stage__c);
    Assert.isTrue(after.AI_Reasoning_Notes__c.contains('closure'));
    Assert.isTrue(
      DailyAgentOrchestrator.chainedInTest[0] instanceof AgentShipStage
    );
  }

  @IsTest
  static void shipStageMergesReleasesAndRefreshesProfile() {
    List<Agent_Run_Log__c> prior = new List<Agent_Run_Log__c>();
    for (Integer i = 1; i <= 6; i++) {
      prior.add(
        new Agent_Run_Log__c(
          Agent_Status__c = 'Success',
          Run_Key__c = '2026-01-0' + i,
          Run_Date__c = Datetime.now().addDays(-i)
        )
      );
    }
    insert prior;
    Agent_Quest__c q = new Agent_Quest__c(
      Title__c = 'Add debounce helper',
      Status__c = 'In Progress',
      GitHub_Issue_Number__c = 42
    );
    insert q;
    Agent_Run_Log__c log = new Agent_Run_Log__c(
      Agent_Status__c = 'Running',
      Run_Key__c = AgentPipelineState.todayKey()
    );
    insert log;
    AgentPipelineState s = baseState(log.Id, q.Id);
    s.generatedJson = JSON.serialize(
      new Map<String, Object>{
        'filePath' => 'src/async/debounce.ts',
        'fileContent' => 'export {}',
        'unitTestPath' => 'tests/debounce.test.ts',
        'unitTestContent' => 'test',
        'commitMessage' => 'feat: debounce',
        'prTitle' => 'feat: debounce',
        'prBody' => 'body',
        'codeReviewCritique' => 'critique',
        'reasoningNotes' => 'notes'
      }
    );
    AgentMockRouter mock = new AgentMockRouter();
    mock.profileReadmeExists = true;
    Test.setMock(HttpCalloutMock.class, mock);
    AgentLLMClient.provider = mock;

    Test.startTest();
    System.enqueueJob(new AgentShipStage(s));
    Test.stopTest();

    Agent_Quest__c shipped = [
      SELECT Status__c, PR_Number__c, Branch_Name__c
      FROM Agent_Quest__c
      WHERE Id = :q.Id
    ];
    Assert.areEqual(
      'Shipped',
      shipped.Status__c,
      'auto-merge refused -> direct squash merge'
    );
    Assert.areEqual(7, shipped.PR_Number__c);
    Assert.areEqual('agent/quest-42', shipped.Branch_Name__c);
    Agent_Run_Log__c done = [
      SELECT
        Agent_Status__c,
        Release_Tag__c,
        Streak_Days__c,
        Contribution_Snapshot__c
      FROM Agent_Run_Log__c
      WHERE Id = :log.Id
    ];
    Assert.areEqual('Success', done.Agent_Status__c);
    Assert.areEqual('v1.1.0', done.Release_Tag__c);
    Assert.areEqual(2, done.Streak_Days__c);
    Assert.isNotNull(done.Contribution_Snapshot__c);
  }

  @IsTest
  static void finalizerMarksFailureAndRequeuesQuest() {
    Agent_Quest__c q = new Agent_Quest__c(
      Title__c = 'x',
      Status__c = 'In Progress'
    );
    insert q;
    Agent_Run_Log__c log = new Agent_Run_Log__c(Agent_Status__c = 'Running');
    insert log;
    AgentPipelineState s = baseState(log.Id, q.Id);
    s.note('something happened');
    new AgentStageFinalizer(s, 'CodeGen').recordFailure('boom');
    Agent_Run_Log__c after = [
      SELECT Agent_Status__c, Stage__c, Error_Detail__c
      FROM Agent_Run_Log__c
      WHERE Id = :log.Id
    ];
    Assert.areEqual('Failed', after.Agent_Status__c);
    Assert.areEqual('CodeGen', after.Stage__c);
    Assert.areEqual(
      'Queued',
      [SELECT Status__c FROM Agent_Quest__c WHERE Id = :q.Id].Status__c
    );
  }

  @IsTest
  static void contextStageFailsWithoutLlmAndFinalizerRecords() {
    Agent_Run_Log__c log = new Agent_Run_Log__c(Agent_Status__c = 'Running');
    insert log;
    AgentPipelineState s = new AgentPipelineState();
    s.runLogId = log.Id;
    AgentMockRouter mock = new AgentMockRouter();
    mock.llmStatus = 500;
    Test.setMock(HttpCalloutMock.class, mock);
    AgentLLMClient.provider = mock;
    Test.startTest();
    System.enqueueJob(new AgentContextStage(s));
    try {
      Test.stopTest();
    } catch (Exception e) {
      // the stage exception may surface here; the finalizer still runs
      System.debug(LoggingLevel.INFO, 'Expected failure: ' + e.getMessage());
    }
    Assert.areEqual(
      'Failed',
      [SELECT Agent_Status__c FROM Agent_Run_Log__c WHERE Id = :log.Id]
      .Agent_Status__c
    );
  }

  @IsTest
  static void ragSelectionAndValidation() {
    AgentPipelineState s = baseState(null, null);
    List<String> picked = AgentRAGCodeEngine.selectContextFiles(s);
    Assert.areEqual(
      'src/strings/slugify.ts',
      picked[0],
      'tag match ranks first'
    );
    Assert.isTrue(picked.contains('tests/slugify.test.ts'));
    Assert.isTrue(picked.contains('src/index.ts'));

    Map<String, Object> bad = new Map<String, Object>();
    for (String f : AgentRAGCodeEngine.OUTPUT_FIELDS) {
      bad.put(f, 'x');
    }
    bad.put('filePath', '.github/workflows/ci.yml');
    bad.put('unitTestPath', 'tests/a.test.ts');
    try {
      AgentRAGCodeEngine.validate(bad);
      Assert.fail('unsafe path should be rejected');
    } catch (AgentRAGCodeEngine.InvalidGenerationException e) {
      Assert.isTrue(e.getMessage().contains('Unsafe path'));
    }
    bad.put('filePath', '');
    try {
      AgentRAGCodeEngine.validate(bad);
      Assert.fail('missing field should be rejected');
    } catch (AgentRAGCodeEngine.InvalidGenerationException e) {
      Assert.isTrue(e.getMessage().contains('missing'));
    }
  }

  @IsTest
  static void helpers() {
    Assert.areEqual(
      'Refactor',
      AgentContextStage.typeFromLabels(
        new List<String>{ 'agent-quest', 'type:refactor' }
      )
    );
    Assert.areEqual(
      'Feature',
      AgentContextStage.typeFromLabels(new List<String>{ 'agent-quest' })
    );
    String merged = GitHubLifecycleService.mergeBlock(
      '# Me\n<!-- AGENT:START -->old<!-- AGENT:END -->\nfooter',
      '<!-- AGENT:START -->new<!-- AGENT:END -->'
    );
    Assert.isTrue(
      merged.contains('new') &&
        !merged.contains('old') &&
        merged.contains('footer')
    );
    Assert.isTrue(
      GitHubLifecycleService.mergeBlock('# Me', 'B').endsWith('B\n')
    );
    Assert.isTrue(GitHubLifecycleService.mergeBlock('', 'B').contains('B'));
    Assert.areEqual(0, GitHubLifecycleService.streakFromSnapshot(null));
    String block = GitHubLifecycleService.buildProfileBlock(
      12,
      'feat: x | y',
      'https://x',
      null,
      ''
    );
    Assert.isTrue(
      block.contains('**12 days**') && block.contains('pre-release')
    );
    Assert.isNotNull(GitHubLifecycleService.parseGitHubDate(null));
    Assert.areEqual('abc…', AgentHttp.abbreviate('abcdef', 3));
    Assert.areEqual('', AgentHttp.abbreviate(null, 3));
    Assert.isTrue(AutonomousQuestGenerator.needsQuest(0));
    Assert.areEqual(2, AutonomousQuestGenerator.parsePriority('P2'));
    Assert.areEqual(3, AutonomousQuestGenerator.parsePriority('high'));
    Assert.areEqual(
      'b',
      (String) AgentLLMClient.extractJson('x {"a":"b"} y').get('a')
    );
    try {
      AgentLLMClient.extractJson('no json');
      Assert.fail('must reject');
    } catch (AgentLLMClient.LlmException e) {
      Assert.isNotNull(e);
    }
  }

  @IsTest
  static void scheduleRequiresUtcUser() {
    Profile p = [
      SELECT Id
      FROM Profile
      WHERE Name = 'System Administrator'
      LIMIT 1
    ];
    User gmt = new User(
      Alias = 'agentutc',
      Email = 'agent.utc@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Utc',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = p.Id,
      TimeZoneSidKey = 'GMT',
      Username = 'agent.utc.' + Crypto.getRandomInteger() + '@example.com'
    );
    User la = gmt.clone();
    la.Alias = 'agentla';
    la.TimeZoneSidKey = 'America/Los_Angeles';
    la.Username = 'agent.la.' + Crypto.getRandomInteger() + '@example.com';
    insert new List<User>{ gmt, la };
    System.runAs(gmt) {
      Assert.isNotNull(DailyAgentOrchestrator.scheduleDaily());
    }
    System.runAs(la) {
      try {
        DailyAgentOrchestrator.scheduleDaily();
        Assert.fail('non-UTC user must not schedule');
      } catch (DailyAgentOrchestrator.ScheduleException e) {
        Assert.isTrue(e.getMessage().contains('GMT'));
      }
    }
  }

  @IsTest
  static void publishJobCreatesIssue() {
    Agent_Quest__c q = new Agent_Quest__c(
      Title__c = 'Custom',
      Description__c = 'do it',
      Quest_Type__c = 'Docs',
      Status__c = 'Queued'
    );
    insert q;
    AgentMockRouter router = new AgentMockRouter();
    Test.setMock(HttpCalloutMock.class, router);
    AgentLLMClient.provider = router;
    Test.startTest();
    System.enqueueJob(new AutonomousQuestGenerator.PublishJob(q.Id));
    Test.stopTest();
    Assert.areEqual(
      42,
      [SELECT GitHub_Issue_Number__c FROM Agent_Quest__c WHERE Id = :q.Id]
      .GitHub_Issue_Number__c
    );
  }

  @IsTest
  static void lifecycleAutoMergeAndStuckSweep() {
    AgentMockRouter mock = new AgentMockRouter();
    mock.autoMergeFails = false;
    Test.setMock(HttpCalloutMock.class, mock);
    AgentLLMClient.provider = mock;
    Test.startTest();
    AgentPipelineState s = baseState(null, null);
    Map<String, Object> gen = new Map<String, Object>{
      'filePath' => 'src/a.ts',
      'fileContent' => 'x',
      'unitTestPath' => 'tests/a.test.ts',
      'unitTestContent' => 'y',
      'commitMessage' => 'feat: a',
      'prTitle' => 'feat: a',
      'prBody' => 'b',
      'codeReviewCritique' => 'c'
    };
    GitHubLifecycleService.ShipResult r = GitHubLifecycleService.ship(s, gen);
    Assert.isTrue(r.autoMergeEnabled);
    Assert.isFalse(r.merged);
    Assert.areEqual(
      'v1.3.0',
      GitHubLifecycleService.publishRelease(3, 'notes')
    );
    Assert.isTrue(
      GitHubLifecycleService.updateProfileReadme(
        '<!-- AGENT:START -->x<!-- AGENT:END -->'
      )
    );
    Test.stopTest();
  }

  @IsTest
  static void indexExportIsAppendedOnce() {
    Assert.areEqual(
      'export * from "./math/clamp";',
      GitHubLifecycleService.indexExportLine('src/math/clamp.ts')
    );
    AgentMockRouter mock = new AgentMockRouter();
    mock.indexExists = true;
    Test.setMock(HttpCalloutMock.class, mock);
    Test.startTest();
    Assert.isNotNull(
      GitHubLifecycleService.ensureIndexExport(
        '/repos/o/r',
        'agent/quest-1',
        'src/math/clamp.ts'
      )
    );
    Assert.isNull(
      GitHubLifecycleService.ensureIndexExport(
        '/repos/o/r',
        'agent/quest-1',
        'src/strings/slugify.ts'
      ),
      'already exported'
    );
    Assert.isNull(
      GitHubLifecycleService.ensureIndexExport(
        '/repos/o/r',
        'agent/quest-1',
        'tests/x.test.ts'
      )
    );
    Test.stopTest();
  }
}
