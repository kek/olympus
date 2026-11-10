import path from "node:path";
import os from "node:os";
import {
  createAgentSession, createExtensionRuntime, ModelRuntime, SessionManager, SettingsManager,
} from "@earendil-works/pi-coding-agent";

export function resources(systemPrompt) {
  return {
    getExtensions: () => ({ extensions: [], errors: [], runtime: createExtensionRuntime() }),
    getSkills: () => ({ skills: [], diagnostics: [] }),
    getPrompts: () => ({ prompts: [], diagnostics: [] }),
    getThemes: () => ({ themes: [], diagnostics: [] }),
    getAgentsFiles: () => ({ agentsFiles: [] }),
    getSystemPrompt: () => systemPrompt,
    getSystemPromptSource: () => undefined,
    getAppendSystemPrompt: () => [],
    getAppendSystemPromptSources: () => [],
    extendResources() {},
    async reload() {},
  };
}

// A second stream must never turn one Fate reservation into two provider calls.
export function boundStream(stream, budget, timeoutMs) {
  let called = false;
  return (model, context, options = {}) => {
    if (called) throw new Error("provider_call_budget");
    called = true;
    return stream(model, context, {
      ...options,
      maxTokens: Math.min(budget, model.maxTokens),
      maxRetries: 0,
      timeoutMs,
    });
  };
}

export async function run({ config, request }) {
  if (!config?.provider || !config?.model ||
      !["propose", "review"].includes(request?.action) ||
      !Number.isInteger(request.budget) || request.budget < 1 || request.budget > 100_000 ||
      !Number.isInteger(request.timeout_ms) || request.timeout_ms < 1 || request.timeout_ms > 120_000 ||
      !Number.isInteger(request.max_bytes) || request.max_bytes < 1 || request.max_bytes > 1_048_576) {
    return { ok: false, error: "invalid_request" };
  }

  let session;
  try {
    const agentDir = path.resolve(config.agent_dir || process.env.PI_CODING_AGENT_DIR ||
      path.join(os.homedir(), ".pi", "agent"));
    const modelRuntime = await ModelRuntime.create({
      authPath: path.join(agentDir, "auth.json"),
      modelsPath: path.join(agentDir, "models.json"),
      modelsStorePath: path.join(agentDir, "models-cache.json"),
      refreshOnCreate: false,
      allowModelNetwork: false,
    });
    const selected = modelRuntime.getPhysicalModel(config.provider, config.model);
    if (!selected) return { ok: false, error: "model_not_found" };

    // Arbitrary model sampling parameters must not override the provider token cap.
    const model = { ...selected, samplingParams: undefined, samplingParamsByThinkingLevel: undefined };
    const instruction = request.action === "propose"
      ? 'Return ONLY a JSON object: {"artifact": <candidate>, "oaths": [optional supplemental checks]}. Satisfy the sealed contract and optimize its objective.'
      : 'Return ONLY a JSON object: {"objections": [zero-based indexes of sealed checks this artifact fails]}. Find real faults in your enemy\'s artifact. Never invent checks.';
    ({ session } = await createAgentSession({
      cwd: agentDir,
      agentDir,
      modelRuntime,
      model,
      thinkingLevel: "off",
      noTools: true,
      tools: [],
      customTools: [],
      resourceLoader: resources(instruction),
      sessionManager: SessionManager.inMemory(agentDir),
      settingsManager: SettingsManager.inMemory({
        compaction: { enabled: false },
        retry: { enabled: false },
        providerRetry: { maxRetries: 0 },
        cacheWarming: "off",
        transport: "sse",
      }),
    }));
    session.agent.streamFunction = boundStream(
      session.agent.streamFunction, request.budget, request.timeout_ms,
    );

    await session.prompt(JSON.stringify(request), { expandPromptTemplates: false });
    const message = session.messages.filter((m) => m.role === "assistant").at(-1);
    if (!message || message.stopReason !== "stop" ||
        message.content.some((c) => c.type !== "text" && c.type !== "thinking")) {
      return { ok: false, error: "pi_failed" };
    }
    if (message.usage?.output > request.budget) return { ok: false, error: "token_budget" };
    const text = session.getLastAssistantText();
    if (typeof text !== "string" || Buffer.byteLength(text) > request.max_bytes)
      return { ok: false, error: "response_budget" };
    const value = JSON.parse(text);
    if (!value || typeof value !== "object" || Array.isArray(value))
      return { ok: false, error: "invalid_response" };
    return { ok: true, value };
  } catch {
    // Do not put provider errors, prompts, paths or credentials on stdout/stderr.
    return { ok: false, error: "pi_failed" };
  } finally {
    session?.dispose();
  }
}
