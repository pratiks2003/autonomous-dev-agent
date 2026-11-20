/**
 * Serializable state handed from one Queueable stage to the next.
 * Kept deliberately flat so it survives Queueable serialization.
 */
public with sharing class AgentPipelineState {
  public Id runLogId;
  public Id questId;
  public Boolean manual = false;
  public Boolean selfGenerated = false;

  public Integer issueNumber;
  public String issueTitle;
  public String issueBody;
  public String questType;
  public String ragTags;

  public String defaultBranch;
  public String baseSha;
  public String readme;
  public String guide;
  public List<String> filePaths = new List<String>();

  /** Raw JSON produced by AgentRAGCodeEngine. */
  public String generatedJson;

  public List<String> notes = new List<String>();

  public void note(String line) {
    notes.add('[' + Datetime.now().formatGmt('HH:mm:ss') + 'Z] ' + line);
  }

  public Map<String, Object> generated() {
    return String.isBlank(generatedJson)
      ? new Map<String, Object>()
      : (Map<String, Object>) JSON.deserializeUntyped(generatedJson);
  }

  public static String todayKey() {
    return Datetime.now().formatGmt('yyyy-MM-dd');
  }
}
