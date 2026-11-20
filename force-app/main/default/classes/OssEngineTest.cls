@IsTest
private class OssEngineTest {
  private static AgentMockRouter mocks() {
    AgentMockRouter m = new AgentMockRouter();
    Test.setMock(HttpCalloutMock.class, m);
    AgentLLMClient.provider = m;
    return m;
  }

  private static OSS_Contribution__c contribution(String status) {
    OSS_Contribution__c c = new OSS_Contribution__c(
      Repo__c = 'acme/widgets',
      Issue_Number__c = 7,
      Issue_Url__c = 'https://github.com/acme/widgets/issues/7',
      Issue_Title__c = 'Handle empty input in parseDuration',
      Issue_Body__c = 'parseDuration("") throws',
      Language__c = 'TypeScript',
      Stars__c = 500,
      Status__c = status,
      Test_Result__c = 'Pending',
      Review_Verdict__c = 'Pending',
      Attempts__c = 0
    );
    insert c;
    return [
      SELECT
        Id,
        Name,
        Repo__c,
        Issue_Number__c,
        Issue_Url__c,
        Issue_Title__c,
        Issue_Body__c,
        Language__c,
        Stars__c,
        Status__c,
        Fork__c,
        Branch__c,
        Base_Branch__c,
        Base_Sha__c,
        Generated_Json__c,
        Review_Notes__c,
        Attempts__c,
        Last_Step_At__c,
        Test_Result__c,
        Fix_Summary__c,
        Verify_Run_Url__c,
        PR_Number__c,
        PR_Url__c
      FROM OSS_Contribution__c
      WHERE Id = :c.Id
    ];
  }

  @IsTest
  static void scoutVetsRanksAndSelects() {
    mocks();
    Test.startTest();
    List<OSS_Contribution__c> found = OssContributionEngine.scout(
      AgentConfig.get()
    );
    Test.stopTest();
    Assert.areEqual(2, found.size());
    Assert.areEqual('Selected', found[0].Status__c);
    Assert.areEqual('acme/widgets', found[0].Repo__c);
    Assert.areEqual(
      'Discovered',
      found[1].Status__c,
      'runner-up goes on the radar'
    );
    Assert.isFalse(AgentEventLogger.buffer.isEmpty());
  }

  @IsTest
  static void fullStateMachineToPullRequest() {
    OSS_Contribution__c c = contribution('Selected');
    AgentMockRouter m = mocks();
    m.runTitleName = c.Name;
    AgentConfig cfg = AgentConfig.get();
    Test.startTest();
    OssContributionEngine.advance(c, cfg, 0);
    Assert.areEqual('Forked', c.Status__c);
    Assert.areEqual('pratiks2003/widgets', c.Fork__c);
    OssContributionEngine.advance(c, cfg, 0);
    Assert.areEqual('Fix_Ready', c.Status__c);
    Assert.isTrue(c.Generated_Json__c.contains('src/duration.ts'));
    OssContributionEngine.advance(c, cfg, 0);
    Assert.areEqual('Verifying', c.Status__c);
    OssContributionEngine.advance(c, cfg, 0);
    Assert.areEqual('Verified', c.Status__c);
    Assert.areEqual('Passed', c.Test_Result__c);
    OssContributionEngine.advance(c, cfg, 0);
    Assert.areEqual('Review_Passed', c.Status__c);
    OssContributionEngine.advance(c, cfg, 1);
    Assert.areEqual('Review_Passed', c.Status__c, 'pace limit holds the PR');
    OssContributionEngine.advance(c, cfg, 0);
    Test.stopTest();
    Assert.areEqual('PR_Open', c.Status__c);
    Assert.areEqual(7, c.PR_Number__c);
  }

  @IsTest
  static void failedTestsRetryOnceThenAbandon() {
    OSS_Contribution__c c = contribution('Verifying');
    AgentMockRouter m = mocks();
    m.runTitleName = c.Name;
    m.testStep = 'failure';
    Test.startTest();
    OssContributionEngine.advance(c, AgentConfig.get(), 0);
    Assert.areEqual(
      'Forked',
      c.Status__c,
      'first failure goes back to Engineer'
    );
    c.Status__c = 'Verifying';
    OssContributionEngine.advance(c, AgentConfig.get(), 0);
    Test.stopTest();
    Assert.areEqual('Failed', c.Status__c);
  }

  @IsTest
  static void tickTracksPublishesAndPersists() {
    OSS_Contribution__c open = contribution('PR_Open');
    open.PR_Number__c = 3;
    update open;
    mocks();
    Test.startTest();
    OssContributionEngine.tick();
    Test.stopTest();
    Assert.areEqual(
      'Merged',
      [SELECT Status__c FROM OSS_Contribution__c WHERE Id = :open.Id].Status__c
    );
    Assert.isTrue(
      [SELECT COUNT() FROM OSS_Contribution__c] >= 2,
      'nothing in flight -> scout added work'
    );
    Assert.isTrue([SELECT COUNT() FROM Agent_Event__c] > 0);
  }

