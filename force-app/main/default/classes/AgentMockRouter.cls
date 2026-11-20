/**
 * Test-only HttpCalloutMock that emulates GitHub REST/GraphQL and the Einstein Models API.
 * Flags let tests exercise alternative branches.
 */
@IsTest
public class AgentMockRouter implements HttpCalloutMock, AgentLLMClient.Provider {
  public Boolean autoMergeFails = true;
  public Boolean profileReadmeExists = false;
  public Boolean indexExists = false;
  public Integer llmStatus = 200;
  public List<String> calls = new List<String>();

  public HttpResponse respond(HttpRequest req) {
    String url = req.getEndpoint();
    String method = req.getMethod();
    String body = req.getBody() == null ? '' : req.getBody();
    calls.add(method + ' ' + url);
    HttpResponse res = new HttpResponse();
    res.setHeader('Content-Type', 'application/json');
    res.setStatusCode(200);

    if (url.endsWith('/graphql')) {
      res.setBody(graphql(body));
    } else if (method == 'POST' && url.contains('/git/refs')) {
      res.setStatusCode(201);
      res.setBody('{"ref":"refs/heads/agent/quest-1"}');
    } else if (method == 'GET' && url.contains('/contents/README.md')) {
      if (profileReadmeExists) {
        res.setBody(
          '{"sha":"abc","content":"' +
            EncodingUtil.base64Encode(
              Blob.valueOf(
                '# Me\n<!-- AGENT:START -->old<!-- AGENT:END -->\nfooter'
              )
            ) +
            '"}'
        );
      } else {
        res.setStatusCode(404);
        res.setBody('{"message":"Not Found"}');
      }
    } else if (
      method == 'GET' &&
      url.contains('/contents/src/index.ts') &&
      indexExists
    ) {
      res.setBody(
        '{"sha":"idx","content":"' +
          EncodingUtil.base64Encode(
            Blob.valueOf('export { slugify } from "./strings/slugify";\n')
          ) +
          '"}'
      );
    } else if (method == 'GET' && url.contains('/contents/')) {
      res.setStatusCode(404);
      res.setBody('{"message":"Not Found"}');
    } else if (method == 'PUT' && url.contains('/contents/')) {
      res.setStatusCode(201);
      res.setBody('{"commit":{"sha":"' + 'c'.repeat(40) + '"}}');
    } else if (method == 'GET' && url.contains('/pulls?state=open')) {
      res.setBody('[]');
    } else if (method == 'POST' && url.endsWith('/pulls')) {
      res.setStatusCode(201);
      res.setBody(
        '{"number":7,"html_url":"https://github.com/o/r/pull/7","node_id":"PR_node7"}'
      );
    } else if (url.contains('/reviews')) {
      res.setBody('{"id":1}');
    } else if (method == 'PUT' && url.endsWith('/merge')) {
      res.setBody('{"sha":"' + 'm'.repeat(40) + '","merged":true}');
    } else if (method == 'GET' && url.contains('/pulls/')) {
      res.setBody(
        '{"merged":true,"state":"closed","merge_commit_sha":"' +
          'd'.repeat(40) +
          '","merged_at":"2026-11-19T08:05:00Z"}'
      );
    } else if (method == 'POST' && url.endsWith('/issues')) {
      res.setStatusCode(201);
      res.setBody('{"number":42}');
    } else if (method == 'POST' && url.endsWith('/releases')) {
      res.setStatusCode(201);
      res.setBody('{"id":1}');
    } else {
      res.setBody('{}');
    }
    return res;
  }

  private String graphql(String body) {
    if (body.contains('enablePullRequestAutoMerge')) {
      return autoMergeFails
        ? '{"errors":[{"message":"Pull request is in clean status"}]}'
        : '{"data":{"enablePullRequestAutoMerge":{"clientMutationId":null}}}';
    }
    if (body.contains('contributionsCollection')) {
      return '{"data":{"user":{"contributionsCollection":{"totalCommitContributions":120,"totalIssueContributions":30,' +
        '"totalPullRequestContributions":40,"totalPullRequestReviewContributions":35,"contributionCalendar":{"totalContributions":225,' +
        '"weeks":[{"contributionDays":[{"date":"2026-11-18","contributionCount":2},{"date":"2026-11-19","contributionCount":4},' +
        '{"date":"2026-11-20","contributionCount":0}]}]}}}}}';
    }
    if (body.contains('f0:')) {
      return '{"data":{"repository":{"f0":{"text":"export const slugify = (s: string) => s;"},"f1":null}}}';
    }
    return '{"data":{"repository":{"defaultBranchRef":{"name":"main","target":{"oid":"' +
      'a'.repeat(40) +
      '"}},' +
      '"issues":{"nodes":[{"number":10,"title":"Add chunk utility","body":"Implement chunk","url":"https://github.com/o/r/issues/10",' +
      '"labels":{"nodes":[{"name":"agent-quest"},{"name":"type:unit_test"}]}}]},' +
      '"readme":{"text":"# agent-forge"},"guide":{"text":"Use strict TS"},"contributing":null,' +
      '"tree":{"entries":[{"path":"src","type":"tree","object":{"entries":[{"path":"src/index.ts","type":"blob","object":null},' +
      '{"path":"src/strings","type":"tree","object":{"entries":[{"path":"src/strings/slugify.ts","type":"blob"}]}}]}},' +
      '{"path":"tests","type":"tree","object":{"entries":[{"path":"tests/slugify.test.ts","type":"blob","object":null}]}},' +
      '{"path":"README.md","type":"blob","object":null}]}}}}';
  }

  /** AgentLLMClient.Provider — emulates the Models API (fenced JSON to exercise extraction). */
  public String generate(String modelName, String prompt) {
    if (llmStatus != 200) {
      throw new AgentLLMClient.LlmException('Models API unavailable');
    }
    return 'Here you go:\n```json\n' +
      llm(prompt.contains('Return the quest JSON')) +
      '\n```';
  }

  private String llm(Boolean questGen) {
    Map<String, Object> payload;
    if (questGen) {
      payload = new Map<String, Object>{
        'title' => 'Add debounce helper',
        'body' => '## Task\nImplement debounce',
        'questType' => 'Feature',
        'ragTags' => 'async,timing',
        'priority' => '2'
      };
    } else {
      payload = new Map<String, Object>{
        'filePath' => 'src/async/debounce.ts',
        'fileContent' => 'export function debounce() {}',
        'unitTestPath' => 'tests/debounce.test.ts',
        'unitTestContent' => 'import { it } from "vitest"; it("works", () => {});',
        'commitMessage' => 'feat: add debounce helper',
        'prTitle' => 'feat: add debounce helper',
        'prBody' => '## Summary\nAdds debounce',
        'codeReviewCritique' => '### Complexity\nO(1)',
        'reasoningNotes' => '- Chose closure-based timer'
      };
    }
    return JSON.serialize(payload);
  }
}
