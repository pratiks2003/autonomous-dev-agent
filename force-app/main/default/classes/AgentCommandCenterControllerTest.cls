@IsTest
private class AgentCommandCenterControllerTest {
  @TestSetup
  static void data() {
    String repo = AgentConfig.get().fullRepo();
    Agent_Quest__c shipped = new Agent_Quest__c(
      Title__c = 'Shipped one',
      Status__c = 'Shipped',
      GitHub_Issue_Number__c = 1,
      PR_Number__c = 2,
      Repository_Name__c = repo,
      Shipped_At__c = Datetime.now()
    );
    Agent_Quest__c active = new Agent_Quest__c(
      Title__c = 'Active',
      Status__c = 'Reviewed',
      GitHub_Issue_Number__c = 3,
      Repository_Name__c = repo
    );
    Agent_Quest__c p1 = new Agent_Quest__c(
      Title__c = 'Later',
      Status__c = 'Queued',
      GitHub_Issue_Number__c = 5,
      Priority__c = 4,
      Repository_Name__c = repo
    );
    Agent_Quest__c p2 = new Agent_Quest__c(
      Title__c = 'First',
      Status__c = 'Queued',
      GitHub_Issue_Number__c = 4,
      Priority__c = 1,
      Repository_Name__c = repo
    );
    insert new List<Agent_Quest__c>{ shipped, active, p1, p2 };
    String snap = '{"totals":{"commits":10,"prs":4,"issues":3,"reviews":2,"total":19},"days":[["2026-11-19",1],["2026-11-20",2]]}';
    insert new List<Agent_Run_Log__c>{
      new Agent_Run_Log__c(
        Run_Date__c = Datetime.now(),
        Agent_Status__c = 'Success',
        Agent_Quest__c = shipped.Id,
        Release_Tag__c = 'v1.1.0',
        Contribution_Snapshot__c = snap,
        Streak_Days__c = 2,
        AI_Reasoning_Notes__c = 'why',
        Review_Comment_Summary__c = 'review'
      ),
      new Agent_Run_Log__c(
        Run_Date__c = Datetime.now().addDays(-1),
        Agent_Status__c = 'Failed',
        Error_Detail__c = 'secret detail'
      )
    };
  }

  private static User viewer() {
    User u = new User(
      Alias = 'agview',
      Email = 'agent.viewer@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Viewer',
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1]
      .Id,
      TimeZoneSidKey = 'GMT',
      Username = 'agent.viewer.' + Crypto.getRandomInteger() + '@example.com'
    );
    insert u;
    insert new PermissionSetAssignment(
      AssigneeId = u.Id,
      PermissionSetId = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'Agent_Command_Center_Viewer'
      ]
      .Id
    );
    return u;
  }

  private static void grantAdmin() {
    insert new PermissionSetAssignment(
      AssigneeId = UserInfo.getUserId(),
      PermissionSetId = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'Agent_Command_Admin'
      ]
      .Id
    );
  }

  @IsTest
  static void dashboardAggregatesEverything() {
    AgentCommandCenterController.Dashboard d;
    System.runAs(viewer()) {
      d = AgentCommandCenterController.getDashboard();
    }
    Assert.areEqual(2, d.streak);
    Assert.areEqual(10, d.commits);
    Assert.areEqual(2, d.reviews);
    Assert.areEqual(2, d.days.size());
    Assert.areEqual('v1.1.0', d.latestRelease);
    Assert.areEqual(1, d.shipped.size());
    Assert.areEqual('why', d.shipped[0].reasoning);
    Assert.areEqual(1, d.active.size());
    Assert.areEqual('First', d.planned[0].title, 'planned sorted by priority');
    Assert.areEqual(50, d.successRate);
    Assert.areEqual(1, d.shippedTotal);
    Assert.isFalse(d.isAdmin);
    Assert.isNull(d.runs[1].error, 'non-admins never see error internals');
  }

  @IsTest
  static void adminActions() {
    if (!AgentCommandCenterController.isAdmin()) {
      grantAdmin();
    }
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.isTrue(AgentCommandCenterController.getDashboard().isAdmin);
      Id logId = AgentCommandCenterController.triggerManualRun();
      Assert.isNotNull(logId);
      Id questId = AgentCommandCenterController.enqueueCustomQuest(
        'Add LRU cache',
        'desc',
        'Feature',
        2
      );
      Agent_Quest__c q = [
        SELECT Status__c, Priority__c
        FROM Agent_Quest__c
        WHERE Id = :questId
      ];
      Assert.areEqual('Queued', q.Status__c);
      Assert.areEqual(2, q.Priority__c);
      try {
        AgentCommandCenterController.enqueueCustomQuest('', null, null, null);
        Assert.fail('blank title rejected');
      } catch (AuraHandledException e) {
        Assert.isNotNull(e);
      }
    }
  }

  @IsTest
  static void nonAdminBlocked() {
    System.runAs(viewer()) {
      try {
        AgentCommandCenterController.triggerManualRun();
        Assert.fail('non-admin must be blocked');
      } catch (AuraHandledException e) {
        Assert.isNotNull(e);
      }
    }
  }

  @IsTest
  static void squadFeedOpenSourceAndChat() {
    User v = viewer();
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new List<Agent_Event__c>{
        new Agent_Event__c(
          Agent__c = 'Scout',
          Event_Type__c = 'Selected issue',
          Message__c = 'Picked acme/widgets#7',
          Occurred_At__c = Datetime.now()
        ),
        new Agent_Event__c(
          Agent__c = 'Concierge',
          Event_Type__c = 'Daily Briefing',
          Message__c = 'Big day',
          Public_Detail__c = '- shipped',
          Occurred_At__c = Datetime.now()
        )
      };
      insert new List<OSS_Contribution__c>{
        new OSS_Contribution__c(
          Repo__c = 'acme/widgets',
          Issue_Number__c = 7,
          Issue_Title__c = 'Fix',
          Status__c = 'PR_Open',
          PR_Number__c = 3
        ),
        new OSS_Contribution__c(
          Repo__c = 'foo/bar',
          Issue_Number__c = 1,
          Issue_Title__c = 'Fix2',
          Status__c = 'Forked'
        ),
        new OSS_Contribution__c(
          Repo__c = 'baz/qux',
          Issue_Number__c = 2,
          Issue_Title__c = 'Fix3',
          Status__c = 'Merged'
        )
      };
    }
    AgentCommandCenterController.Dashboard d;
    System.runAs(v) {
      d = AgentCommandCenterController.getDashboard();
    }
    Assert.areEqual('Big day', d.briefingHeadline);
    Assert.areEqual('- shipped', d.briefingBody);
    Assert.areEqual(8, d.squad.size());
    Assert.areEqual(1, d.squad[1].actions24h, 'Scout counted');
    Assert.areEqual(1, d.events.size(), 'briefing excluded from feed');
    Assert.areEqual(1, d.ossOpen);
    Assert.areEqual(1, d.ossInFlight);
    Assert.areEqual(1, d.ossMerged);
    Assert.areEqual(2, d.ossRepos);
    if (!AgentCommandCenterController.isAdmin()) {
      grantAdmin();
    }
    System.runAs(new User(Id = UserInfo.getUserId())) {
      Assert.areEqual(
        'test-session',
        AgentCommandCenterController.askMissionControl('status?', null)
          .sessionId
      );
    }
  }
}
