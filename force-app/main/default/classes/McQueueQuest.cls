/** Agentforce action: Queue Quest */
public with sharing class McQueueQuest {
  public class Request {
    @InvocableVariable(
      label='Title'
      description='Short title of the task'
      required=true
    )
    public String title;
    @InvocableVariable(
      label='Details'
      description='Acceptance criteria or extra details'
    )
    public String details;
    @InvocableVariable(
      label='Quest Type'
      description='Feature, Unit_Test, Refactor, Docs or Challenge'
    )
    public String questType;
  }

  public class Response {
    @InvocableVariable(
      label='Response'
      description='Answer to relay to the user'
    )
    public String response;
  }

  @InvocableMethod(
    label='Queue Quest'
    description='Adds a new engineering task for the Maintainer to build in agent-forge, published as a GitHub issue.'
    category='Mission Control'
  )
  public static List<Response> run(List<Request> requests) {
    List<Response> out = new List<Response>();
    for (Request req : requests) {
      Response r = new Response();
      r.response = MissionControlService.queueQuest(
        req.title,
        req.details,
        req.questType
      );
      out.add(r);
    }
    return out;
  }
}
