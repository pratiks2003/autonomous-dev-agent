/** Agentforce action: Get Recent Activity */
public with sharing class McRecentActivity {
  public class Request {
    @InvocableVariable(
      label='Hours'
      description='How many hours back to look, default 24'
    )
    public Integer hours;
  }

  public class Response {
    @InvocableVariable(
      label='Response'
      description='Answer to relay to the user'
    )
    public String response;
  }

  @InvocableMethod(
    label='Get Recent Activity'
    description='Timeline of what each agent did in the last N hours (IST).'
    category='Mission Control'
  )
  public static List<Response> run(List<Request> requests) {
    List<Response> out = new List<Response>();
    for (Request req : requests) {
      Response r = new Response();
      r.response = MissionControlService.activity(req.hours);
      out.add(r);
    }
    return out;
  }
}
