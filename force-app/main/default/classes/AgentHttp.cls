/**
 * Thin callout helper around the GitHub_API Named Credential.
 * Never logs or returns credential material.
 */
public with sharing class AgentHttp {
  public class AgentCalloutException extends Exception {
  }

  public class Result {
    public Integer status;
    public String body;
    public Map<String, String> headers = new Map<String, String>();
    public Boolean ok() {
      return status >= 200 && status < 300;
    }
    public Map<String, Object> json() {
      if (String.isBlank(body)) {
        return new Map<String, Object>();
      }
      Object parsed = JSON.deserializeUntyped(body);
      return parsed instanceof Map<String, Object>
        ? (Map<String, Object>) parsed
        : new Map<String, Object>{ 'items' => parsed };
    }
    public List<Object> jsonList() {
      Object parsed = JSON.deserializeUntyped(body);
      return parsed instanceof List<Object>
        ? (List<Object>) parsed
        : new List<Object>();
    }
  }

  public static Result github(String method, String path, Object payload) {
    HttpRequest req = new HttpRequest();
    req.setEndpoint('callout:GitHub_API' + path);
    req.setMethod(method);
    req.setTimeout(30000);
    req.setHeader('Accept', 'application/vnd.github+json');
    req.setHeader('X-GitHub-Api-Version', '2022-11-28');
    req.setHeader('User-Agent', 'autonomous-dev-agent');
    if (payload != null) {
      req.setHeader('Content-Type', 'application/json');
      req.setBody(JSON.serialize(payload, true));
    }
    return send(req);
  }

  private static Result send(HttpRequest req) {
    HttpResponse res = new Http().send(req);
    Result r = new Result();
    r.status = res.getStatusCode();
    r.body = res.getBody();
    for (String key : res.getHeaderKeys()) {
      if (key != null) {
        r.headers.put(key.toLowerCase(), res.getHeader(key));
      }
    }
    return r;
  }

  public static Result require(Result r, String what) {
    if (!r.ok()) {
      throw new AgentCalloutException(
        what + ' failed (HTTP ' + r.status + '): ' + abbreviate(r.body, 600)
      );
    }
    return r;
  }

  public static String abbreviate(String s, Integer max) {
    if (s == null) {
      return '';
    }
    return s.length() > max ? s.substring(0, max) + '…' : s;
  }
}
