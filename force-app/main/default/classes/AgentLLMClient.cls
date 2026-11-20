/**
 * LLM access through Salesforce's built-in Models API (aiplatform.ModelsAPI),
 * routed through the Einstein Trust Layer — no external API keys required.
 * Default model: sfdc_ai__DefaultBedrockAnthropicClaude4Sonnet (Agent_Config__mdt.Model__c).
 *
 * The Models API has no schema-enforced JSON mode, so createJson() instructs the
 * model to return a bare JSON object, extracts it tolerantly (code fences, prose),
 * verifies every required key, and retries once on malformed output.
 */
public with sharing class AgentLLMClient {
  public class LlmException extends Exception {
  }

  public interface Provider {
    String generate(String modelName, String prompt);
  }

  @TestVisible
  private static Provider provider = new ModelsApiProvider();

  public class ModelsApiProvider implements Provider {
    public String generate(String modelName, String prompt) {
      aiplatform.ModelsAPI.createGenerations_Request req = new aiplatform.ModelsAPI.createGenerations_Request();
      req.modelName = modelName;
      aiplatform.ModelsAPI_GenerationRequest body = new aiplatform.ModelsAPI_GenerationRequest();
      body.prompt = prompt;
      req.body = body;
      try {
        aiplatform.ModelsAPI.createGenerations_Response res = new aiplatform.ModelsAPI()
          .createGenerations(req);
        return res.Code200.generation.generatedText;
      } catch (aiplatform.ModelsAPI.createGenerations_ResponseException e) {
        throw new LlmException(
          'Models API error (' + e.responseCode + '): ' + e.getMessage()
        );
      }
    }
  }

  public static Map<String, Object> createJson(
    String systemPrompt,
    String userPrompt,
    List<String> requiredKeys
  ) {
    String model = AgentConfig.get().model;
    String prompt =
      systemPrompt +
      '\n\n' +
      userPrompt +
      '\n\n## Output format\nRespond with ONLY one JSON object — no markdown fences, no commentary before or after. ' +
      'It must contain exactly these keys (string values unless the instructions say otherwise): ' +
      String.join(requiredKeys, ', ') +
      '. ' +
      'Escape newlines and quotes inside string values correctly.';
    String lastError;
    for (Integer attempt = 1; attempt <= 2; attempt++) {
      String raw = provider.generate(
        model,
        attempt == 1
          ? prompt
          : prompt +
            '\n\nYour previous reply was not valid JSON (' +
            lastError +
            '). Return only the JSON object.'
      );
      try {
        Map<String, Object> parsed = extractJson(raw);
        for (String k : requiredKeys) {
          if (parsed.get(k) == null) {
            throw new LlmException('missing key ' + k);
          }
          Object v = parsed.get(k);
          if (
            !(v instanceof String) &&
            !(v instanceof List<Object>) &&
            !(v instanceof Map<String, Object>)
          ) {
            parsed.put(k, String.valueOf(v));
          }
        }
        return parsed;
      } catch (Exception e) {
        lastError = e.getMessage();
      }
    }
    throw new LlmException('Model returned unusable JSON twice: ' + lastError);
  }

  @TestVisible
  private static Map<String, Object> extractJson(String raw) {
    if (String.isBlank(raw)) {
      throw new LlmException('empty response');
    }
    Integer start = raw.indexOf('{');
    Integer finish = raw.lastIndexOf('}');
    if (start < 0 || finish <= start) {
      throw new LlmException('no JSON object found');
    }
    Object parsed = JSON.deserializeUntyped(raw.substring(start, finish + 1));
    if (!(parsed instanceof Map<String, Object>)) {
      throw new LlmException('top-level JSON is not an object');
    }
    return (Map<String, Object>) parsed;
  }
}
