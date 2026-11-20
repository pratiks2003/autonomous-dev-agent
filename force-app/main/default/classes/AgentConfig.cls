/**
 * Typed access to Agent_Config__mdt.Default with safe fallbacks.
 * Tests can inject a config via AgentConfig.testOverride.
 */
public with sharing class AgentConfig {
  @TestVisible
  private static AgentConfig testOverride;
  private static AgentConfig cached;

  public String owner = 'pratiks2003';
  public String repo = 'agent-forge';
  public String profileRepo = 'pratiks2003';
  public String siteUrl = '';
  public String model = 'sfdc_ai__DefaultBedrockAnthropicClaude4Sonnet';
  public Integer minOpenQuests = 3;
  public Integer releaseEveryNRuns = 7;
  public Boolean enabled = true;

  public static AgentConfig get() {
    if (testOverride != null) {
      return testOverride;
    }
    if (cached != null) {
      return cached;
    }
    cached = new AgentConfig();
    Agent_Config__mdt rec = Agent_Config__mdt.getInstance('Default');
    if (rec != null) {
      cached.owner = String.isNotBlank(rec.Owner__c)
        ? rec.Owner__c
        : cached.owner;
      cached.repo = String.isNotBlank(rec.Repo__c) ? rec.Repo__c : cached.repo;
      cached.profileRepo = String.isNotBlank(rec.Profile_Repo__c)
        ? rec.Profile_Repo__c
        : cached.owner;
      cached.siteUrl = String.isNotBlank(rec.Site_Url__c)
        ? rec.Site_Url__c
        : '';
      cached.model = String.isNotBlank(rec.Model__c)
        ? rec.Model__c
        : cached.model;
      cached.minOpenQuests = rec.Min_Open_Quests__c != null
        ? rec.Min_Open_Quests__c.intValue()
        : 3;
      cached.releaseEveryNRuns = rec.Release_Every_N_Runs__c != null &&
        rec.Release_Every_N_Runs__c > 0
        ? rec.Release_Every_N_Runs__c.intValue()
        : 7;
      cached.enabled = rec.Enabled__c;
    }
    return cached;
  }

  public String fullRepo() {
    return owner + '/' + repo;
  }
}
