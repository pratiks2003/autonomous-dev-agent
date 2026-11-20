/**
 * Autonomous open-source contributor.
 *
 * Each heartbeat tick (OssHeartbeat, every 30 min) does:
 *   1. Tracker   — refresh every open upstream PR (merged / closed).
 *   2. One step for the oldest in-flight contribution:
 *        Selected      -> Scout picked it        -> fork upstream (Engineer)
 *        Forked        -> branch + RAG + LLM fix -> Fix_Ready (Engineer)
 *        Fix_Ready     -> dispatch oss-verify.yml in agent-forge (Verifier)
 *        Verifying     -> read the run's test result (Verifier)
 *        Verified      -> independent LLM review (Reviewer)
 *        Review_Passed -> open the upstream PR (Publisher, max 1 per 24h)
 *   3. If nothing is in flight: promote a Discovered candidate or scout new issues (Scout).
 *
 * Guardrails: only open, unassigned issues labelled for contributors, in active repos
 * (>= 50 stars, pushed in the last 60 days) whose CONTRIBUTING/README does not reject
 * AI-generated contributions, with no linked open PR; at most one open PR per repo;
 * repos that close one of our PRs unmerged are never contacted again; tests must pass
 * where the project has them; every PR carries a one-line AI-assistance note.
 */
