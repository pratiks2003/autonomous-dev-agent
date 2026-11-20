/** Agentforce action: Run Daily Mission Now */
public with sharing class McRunDailyMission {
  public class Request {
    @InvocableVariable(
      label='Context'
      description='Optional extra context from the user'
    )
    public String context;
  }

  public class Response {
    @InvocableVariable(
      label='Response'
      description='Answer to relay to the user'
    )
    public String response;
  }

  @InvocableMethod(
    label='Run Daily Mission Now'
    description='Starts the daily mission immediately: pick or invent a quest, write code and tests, open, review and merge a PR in agent-forge.'
    category='Mission Control'
  )
  public static List<Response> run(List<Request> requests) {
    List<Response> out = new List<Response>();
    for (Request req : requests) {
      Response r = new Response();
      r.response = MissionControlService.runMission();
      out.add(r);
    }
    return out;
  }
}
