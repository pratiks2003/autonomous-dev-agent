/** Agentforce action: Get Open Source Contributions */
public with sharing class McOpenSourceStatus {
  public class Request {
    @InvocableVariable(
      label='Max Items'
      description='How many to list, default 8'
    )
    public Integer maxItems;
  }

  public class Response {
    @InvocableVariable(
      label='Response'
      description='Answer to relay to the user'
    )
    public String response;
  }

  @InvocableMethod(
    label='Get Open Source Contributions'
    description='Lists open-source contributions across public GitHub repos with their status and PR links.'
    category='Mission Control'
  )
  public static List<Response> run(List<Request> requests) {
    List<Response> out = new List<Response>();
    for (Request req : requests) {
      Response r = new Response();
      r.response = MissionControlService.contributions(
        req.maxItems == null ||
          req.maxItems <= 0
          ? 8
          : Math.min(req.maxItems, 25)
      );
      out.add(r);
    }
    return out;
  }
}
