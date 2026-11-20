/** Agentforce action: Scout Open Source Issues */
public with sharing class McScoutOpenSource {
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
    label='Scout Open Source Issues'
    description='Asks the Scout to search public GitHub repos for good-first issues the squad can fix now.'
    category='Mission Control'
  )
  public static List<Response> run(List<Request> requests) {
    List<Response> out = new List<Response>();
    for (Request req : requests) {
      Response r = new Response();
      r.response = MissionControlService.scoutNow();
      out.add(r);
    }
    return out;
  }
}
