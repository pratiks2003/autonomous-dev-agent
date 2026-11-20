/**
 * Retrieval-augmented code generation.
 * 1. selectContextFiles: ranks repository paths against the quest (title + RAG tags)
 *    and always includes an existing test + tsconfig as style exemplars.
 * 2. generate: prompts Claude with the quest + retrieved code and returns strict JSON:
 *    filePath, fileContent, unitTestPath, unitTestContent, commitMessage, prTitle,
 *    prBody, codeReviewCritique, reasoningNotes.
 * 3. validate: rejects any path outside src/ and tests/ (no CI/config tampering).
 */
public with sharing class AgentRAGCodeEngine {
  public class InvalidGenerationException extends Exception {
  }

  public static final List<String> OUTPUT_FIELDS = new List<String>{
    'filePath',
    'fileContent',
    'unitTestPath',
    'unitTestContent',
    'commitMessage',
    'prTitle',
    'prBody',
    'codeReviewCritique',
    'reasoningNotes'
  };

  private static final String SYSTEM_PROMPT =
    'You are a senior TypeScript engineer working autonomously on a public utility library. ' +
    'Implement the GitHub issue you are given as ONE implementation file under src/ and ONE Vitest test file under tests/. ' +
    'Match the conventions of the retrieved files exactly (module style, naming, JSDoc, strict TypeScript, ESM imports with .js-less paths as used in the repo). ' +
    'The code must compile under `tsc --noEmit` with strict mode and every test must pass with `vitest run`. ' +
    'Keep the change focused: implementation under 150 lines, tests under 120 lines. No external dependencies. ' +
    'If you modify an existing file, return its COMPLETE new content. ' +
    'The test file MUST import from the implementation file directly (e.g. ../src/math/clamp), never from ../src/index — the pipeline updates src/index.ts itself. ' +
    'commitMessage must be a Conventional Commit (feat:, test:, refactor:, docs:, fix:). ' +
    'prBody: markdown with Summary, Changes, Testing sections. ' +
    'codeReviewCritique: an honest senior-reviewer critique of your own diff in markdown covering Complexity (Big-O), ' +
    'Edge cases, Security, and Suggested follow-ups. reasoningNotes: 3-6 bullet points on the design decisions.';

  public static List<String> selectContextFiles(AgentPipelineState state) {
    Set<String> tokens = new Set<String>();
    String haystack = ((state.issueTitle == null ? '' : state.issueTitle) +
      ' ' +
      (state.ragTags == null ? '' : state.ragTags))
      .toLowerCase();
    for (String t : haystack.split('[^a-z0-9]+')) {
      if (t.length() >= 3) {
        tokens.add(t);
      }
    }
    List<String> picked = new List<String>();
    String bestTest;
    Map<String, Integer> scores = new Map<String, Integer>();
    for (String path : state.filePaths) {
      String lower = path.toLowerCase();
      if (!(lower.endsWith('.ts') || lower.endsWith('.md'))) {
        continue;
      }
      Integer score = 0;
      for (String t : tokens) {
        if (lower.contains(t)) {
          score += 3;
        }
      }
      if (lower.startsWith('src/')) {
        score += 1;
      }
      if (lower.startsWith('tests/') && bestTest == null) {
        bestTest = path;
      }
      if (score > 0) {
        scores.put(path, score);
      }
    }
    for (Integer round = 0; round < 4 && !scores.isEmpty(); round++) {
      String top;
      for (String p : scores.keySet()) {
        if (top == null || scores.get(p) > scores.get(top)) {
          top = p;
        }
      }
      picked.add(top);
      scores.remove(top);
    }
    if (bestTest != null && !picked.contains(bestTest)) {
      picked.add(bestTest);
    }
    if (
      state.filePaths.contains('src/index.ts') &&
      !picked.contains('src/index.ts')
    ) {
      picked.add('src/index.ts');
    }
    return picked;
  }

  public static Map<String, Object> generate(
    AgentPipelineState state,
    Map<String, String> retrieved
  ) {
    String context = '';
    for (String path : retrieved.keySet()) {
      context +=
        '\n### ' +
        path +
        '\n```ts\n' +
        retrieved.get(path) +
        '\n```\n';
    }
    String userPrompt =
      '## Issue #' +
      state.issueNumber +
      ': ' +
      state.issueTitle +
      '\nType: ' +
      state.questType +
      '\n\n' +
      AgentHttp.abbreviate(state.issueBody, 6000) +
      '\n\n## Repository guide\n' +
      AgentHttp.abbreviate(state.guide, 3000) +
      '\n\n## Existing files (paths)\n' +
      AgentHttp.abbreviate(String.join(state.filePaths, '\n'), 4000) +
      '\n\n## Retrieved code (RAG context)\n' +
      context +
      '\n\nReturn the JSON for this change.';
    Map<String, Object> out = AgentLLMClient.createJson(
      SYSTEM_PROMPT,
      userPrompt,
      OUTPUT_FIELDS
    );
    validate(out);
    return out;
  }

  public static void validate(Map<String, Object> out) {
    for (String f : OUTPUT_FIELDS) {
      if (String.isBlank((String) out.get(f))) {
        throw new InvalidGenerationException('Generated output missing ' + f);
      }
    }
    assertSafePath((String) out.get('filePath'), 'src/');
    assertSafePath((String) out.get('unitTestPath'), 'tests/');
  }

  private static void assertSafePath(String path, String prefix) {
    if (
      !path.startsWith(prefix) ||
      path.contains('..') ||
      path.contains('\\') ||
      !Pattern.matches('[A-Za-z0-9_./-]+', path)
    ) {
      throw new InvalidGenerationException('Unsafe path rejected: ' + path);
    }
  }
}
