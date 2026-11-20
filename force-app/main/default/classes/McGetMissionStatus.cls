/** Agentforce action: Get Mission Status */
public with sharing class McGetMissionStatus {
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
    label='Get Mission Status'
    description='Current streak, GitHub activity totals, last daily mission, open-source progress and latest briefing.'
    category='Mission Control'
  )
  public static List<Response> run(List<Request> requests) {
    List<Response> out = new List<Response>();
    for (Request req : requests) {
      Response r = new Response();
      r.response = MissionControlService.status();
      out.add(r);
    }
    return out;
  }
}