public with sharing class OssContributionEngine {
  public static final String NOTE_TESTED = 'Prepared with AI assistance; tests run locally.';
  public static final String NOTE_UNTESTED = 'Prepared with AI assistance.';
  public static final List<String> LANGUAGES = new List<String>{
    'TypeScript',
    'JavaScript',
    'Python',
    'Apex'
  };
  public static final Integer MIN_STARS = 50;
  public static final Set<String> IN_FLIGHT = new Set<String>{
    'Selected',
    'Forked',
    'Fix_Ready',
    'Verifying',
    'Verified',
    'Review_Passed'
  };
  private static final List<String> AI_BAN_PHRASES = new List<String>{
    'no ai',
    'ai-generated',
    'ai generated',
    'generative ai',
    'llm-generated',
    'chatgpt',
    'copilot-generated',
    'machine-generated',
    'do not use ai',
    'not accept ai'
  };

  public class EngineException extends Exception {
  }

  // ====================================================================== tick

  public static void tick() {
    AgentConfig cfg = AgentConfig.get();
    List<OSS_Contribution__c> open = [
      SELECT
        Id,
        Name,
        Repo__c,
        PR_Number__c,
        PR_Url__c,
        Status__c,
        Issue_Title__c
      FROM OSS_Contribution__c
      WHERE Status__c = 'PR_Open'
      WITH SECURITY_ENFORCED
      ORDER BY Last_Step_At__c ASC
      LIMIT 10
    ];
    List<OSS_Contribution__c> inFlight = [
      SELECT
        Id,
        Name,
        Repo__c,
        Issue_Number__c,
        Issue_Url__c,
        Issue_Title__c,
        Issue_Body__c,
        Language__c,
        Stars__c,
        Status__c,
        Fork__c,
        Branch__c,
        Base_Branch__c,
        Base_Sha__c,
        Generated_Json__c,
        Review_Notes__c,
        Attempts__c,
        Last_Step_At__c,
        Test_Result__c,
        Fix_Summary__c,
        Verify_Run_Url__c
      FROM OSS_Contribution__c
      WHERE Status__c IN :IN_FLIGHT
      WITH SECURITY_ENFORCED
      ORDER BY Last_Step_At__c ASC NULLS FIRST
      LIMIT 1
    ];
    Datetime dayAgo = Datetime.now().addHours(-24);
    Integer openedLastDay = [
      SELECT COUNT()
      FROM OSS_Contribution__c
      WHERE Opened_At__c >= :dayAgo
      WITH SECURITY_ENFORCED
    ];

    List<OSS_Contribution__c> toUpsert = new List<OSS_Contribution__c>();
    track(open);
    toUpsert.addAll(open);

    if (!inFlight.isEmpty()) {
      OSS_Contribution__c c = inFlight[0];
      try {
        advance(c, cfg, openedLastDay);
      } catch (Exception e) {
        c.Status__c = 'Failed';
        c.Skip_Reason__c = AgentHttp.abbreviate(e.getMessage(), 250);
        AgentEventLogger.error(
          'Engineer',
          'Contribution failed',
          c.Repo__c +
            '#' +
            c.Issue_Number__c +
            ' — ' +
            AgentHttp.abbreviate(e.getMessage(), 150),
          e.getStackTraceString()
        );
      }
      c.Last_Step_At__c = Datetime.now();
      toUpsert.add(c);
    } else if (cfg.enabled) {
      toUpsert.addAll(scoutOrPromote(cfg));
    }

    upsert toUpsert;
    AgentEventLogger.flush();
  }

  // ====================================================================== state machine

  @TestVisible
  private static void advance(
    OSS_Contribution__c c,
    AgentConfig cfg,
    Integer openedLastDay
  ) {
    switch on c.Status__c {
      when 'Selected' {
        fork(c, cfg);
      }
      when 'Forked' {
        engineer(c, cfg);
      }
      when 'Fix_Ready' {
        dispatchVerify(c, cfg);
      }
      when 'Verifying' {
        pollVerify(c, cfg);
      }
      when 'Verified' {
        review(c);
      }
      when 'Review_Passed' {
        if (openedLastDay > 0) {
          return; // pace: at most one upstream PR per 24h
        }
        publish(c, cfg);
      }
    }
  }

  // ---------------------------------------------------------------------- Scout

  @TestVisible
  private static List<OSS_Contribution__c> scoutOrPromote(AgentConfig cfg) {
    List<OSS_Contribution__c> out = new List<OSS_Contribution__c>();
    List<OSS_Contribution__c> radar = [
      SELECT
        Id,
        Name,
        Repo__c,
        Issue_Number__c,
        Issue_Title__c,
        Feasibility_Score__c,
        Status__c
      FROM OSS_Contribution__c
      WHERE Status__c = 'Discovered'
      WITH SECURITY_ENFORCED
      ORDER BY Feasibility_Score__c DESC
      LIMIT 1
    ];
    if (!radar.isEmpty()) {
      OSS_Contribution__c next = radar[0];
      Map<String, Object> issue = AgentHttp.github(
          'GET',
          '/repos/' +
            next.Repo__c +
            '/issues/' +
            next.Issue_Number__c.intValue(),
          null
        )
        .json();
      if (issue.get('state') == 'open' && isEmptyList(issue.get('assignees'))) {
        next.Status__c = 'Selected';
        AgentEventLogger.info(
          'Scout',
          'Picked from radar',
          'Promoted ' +
            next.Repo__c +
            '#' +
            next.Issue_Number__c.intValue() +
            ' — ' +
            next.Issue_Title__c,
          null
        );
      } else {
        next.Status__c = 'Skipped';
        next.Skip_Reason__c = 'Issue closed or assigned before we started';
      }
      next.Last_Step_At__c = Datetime.now();
      out.add(next);
      return out;
    }
    return scout(cfg);
  }

  public static List<OSS_Contribution__c> scout(AgentConfig cfg) {
    String language = LANGUAGES[
      Math.mod(Date.today().dayOfYear(), LANGUAGES.size())
    ];
    Set<String> avoid = reposToAvoid();
    String since = Datetime.now().addDays(-90).formatGmt('yyyy-MM-dd');
    String q =
      'label:"good first issue" state:open type:issue no:assignee archived:false comments:<6 language:' +
      language +
      ' created:>' +
      since;
    Map<String, Object> res = AgentHttp.require(
        AgentHttp.github(
          'GET',
          '/search/issues?sort=created&order=desc&per_page=25&q=' +
          EncodingUtil.urlEncode(q, 'UTF-8'),
          null
        ),
        'Issue search'
      )
      .json();
    List<Map<String, Object>> candidates = new List<Map<String, Object>>();
    for (Object o : (List<Object>) res.get('items')) {
      Map<String, Object> item = (Map<String, Object>) o;
      String repo = ((String) item.get('repository_url'))
        .substringAfter('/repos/');
      if (
        avoid.contains(repo.toLowerCase()) ||
        repo.startsWithIgnoreCase(cfg.owner + '/')
      ) {
        continue;
      }
      avoid.add(repo.toLowerCase()); // one candidate per repo
      item.put('_repo', repo);
      candidates.add(item);
      if (candidates.size() >= 6) {
        break;
      }
    }

    List<Map<String, Object>> vetted = new List<Map<String, Object>>();
    for (Map<String, Object> item : candidates) {
      String repo = (String) item.get('_repo');
      AgentHttp.Result repoRes = AgentHttp.github(
        'GET',
        '/repos/' + repo,
        null
      );
      if (!repoRes.ok()) {
        continue;
      }
      Map<String, Object> meta = repoRes.json();
      Integer stars = (Integer) meta.get('stargazers_count');
      Datetime pushed = GitHubLifecycleService.parseGitHubDate(
        (String) meta.get('pushed_at')
      );
      if (
        stars < MIN_STARS ||
        meta.get('archived') == true ||
        pushed < Datetime.now().addDays(-60)
      ) {
        continue;
      }
      if (
        rejectsAi(repo) || hasLinkedOpenPr(repo, (Integer) item.get('number'))
      ) {
        continue;
      }
      item.put('_stars', stars);
      item.put('_default_branch', meta.get('default_branch'));
      vetted.add(item);
    }
    if (vetted.isEmpty()) {
      AgentEventLogger.info(
        'Scout',
        'Scan complete',
        'Scanned ' + language + ' issues — nothing met the bar today.',
        null
      );
      return new List<OSS_Contribution__c>();
    }

    String listing = '';
    for (Integer i = 0; i < vetted.size(); i++) {
      Map<String, Object> v = vetted[i];
      listing +=
        '\n[' +
        i +
        '] ' +
        v.get('_repo') +
        ' (★' +
        v.get('_stars') +
        ') #' +
        v.get('number') +
        ': ' +
        v.get('title') +
        '\n' +
        AgentHttp.abbreviate((String) v.get('body'), 700) +
        '\n';
    }
    Map<String, Object> triage = AgentLLMClient.createJson(
      'You are the Scout of an autonomous engineering team that contributes small, high-quality fixes to open-source projects. ' +
        'Rate each issue 0-10 for how confidently a careful engineer could resolve it in ONE pull request touching at most 3 files, ' +
        'with a clear expected behaviour and something testable. Penalise vague, design-heavy, UI-screenshot, infra, or multi-repo issues.',
      'Language focus: ' +
        language +
        '\nCandidates:' +
        listing +
        '\n\nReturn "ranking" as a JSON array of objects {"index": number, "score": number, "reason": string}, best first.',
      new List<String>{ 'ranking' }
    );

    List<OSS_Contribution__c> out = new List<OSS_Contribution__c>();
    Boolean selected = false;
    for (Object o : (List<Object>) triage.get('ranking')) {
      Map<String, Object> r = (Map<String, Object>) o;
      Integer idx = Integer.valueOf(String.valueOf(r.get('index')));
      Integer score = Integer.valueOf(String.valueOf(r.get('score')));
      if (idx < 0 || idx >= vetted.size() || score < 6 || out.size() >= 4) {
        continue;
      }
      Map<String, Object> v = vetted[idx];
      OSS_Contribution__c c = new OSS_Contribution__c(
        Repo__c = (String) v.get('_repo'),
        Issue_Number__c = (Integer) v.get('number'),
        Issue_Url__c = (String) v.get('html_url'),
        Issue_Title__c = AgentHttp.abbreviate((String) v.get('title'), 250),
        Issue_Body__c = AgentHttp.abbreviate((String) v.get('body'), 32000),
        Language__c = language,
        Stars__c = (Integer) v.get('_stars'),
        Base_Branch__c = (String) v.get('_default_branch'),
        Feasibility_Score__c = score,
        Status__c = selected ? 'Discovered' : 'Selected',
        Test_Result__c = 'Pending',
        Review_Verdict__c = 'Pending',
        Attempts__c = 0,
        Fix_Summary__c = (String) r.get('reason'),
        Last_Step_At__c = Datetime.now()
      );
      out.add(c);
      AgentEventLogger.info(
        'Scout',
        selected ? 'Added to radar' : 'Selected issue',
        (selected ? 'Radar: ' : 'Picked ') +
          c.Repo__c +
          '#' +
          c.Issue_Number__c +
          ' (★' +
          c.Stars__c +
          ', score ' +
          score +
          '/10) — ' +
          c.Issue_Title__c,
        c.Issue_Url__c
      );
      selected = true;
    }
    if (out.isEmpty()) {
      AgentEventLogger.info(
        'Scout',
        'Scan complete',
        'Reviewed ' +
          vetted.size() +
          ' ' +
          language +
          ' issues — none scored high enough.',
        null
      );
    }
    return out;
  }

  @TestVisible
  private static Boolean rejectsAi(String repo) {
    String text = '';
    for (
      String path : new List<String>{
        'CONTRIBUTING.md',
        '.github/CONTRIBUTING.md'
      }
    ) {
      AgentHttp.Result r = AgentHttp.github(
        'GET',
        '/repos/' + repo + '/contents/' + path,
        null
      );
      if (r.ok() && r.json().get('content') != null) {
        text += decode((String) r.json().get('content')).toLowerCase();
        break;
      }
    }
    for (String phrase : AI_BAN_PHRASES) {
      if (text.contains(phrase)) {
        return true;
      }
    }
    return false;
  }

  private static Boolean hasLinkedOpenPr(String repo, Integer issueNumber) {
    try {
      Map<String, Object> data = GitHubGraphQLService.run(
        'query($o:String!,$n:String!,$i:Int!){ repository(owner:$o,name:$n){ issue(number:$i){ ' +
          'timelineItems(itemTypes:[CROSS_REFERENCED_EVENT, CONNECTED_EVENT], last:25){ nodes{ __typename ' +
          '... on CrossReferencedEvent { source { ... on PullRequest { state } } } } } } } }',
        new Map<String, Object>{
          'o' => repo.substringBefore('/'),
          'n' => repo.substringAfter('/'),
          'i' => issueNumber
        }
      );
      String raw = JSON.serialize(data);
      return raw.contains('"ConnectedEvent"') || raw.contains('"state":"OPEN"');
    } catch (Exception e) {
      return true; // when unsure, stay away
    }
  }

  private static Set<String> reposToAvoid() {
    Set<String> out = new Set<String>();
    Datetime monthAgo = Datetime.now().addDays(-30);
    for (OSS_Contribution__c c : [
      SELECT Repo__c, Status__c, CreatedDate
      FROM OSS_Contribution__c
      WHERE
        Status__c = 'Closed'
        OR CreatedDate >= :monthAgo
        OR Status__c IN :IN_FLIGHT
        OR Status__c = 'PR_Open'
      WITH SECURITY_ENFORCED
      LIMIT 500
    ]) {
      out.add(c.Repo__c.toLowerCase());
    }
    return out;
  }

  // ---------------------------------------------------------------------- Engineer

  @TestVisible
  private static void fork(OSS_Contribution__c c, AgentConfig cfg) {
    Map<String, Object> meta = AgentHttp.require(
        AgentHttp.github('GET', '/repos/' + c.Repo__c, null),
        'Read upstream'
      )
      .json();
    c.Base_Branch__c = (String) meta.get('default_branch');
    Map<String, Object> ref = AgentHttp.require(
        AgentHttp.github(
          'GET',
          '/repos/' + c.Repo__c + '/git/ref/heads/' + c.Base_Branch__c,
          null
        ),
        'Read upstream head'
      )
      .json();
    c.Base_Sha__c = (String) ((Map<String, Object>) ref.get('object'))
      .get('sha');
    Map<String, Object> f = AgentHttp.require(
        AgentHttp.github(
          'POST',
          '/repos/' + c.Repo__c + '/forks',
          new Map<String, Object>{ 'default_branch_only' => true }
        ),
        'Fork'
      )
      .json();
    c.Fork__c = (String) f.get('full_name');
    c.Branch__c = 'fix/issue-' + c.Issue_Number__c.intValue();
    c.Status__c = 'Forked';
    AgentEventLogger.info(
      'Engineer',
      'Forked repo',
      'Forked ' + c.Repo__c + ' → ' + c.Fork__c,
      'https://github.com/' + c.Fork__c
    );
  }

  @TestVisible
  private static void engineer(OSS_Contribution__c c, AgentConfig cfg) {
    // fresh fork may still be provisioning: try to sync and branch, otherwise wait for next tick
    AgentHttp.github(
      'POST',
      '/repos/' + c.Fork__c + '/merge-upstream',
      new Map<String, Object>{ 'branch' => c.Base_Branch__c }
    );
    AgentHttp.Result br = AgentHttp.github(
      'POST',
      '/repos/' + c.Fork__c + '/git/refs',
      new Map<String, Object>{
        'ref' => 'refs/heads/' + c.Branch__c,
        'sha' => c.Base_Sha__c
      }
    );
    if (!br.ok() && br.status != 422) {
      if (br.status == 404 || br.status == 409) {
        return; // fork not ready yet
      }
      AgentHttp.require(br, 'Create branch');
    }

    // ---- retrieval: repo tree + code search + keyword ranking
    Map<String, Object> tree = AgentHttp.require(
        AgentHttp.github(
          'GET',
          '/repos/' +
            c.Repo__c +
            '/git/trees/' +
            c.Base_Sha__c +
            '?recursive=1',
          null
        ),
        'Read tree'
      )
      .json();
    List<String> paths = new List<String>();
    for (Object o : (List<Object>) tree.get('tree')) {
      Map<String, Object> t = (Map<String, Object>) o;
      String p = (String) t.get('path');
      if (t.get('type') == 'blob' && isSourcePath(p)) {
        paths.add(p);
      }
    }
    List<String> keywords = keywordsFor(
      c.Issue_Title__c + ' ' + AgentHttp.abbreviate(c.Issue_Body__c, 400)
    );
    List<String> picked = new List<String>();
    if (!keywords.isEmpty()) {
      String q = String.join(keywords, ' ') + ' repo:' + c.Repo__c;
      AgentHttp.Result search = AgentHttp.github(
        'GET',
        '/search/code?per_page=8&q=' + EncodingUtil.urlEncode(q, 'UTF-8'),
        null
      );
      if (search.ok()) {
        for (Object o : (List<Object>) search.json().get('items')) {
          String p = (String) ((Map<String, Object>) o).get('path');
          if (isSourcePath(p) && !picked.contains(p) && picked.size() < 4) {
            picked.add(p);
          }
        }
      }
    }
    for (String p : rankPaths(paths, keywords)) {
      if (picked.size() >= 5) {
        break;
      }
      if (!picked.contains(p)) {
        picked.add(p);
      }
    }
    String context = '';
    Map<String, String> originals = new Map<String, String>();
    for (String p : picked) {
      String text = readFile(c.Repo__c, p, c.Base_Sha__c);
      if (text != null) {
        originals.put(p, text);
        context +=
          '\n### ' +
          p +
          '\n```\n' +
          AgentHttp.abbreviate(text, 14000) +
          '\n```\n';
      }
    }
    String guide = AgentHttp.abbreviate(
      readFile(c.Repo__c, 'CONTRIBUTING.md', c.Base_Sha__c),
      2500
    );

    Map<String, Object> out = AgentLLMClient.createJson(
      'You are a senior ' +
        c.Language__c +
        ' engineer contributing to an open-source project you do not own. ' +
        'Resolve the issue with the smallest correct change, matching the project style exactly. Touch at most 3 existing or new files. ' +
        'Add or update a test when the project has tests. Never modify CI, lockfiles, licenses, or unrelated code. ' +
        'Return COMPLETE file contents for every file you change. Write the PR like a thoughtful human contributor: concise, specific, no hype.',
      '## Issue #' +
        c.Issue_Number__c.intValue() +
        ' in ' +
        c.Repo__c +
        ': ' +
        c.Issue_Title__c +
        '\n\n' +
        AgentHttp.abbreviate(c.Issue_Body__c, 5000) +
        (String.isNotBlank(c.Review_Notes__c)
          ? '\n\n## Reviewer feedback on your previous attempt (address it)\n' +
            c.Review_Notes__c
          : '') +
        '\n\n## CONTRIBUTING (excerpt)\n' +
        guide +
        '\n\n## Repository files (subset)\n' +
        AgentHttp.abbreviate(String.join(paths, '\n'), 5000) +
        '\n\n## Relevant code\n' +
        context +
        '\n\nReturn: "files" as a JSON array of {"path": string, "content": string}; "summary" (2-4 sentences); ' +
        '"prTitle" (conventional, <= 72 chars); "prBody" (markdown: what/why/how tested, no AI mention); "commitMessage".',
      new List<String>{
        'files',
        'summary',
        'prTitle',
        'prBody',
        'commitMessage'
      }
    );
    List<Object> files = (List<Object>) out.get('files');
    if (files == null || files.isEmpty() || files.size() > 3) {
      throw new EngineException(
        'Engineer produced ' +
          (files == null ? 0 : files.size()) +
          ' files (expected 1-3).'
      );
    }
    for (Object o : files) {
      Map<String, Object> f = (Map<String, Object>) o;
      String p = (String) f.get('path');
      if (
        !isSafeContributionPath(p) || String.isBlank((String) f.get('content'))
      ) {
        throw new EngineException('Unsafe or empty file in change: ' + p);
      }
    }
    for (Object o : files) {
      Map<String, Object> f = (Map<String, Object>) o;
      GitHubLifecycleService.putFile(
        '/repos/' + c.Fork__c,
        c.Branch__c,
        (String) f.get('path'),
        (String) f.get('content'),
        (String) out.get('commitMessage')
      );
    }
    Map<String, Object> stored = new Map<String, Object>{
      'files' => files,
      'originals' => originals,
      'prTitle' => out.get('prTitle'),
      'prBody' => out.get('prBody')
    };
    c.Generated_Json__c = AgentHttp.abbreviate(JSON.serialize(stored), 130000);
    c.Fix_Summary__c = (String) out.get('summary');
    c.Status__c = 'Fix_Ready';
    AgentEventLogger.info(
      'Engineer',
      'Fix committed',
      'Wrote a ' +
        files.size() +
        '-file fix for ' +
        c.Repo__c +
        '#' +
        c.Issue_Number__c.intValue() +
        ': ' +
        AgentHttp.abbreviate(c.Fix_Summary__c, 140),
      'https://github.com/' + c.Fork__c + '/tree/' + c.Branch__c
    );
  }

  // ---------------------------------------------------------------------- Verifier

  @TestVisible
  private static void dispatchVerify(OSS_Contribution__c c, AgentConfig cfg) {
    AgentHttp.require(
      AgentHttp.github(
        'POST',
        '/repos/' +
          cfg.fullRepo() +
          '/actions/workflows/oss-verify.yml/dispatches',
        new Map<String, Object>{
          'ref' => 'main',
          'inputs' => new Map<String, Object>{
            'fork' => c.Fork__c,
            'branch' => c.Branch__c,
            'contribution' => c.Name,
            'language' => c.Language__c
          }
        }
      ),
      'Dispatch verifier'
    );
    c.Status__c = 'Verifying';
    c.Test_Result__c = 'Pending';
    AgentEventLogger.info(
      'Verifier',
      'Tests started',
      'Running the project\'s own test suite for ' +
        c.Repo__c +
        '#' +
        c.Issue_Number__c.intValue(),
      null
    );
  }

  @TestVisible
  private static void pollVerify(OSS_Contribution__c c, AgentConfig cfg) {
    Map<String, Object> runs = AgentHttp.require(
        AgentHttp.github(
          'GET',
          '/repos/' +
            cfg.fullRepo() +
            '/actions/workflows/oss-verify.yml/runs?event=workflow_dispatch&per_page=30',
          null
        ),
        'List verifier runs'
      )
      .json();
    Map<String, Object> run;
    for (Object o : (List<Object>) runs.get('workflow_runs')) {
      Map<String, Object> r = (Map<String, Object>) o;
      if (String.valueOf(r.get('display_title')).contains(c.Name + ' ')) {
        run = r;
        break;
      }
    }
    if (run == null || run.get('status') != 'completed') {
      if (
        c.Last_Step_At__c != null &&
        c.Last_Step_At__c < Datetime.now().addHours(-3)
      ) {
        c.Status__c = 'Failed';
        c.Skip_Reason__c = 'Verifier did not finish within 3 hours';
      }
      return;
    }
    c.Verify_Run_Url__c = (String) run.get('html_url');
    Map<String, Object> jobs = AgentHttp.require(
        AgentHttp.github(
          'GET',
          ((String) run.get('jobs_url')).substringAfter('api.github.com'),
          null
        ),
        'Read verifier jobs'
      )
      .json();
    String tests = 'skipped';
    String staticCheck = 'skipped';
    for (Object jo : (List<Object>) jobs.get('jobs')) {
      for (Object so : (List<Object>) ((Map<String, Object>) jo).get('steps')) {
        Map<String, Object> step = (Map<String, Object>) so;
        if (step.get('name') == 'Run tests') {
          tests = String.valueOf(step.get('conclusion'));
        } else if (step.get('name') == 'Static check') {
          staticCheck = String.valueOf(step.get('conclusion'));
        }
      }
    }
    if (tests == 'success') {
      c.Test_Result__c = 'Passed';
    } else if (
      tests == 'failure' ||
      staticCheck == 'failure' ||
      run.get('conclusion') == 'failure'
    ) {
      c.Test_Result__c = 'Failed';
    } else if (staticCheck == 'success') {
      c.Test_Result__c = 'Static_Only';
    } else {
      c.Test_Result__c = 'No_Tests';
    }
    if (c.Test_Result__c == 'Failed') {
      if (c.Attempts__c == null || c.Attempts__c < 1) {
        c.Attempts__c = (c.Attempts__c == null ? 0 : c.Attempts__c) + 1;
        c.Review_Notes__c =
          'The project test suite FAILED on your change (' +
          c.Verify_Run_Url__c +
          '). Re-check edge cases, imports and existing tests; keep the change minimal.';
        c.Status__c = 'Forked';
        AgentEventLogger.warn(
          'Verifier',
          'Tests failed',
          'Tests failed for ' +
            c.Repo__c +
            '#' +
            c.Issue_Number__c.intValue() +
            ' — sending back to Engineer for one retry.',
          c.Verify_Run_Url__c
        );
      } else {
        c.Status__c = 'Failed';
        c.Skip_Reason__c = 'Project tests failed twice';
        AgentEventLogger.warn(
          'Verifier',
          'Abandoned',
          'Tests failed twice for ' +
            c.Repo__c +
            '#' +
            c.Issue_Number__c.intValue() +
            ' — no PR will be opened.',
          c.Verify_Run_Url__c
        );
      }
      return;
    }
    c.Status__c = 'Verified';
    AgentEventLogger.success(
      'Verifier',
      'Verification passed',
      c.Repo__c +
        '#' +
        c.Issue_Number__c.intValue() +
        ' — ' +
        c.Test_Result__c.replace('_', ' ').toLowerCase(),
      c.Verify_Run_Url__c
    );
  }

  // ---------------------------------------------------------------------- Reviewer

  @TestVisible
  private static void review(OSS_Contribution__c c) {
    Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(
      c.Generated_Json__c
    );
    Map<String, Object> originals = (Map<String, Object>) stored.get(
      'originals'
    );
    String diffView = '';
    for (Object o : (List<Object>) stored.get('files')) {
      Map<String, Object> f = (Map<String, Object>) o;
      String p = (String) f.get('path');
      diffView +=
        '\n### ' +
        p +
        '\n--- BEFORE\n' +
        AgentHttp.abbreviate((String) originals.get(p), 6000) +
        '\n--- AFTER\n' +
        AgentHttp.abbreviate((String) f.get('content'), 6000) +
        '\n';
    }
    Map<String, Object> verdict = AgentLLMClient.createJson(
      'You are an exacting open-source maintainer reviewing a pull request from a new contributor. Approve only if the change ' +
        'clearly resolves the issue, is minimal, follows the project style, does not break behaviour, and includes or updates tests ' +
        'when the project has tests. Reject anything that rewrites unrelated code or guesses at behaviour.',
      '## Issue: ' +
        c.Issue_Title__c +
        '\n' +
        AgentHttp.abbreviate(c.Issue_Body__c, 3000) +
        '\n\n## Test result: ' +
        c.Test_Result__c +
        '\n\n## Proposed change' +
        diffView +
        '\n\nReturn "verdict" (one of Approve, Revise, Reject) and "notes" (markdown review).',
      new List<String>{ 'verdict', 'notes' }
    );
    String v = String.valueOf(verdict.get('verdict')).trim();
    c.Review_Notes__c = AgentHttp.abbreviate(
      String.valueOf(verdict.get('notes')),
      32000
    );
    if (v.equalsIgnoreCase('Approve')) {
      c.Review_Verdict__c = 'Approve';
      c.Status__c = 'Review_Passed';
      AgentEventLogger.success(
        'Reviewer',
        'Approved',
        'Approved the fix for ' +
          c.Repo__c +
          '#' +
          c.Issue_Number__c.intValue(),
        null
      );
    } else if (
      v.equalsIgnoreCase('Revise') &&
      (c.Attempts__c == null ||
      c.Attempts__c < 1)
    ) {
      c.Review_Verdict__c = 'Revise';
      c.Attempts__c = (c.Attempts__c == null ? 0 : c.Attempts__c) + 1;
      c.Status__c = 'Forked';
      AgentEventLogger.warn(
        'Reviewer',
        'Changes requested',
        'Sent ' +
          c.Repo__c +
          '#' +
          c.Issue_Number__c.intValue() +
          ' back to Engineer with review notes.',
        c.Review_Notes__c
      );
    } else {
      c.Review_Verdict__c = 'Reject';
      c.Status__c = 'Skipped';
      c.Skip_Reason__c = 'Reviewer rejected the change';
      AgentEventLogger.warn(
        'Reviewer',
        'Rejected',
        'Rejected the fix for ' +
          c.Repo__c +
          '#' +
          c.Issue_Number__c.intValue() +
          ' — not good enough to send.',
        c.Review_Notes__c
      );
    }
  }

  // ---------------------------------------------------------------------- Publisher

  @TestVisible
  private static void publish(OSS_Contribution__c c, AgentConfig cfg) {
    Map<String, Object> issue = AgentHttp.require(
        AgentHttp.github(
          'GET',
          '/repos/' + c.Repo__c + '/issues/' + c.Issue_Number__c.intValue(),
          null
        ),
        'Re-check issue'
      )
      .json();
    if (issue.get('state') != 'open' || !isEmptyList(issue.get('assignees'))) {
      c.Status__c = 'Skipped';
      c.Skip_Reason__c = 'Issue was closed or assigned while we worked';
      AgentEventLogger.info(
        'Publisher',
        'Stood down',
        c.Repo__c +
          '#' +
          c.Issue_Number__c.intValue() +
          ' was taken by someone else — no PR sent.',
        c.Issue_Url__c
      );
      return;
    }
    Map<String, Object> stored = (Map<String, Object>) JSON.deserializeUntyped(
      c.Generated_Json__c
    );
    String note = c.Test_Result__c == 'Passed' ? NOTE_TESTED : NOTE_UNTESTED;
    String body =
      String.valueOf(stored.get('prBody')) +
      '\n\nFixes #' +
      c.Issue_Number__c.intValue() +
      '\n\n' +
      note;
    Map<String, Object> pr = AgentHttp.require(
        AgentHttp.github(
          'POST',
          '/repos/' + c.Repo__c + '/pulls',
          new Map<String, Object>{
            'title' => AgentHttp.abbreviate(
              String.valueOf(stored.get('prTitle')),
              120
            ),
            'head' => cfg.owner +
            ':' +
            c.Branch__c,
            'base' => c.Base_Branch__c,
            'body' => body,
            'maintainer_can_modify' => true
          }
        ),
        'Open upstream PR'
      )
      .json();
    c.PR_Number__c = (Integer) pr.get('number');
    c.PR_Url__c = (String) pr.get('html_url');
    c.Opened_At__c = Datetime.now();
    c.Status__c = 'PR_Open';
    AgentEventLogger.success(
      'Publisher',
      'PR opened',
      'Opened PR #' +
        c.PR_Number__c.intValue() +
        ' on ' +
        c.Repo__c +
        ' — ' +
        stored.get('prTitle'),
      c.PR_Url__c
    );
  }

  // ---------------------------------------------------------------------- Tracker

  @TestVisible
  private static void track(List<OSS_Contribution__c> open) {
    for (OSS_Contribution__c c : open) {
      AgentHttp.Result r = AgentHttp.github(
        'GET',
        '/repos/' + c.Repo__c + '/pulls/' + c.PR_Number__c.intValue(),
        null
      );
      if (!r.ok()) {
        continue;
      }
      Map<String, Object> pr = r.json();
      if (pr.get('merged') == true) {
        c.Status__c = 'Merged';
        AgentEventLogger.success(
          'Publisher',
          'PR merged',
          '🎉 ' +
            c.Repo__c +
            ' merged PR #' +
            c.PR_Number__c.intValue() +
            ' — ' +
            c.Issue_Title__c,
          c.PR_Url__c
        );
      } else if (pr.get('state') == 'closed') {
        c.Status__c = 'Closed';
        AgentEventLogger.warn(
          'Publisher',
          'PR closed',
          c.Repo__c +
            ' closed PR #' +
            c.PR_Number__c.intValue() +
            ' without merging — repo added to blocklist.',
          c.PR_Url__c
        );
      }
      c.Last_Step_At__c = Datetime.now();
    }
  }

  // ---------------------------------------------------------------------- helpers

  @TestVisible
  private static Boolean isSourcePath(String p) {
    String l = p.toLowerCase();
    if (
      l.contains('node_modules/') ||
      l.contains('/dist/') ||
      l.startsWith('dist/') ||
      l.contains('vendor/') ||
      l.contains('.min.')
    ) {
      return false;
    }
    for (
      String ext : new List<String>{
        '.ts',
        '.tsx',
        '.js',
        '.jsx',
        '.mjs',
        '.py',
        '.cls',
        '.trigger',
        '.md'
      }
    ) {
      if (l.endsWith(ext)) {
        return true;
      }
    }
    return false;
  }

  @TestVisible
  private static Boolean isSafeContributionPath(String p) {
    if (
      String.isBlank(p) ||
      p.contains('..') ||
      p.startsWith('/') ||
      p.startsWith('.github/')
    ) {
      return false;
    }
    String l = p.toLowerCase();
    for (
      String banned : new List<String>{
        'package-lock.json',
        'yarn.lock',
        'pnpm-lock.yaml',
        'poetry.lock',
        'license'
      }
    ) {
      if (l.endsWith(banned)) {
        return false;
      }
    }
    return Pattern.matches('[A-Za-z0-9_./@-]+', p);
  }

  @TestVisible
  private static List<String> keywordsFor(String text) {
    Set<String> stop = new Set<String>{
      'the',
      'and',
      'for',
      'with',
      'that',
      'this',
      'when',
      'from',
      'should',
      'would',
      'into',
      'issue',
      'error',
      'add',
      'support',
      'not',
      'are',
      'but',
      'have',
      'use',
      'using',
      'can',
      'fix',
      'bug',
      'feature',
      'request',
      'there'
    };
    List<String> out = new List<String>();
    for (
      String w : (text == null ? '' : text.toLowerCase()).split('[^a-z0-9_]+')
    ) {
      if (w.length() >= 4 && !stop.contains(w) && !out.contains(w)) {
        out.add(w);
      }
      if (out.size() >= 3) {
        break;
      }
    }
    return out;
  }

  private static List<String> rankPaths(
    List<String> paths,
    List<String> keywords
  ) {
    List<String> scored = new List<String>();
    for (String p : paths) {
      Integer s = 0;
      for (String k : keywords) {
        if (p.toLowerCase().contains(k)) {
          s++;
        }
      }
      if (s > 0) {
        scored.add(String.valueOf(9 - Math.min(s, 9)) + '|' + p);
      }
    }
    scored.sort();
    List<String> out = new List<String>();
    for (String s : scored) {
      out.add(s.substringAfter('|'));
    }
    return out;
  }

  private static String readFile(String repo, String path, String ref) {
    AgentHttp.Result r = AgentHttp.github(
      'GET',
      '/repos/' + repo + '/contents/' + path + '?ref=' + ref,
      null
    );
    if (!r.ok() || r.json().get('content') == null) {
      return null;
    }
    return decode((String) r.json().get('content'));
  }

  private static String decode(String b64) {
    return EncodingUtil.base64Decode(b64.replaceAll('\\s', '')).toString();
  }

  private static Boolean isEmptyList(Object o) {
    return o == null ||
      (o instanceof List<Object> && ((List<Object>) o).isEmpty());
  }
}
