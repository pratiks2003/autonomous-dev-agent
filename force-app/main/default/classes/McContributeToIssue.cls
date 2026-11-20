/** Agentforce action: Contribute To Issue */
public with sharing class McContributeToIssue {
  public class Request {
    @InvocableVariable(
      label='Issue URL'
      description='GitHub issue URL, e.g. https://github.com/owner/repo/issues/123'
      required=true
    )
    public String issueUrl;
  }

  public class Response {
    @InvocableVariable(
      label='Response'
      description='Answer to relay to the user'
    )
    public String response;
  }

  @InvocableMethod(
    label='Contribute To Issue'
    description='Puts a specific public GitHub issue (URL) at the top of the squad radar to fix and open a PR.'
    category='Mission Control'
  )
  public static List<Response> run(List<Request> requests) {
    List<Response> out = new List<Response>();
    for (Request req : requests) {
      Response r = new Response();
      r.response = MissionControlService.contributeTo(req.issueUrl);
      out.add(r);
    }
    return out;
  }
}
