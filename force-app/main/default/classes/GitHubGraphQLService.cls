/**
 * All GitHub GraphQL reads in as few round-trips as possible:
 *  - fetchRepoContext: open `agent-quest` issues, default branch + head SHA,
 *    a 3-level file tree, README.md and AGENT_GUIDE.md / CONTRIBUTING.md in ONE POST /graphql.
 *  - fetchFiles: RAG retrieval of selected source files in one request.
 *  - fetchContributions: the 4-axis totals + contribution calendar for the dashboard.
 *  - enableAutoMerge: squash auto-merge once required CI checks pass.
 */
public with sharing class GitHubGraphQLService {
  public class GraphQLException extends Exception {
  }

  public class IssueInfo {
    public Integer num;
    public String title;
    public String body;
    public String url;
    public List<String> labels = new List<String>();
  }

  public class RepoContext {
    public String defaultBranch;
    public String headSha;
    public String readme = '';
    public String guide = '';
    public List<String> filePaths = new List<String>();
    public List<IssueInfo> openQuests = new List<IssueInfo>();
  }

  private static final String TREE_FRAGMENT = 'entries { path type object { ... on Tree { entries { path type object { ... on Tree { entries { path type } } } } } } }';

  public static RepoContext fetchRepoContext(String owner, String repo) {
    String query =
      'query($owner:String!,$name:String!){ repository(owner:$owner,name:$name){' +
      ' defaultBranchRef { name target { oid } }' +
      ' issues(first:30, states:OPEN, labels:["agent-quest"], orderBy:{field:CREATED_AT, direction:ASC}) {' +
      '   nodes { number title body url labels(first:10){ nodes { name } } } }' +
      ' readme: object(expression:"HEAD:README.md") { ... on Blob { text } }' +
      ' guide: object(expression:"HEAD:AGENT_GUIDE.md") { ... on Blob { text } }' +
      ' contributing: object(expression:"HEAD:CONTRIBUTING.md") { ... on Blob { text } }' +
      ' tree: object(expression:"HEAD:") { ... on Tree { ' +
      TREE_FRAGMENT +
      ' } }' +
      '} }';
    Map<String, Object> repoData = (Map<String, Object>) run(
        query,
        new Map<String, Object>{ 'owner' => owner, 'name' => repo }
      )
      .get('repository');
    if (repoData == null) {
      throw new GraphQLException(
        'Repository ' + owner + '/' + repo + ' not found or token lacks access.'
      );
    }
    RepoContext ctx = new RepoContext();
    Map<String, Object> ref = (Map<String, Object>) repoData.get(
      'defaultBranchRef'
    );
    ctx.defaultBranch = (String) ref.get('name');
    ctx.headSha = (String) ((Map<String, Object>) ref.get('target')).get('oid');
    ctx.readme = blobText(repoData.get('readme'));
    ctx.guide =
      blobText(repoData.get('guide')) +
      '\n' +
      blobText(repoData.get('contributing'));
    Map<String, Object> tree = (Map<String, Object>) repoData.get('tree');
    if (tree != null) {
      collectPaths((List<Object>) tree.get('entries'), ctx.filePaths);
    }
    for (
      Object n : (List<Object>) ((Map<String, Object>) repoData.get('issues'))
        .get('nodes')
    ) {
      Map<String, Object> node = (Map<String, Object>) n;
      IssueInfo info = new IssueInfo();
      info.num = (Integer) node.get('number');
      info.title = (String) node.get('title');
      info.body = (String) node.get('body');
      info.url = (String) node.get('url');
      for (
        Object l : (List<Object>) ((Map<String, Object>) node.get('labels'))
          .get('nodes')
      ) {
        info.labels.add((String) ((Map<String, Object>) l).get('name'));
      }
      ctx.openQuests.add(info);
    }
    return ctx;
  }

  /** Returns path -> file text for up to 6 paths, in a single request. */
  public static Map<String, String> fetchFiles(
    String owner,
    String repo,
    List<String> paths
  ) {
    Map<String, String> out = new Map<String, String>();
    if (paths == null || paths.isEmpty()) {
      return out;
    }
    String fields = '';
    for (Integer i = 0; i < paths.size() && i < 6; i++) {
      fields +=
        ' f' +
        i +
        ': object(expression:' +
        JSON.serialize('HEAD:' + paths[i]) +
        ') { ... on Blob { text } }';
    }
    Map<String, Object> repoData = (Map<String, Object>) run(
        'query($owner:String!,$name:String!){ repository(owner:$owner,name:$name){' +
          fields +
          ' } }',
        new Map<String, Object>{ 'owner' => owner, 'name' => repo }
      )
      .get('repository');
    for (Integer i = 0; i < paths.size() && i < 6; i++) {
      String text = blobText(repoData.get('f' + i));
      if (String.isNotBlank(text)) {
        out.put(
          paths[i],
          text.length() > 12000 ? text.substring(0, 12000) : text
        );
      }
    }
    return out;
  }

  /** Compact JSON snapshot: {"totals":{commits,prs,issues,reviews,total},"days":[["2026-11-20",3],...]} */
  public static String fetchContributionSnapshot(String login) {
    String query =
      'query($login:String!){ user(login:$login){ contributionsCollection {' +
      ' totalCommitContributions totalIssueContributions totalPullRequestContributions totalPullRequestReviewContributions' +
      ' contributionCalendar { totalContributions weeks { contributionDays { date contributionCount } } } } } }';
    Map<String, Object> user = (Map<String, Object>) run(
        query,
        new Map<String, Object>{ 'login' => login }
      )
      .get('user');
    Map<String, Object> cc = (Map<String, Object>) user.get(
      'contributionsCollection'
    );
    Map<String, Object> cal = (Map<String, Object>) cc.get(
      'contributionCalendar'
    );
    List<Object> days = new List<Object>();
    for (Object w : (List<Object>) cal.get('weeks')) {
      for (
        Object d : (List<Object>) ((Map<String, Object>) w)
          .get('contributionDays')
      ) {
        Map<String, Object> day = (Map<String, Object>) d;
        days.add(
          new List<Object>{ day.get('date'), day.get('contributionCount') }
        );
      }
    }
    return JSON.serialize(
      new Map<String, Object>{
        'totals' => new Map<String, Object>{
          'commits' => cc.get('totalCommitContributions'),
          'prs' => cc.get('totalPullRequestContributions'),
          'issues' => cc.get('totalIssueContributions'),
          'reviews' => cc.get('totalPullRequestReviewContributions'),
          'total' => cal.get('totalContributions'),
          'shipped' => mergedAgentPrs(login)
        },
        'days' => days
      }
    );
  }

  /** Lifetime merged PRs authored by the owner in the agent repo (survives data retention). */
  public static Integer mergedAgentPrs(String login) {
    try {
      String q =
        'is:pr is:merged author:' +
        login +
        ' repo:' +
        AgentConfig.get().fullRepo();
      AgentHttp.Result r = AgentHttp.github(
        'GET',
        '/search/issues?per_page=1&q=' + EncodingUtil.urlEncode(q, 'UTF-8'),
        null
      );
      return r.ok() ? (Integer) r.json().get('total_count') : null;
    } catch (Exception e) {
      return null;
    }
  }

  /** Returns true if auto-merge was enabled; false if GitHub refused (e.g. PR already mergeable/clean). */
  public static Boolean enableAutoMerge(String pullRequestNodeId) {
    try {
      run(
        'mutation($id:ID!){ enablePullRequestAutoMerge(input:{pullRequestId:$id, mergeMethod:SQUASH}) { clientMutationId } }',
        new Map<String, Object>{ 'id' => pullRequestNodeId }
      );
      return true;
    } catch (GraphQLException e) {
      return false;
    }
  }

  public static Map<String, Object> run(
    String query,
    Map<String, Object> variables
  ) {
    AgentHttp.Result res = AgentHttp.require(
      AgentHttp.github(
        'POST',
        '/graphql',
        new Map<String, Object>{ 'query' => query, 'variables' => variables }
      ),
      'GitHub GraphQL'
    );
    Map<String, Object> body = res.json();
    if (body.get('errors') != null) {
      throw new GraphQLException(
        'GraphQL errors: ' +
        AgentHttp.abbreviate(JSON.serialize(body.get('errors')), 500)
      );
    }
    return (Map<String, Object>) body.get('data');
  }

  private static String blobText(Object blobNode) {
    if (blobNode == null) {
      return '';
    }
    Object text = ((Map<String, Object>) blobNode).get('text');
    return text == null ? '' : (String) text;
  }

  private static void collectPaths(List<Object> entries, List<String> out) {
    if (entries == null) {
      return;
    }
    for (Object e : entries) {
      Map<String, Object> entry = (Map<String, Object>) e;
      String path = (String) entry.get('path');
      if (entry.get('type') == 'blob') {
        out.add(path);
      } else if (
        entry.get('type') == 'tree' &&
        !path.startsWith('node_modules') &&
        !path.startsWith('.git/')
      ) {
        Map<String, Object> obj = (Map<String, Object>) entry.get('object');
        if (obj != null) {
          collectPaths((List<Object>) obj.get('entries'), out);
        }
      }
    }
  }
}