  @IsTest
  static void heartbeatBriefingAndScheduling() {
    mocks();
    insert new Agent_Event__c(
      Agent__c = 'Maintainer',
      Message__c = 'Shipped clamp',
      Occurred_At__c = Datetime.now(),
      Event_Type__c = 'PR merged'
    );
    Test.startTest();
    System.enqueueJob(new OssHeartbeatJob());
    Test.stopTest();
    DailyBriefingService.write(Datetime.now().addDays(-1));
    AgentEventLogger.flush();
    Assert.areEqual(
      1,
      [
          SELECT COUNT()
          FROM Agent_Event__c
          WHERE
            Event_Type__c = :DailyBriefingService.EVENT_TYPE
            AND Message__c = 'Quiet, productive day'
        ] > 0
        ? 1
        : 0
    );
    Assert.areEqual(2, OssHeartbeat.scheduleAll().size());
    new OssHeartbeat().execute((SchedulableContext) null);
    DailyBriefingService.generateIfDue();
  }

  @IsTest
  static void missionControlActions() {
    mocks();
    insert new Agent_Event__c(
      Agent__c = 'Scout',
      Message__c = 'Picked acme/widgets#7',
      Occurred_At__c = Datetime.now(),
      Event_Type__c = 'Selected issue'
    );
    McGetMissionStatus.Request s = new McGetMissionStatus.Request();
    Assert.isTrue(
      McGetMissionStatus.run(new List<McGetMissionStatus.Request>{ s })[0]
        .response.contains('Streak')
    );
    McRecentActivity.Request a = new McRecentActivity.Request();
    a.hours = 5;
    Assert.isTrue(
      McRecentActivity.run(new List<McRecentActivity.Request>{ a })[0]
        .response.contains('Scout')
    );
    Assert.isTrue(
      McOpenSourceStatus.run(
          new List<McOpenSourceStatus.Request>{
            new McOpenSourceStatus.Request()
          }
        )[0]
        .response.contains('No open-source')
    );
    Assert.isTrue(
      McScoutOpenSource.run(
          new List<McScoutOpenSource.Request>{ new McScoutOpenSource.Request() }
        )[0]
        .response.contains('Scout')
    );
    McContributeToIssue.Request ci = new McContributeToIssue.Request();
    ci.issueUrl = 'https://github.com/acme/widgets/issues/42';
    Assert.isTrue(
      McContributeToIssue.run(new List<McContributeToIssue.Request>{ ci })[0]
        .response.contains('radar')
    );
    Assert.isTrue(
      McContributeToIssue.run(new List<McContributeToIssue.Request>{ ci })[0]
        .response.contains('already')
    );
    ci.issueUrl = 'nope';
    Assert.isTrue(
      McContributeToIssue.run(new List<McContributeToIssue.Request>{ ci })[0]
        .response.contains('URL')
    );
    Assert.isTrue(
      MissionControlService.contributions(5).contains('acme/widgets#42')
    );
    Assert.isTrue(
      McRunDailyMission.run(
          new List<McRunDailyMission.Request>{ new McRunDailyMission.Request() }
        )[0]
        .response.contains('started')
    );
    McQueueQuest.Request q = new McQueueQuest.Request();
    Assert.isTrue(
      McQueueQuest.run(new List<McQueueQuest.Request>{ q })[0]
        .response.contains('title')
    );
  }

  @IsTest
  static void helpers() {
    Assert.isTrue(OssContributionEngine.isSafeContributionPath('src/a.ts'));
    Assert.isFalse(
      OssContributionEngine.isSafeContributionPath('.github/workflows/ci.yml')
    );
    Assert.isFalse(
      OssContributionEngine.isSafeContributionPath('package-lock.json')
    );
    Assert.isFalse(OssContributionEngine.isSafeContributionPath('../x'));
    Assert.isTrue(
      OssContributionEngine.isSourcePath('force-app/main/default/classes/A.cls')
    );
    Assert.isFalse(
      OssContributionEngine.isSourcePath('node_modules/x/index.js')
    );
    Assert.areEqual(
      new List<String>{ 'handle', 'empty', 'input' },
      OssContributionEngine.keywordsFor('Handle empty input in parseDuration')
    );
    mocks();
    Test.startTest();
    Assert.isFalse(OssContributionEngine.rejectsAi('acme/widgets'));
    Test.stopTest();
  }
}
