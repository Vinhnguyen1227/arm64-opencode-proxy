/**
 * OpenCode V2 Anti-Loop Reasoning Plugin
 *
 * Runs exclusively inside the end-user's OpenCode client environment.
 * Monitors streaming thinking traces (part.type === "reasoning" | "thinking").
 * Uses an arbitrary free model from OpenCode's free model pool to judge loops.
 * Automatically loops back to rotate across free models if rate-limited (HTTP 429).
 * Aborts the runaway session via session.abort() to save user credits.
 */

// Candidate pool of OpenCode built-in free models
const FREE_MODELS_POOL = [
  'opencode/mimo-v2.6-flash-free',
  'opencode/nemotron-3.5-lightning-free',
  'opencode/ling-3.1-flash-free',
  'opencode/longcat-2.5-preview-free',
  'opencode/exo-free',
  'opencode/big-pickle',
  'opencode/space-bunny-free',
  'opencode/fledge-alpha-free',
  'opencode/ling-3.0-flash-fin-free',
  'opencode/nemotron-3-ultra-free',
  'opencode/muse-spark-1.3-contributor-free'
];

// Configuration thresholds
const MIN_REASONING_CHARS = 3500;  // Skip short normal thinking traces
const CHECK_INTERVAL_CHARS = 2000; // Character delta before next check
const CONFIDENCE_THRESHOLD = 0.8;  // Minimum confidence score to abort
const REPETITION_HEURISTIC_SCORE = 0.6; // Local repetition score to force early check

/**
 * Fast local n-gram repetition detector.
 * Returns a score between 0.0 and 1.0 based on phrase repetition.
 */
function detectLocalRepetition(text) {
  if (!text || text.length < 1500) return 0.0;

  const sample = text.slice(-2500);
  const phraseLength = 35;
  const seen = new Map();
  let maxRepeats = 0;

  for (let i = 0; i <= sample.length - phraseLength; i += 15) {
    const chunk = sample.substring(i, i + phraseLength).toLowerCase().replace(/\s+/g, ' ');
    const count = (seen.get(chunk) || 0) + 1;
    seen.set(chunk, count);
    if (count > maxRepeats) maxRepeats = count;
  }

  if (maxRepeats >= 4) return 1.0;
  if (maxRepeats >= 3) return 0.8;
  if (maxRepeats >= 2) return 0.5;
  return 0.1;
}

/**
 * Loops back across free models to find an available judge model.
 * Bypasses individual free model rate limits (429) or temporary outages.
 */
async function inspectWithRandomFreeModel(client, reasoningExcerpt, queryFn = null) {
  const candidates = [...FREE_MODELS_POOL];
  const maxRetries = Math.min(5, candidates.length);

  const prompt = [
    'You are an automated reasoning loop supervisor for an AI coding assistant.',
    'Carefully analyze this trailing excerpt of an active reasoning/thinking trace:',
    '<<<BEGIN THINKING EXCERPT>>>',
    reasoningExcerpt,
    '<<<END THINKING EXCERPT>>>',
    '',
    'Question: Is the model stuck in an unproductive infinite reasoning loop, endlessly repeating deductions, circular thoughts, or dead ends without making forward progress?',
    'Answer with ONLY a strict JSON object (no markdown fences, no conversational text):',
    '{"is_loop": true, "confidence": 0.95, "reason": "concise explanation"}'
  ].join('\n');

  for (let attempt = 1; attempt <= maxRetries && candidates.length > 0; attempt++) {
    // Arbitrarily pick random free model from remaining candidates
    const randIdx = Math.floor(Math.random() * candidates.length);
    const chosenModel = candidates.splice(randIdx, 1)[0];

    try {
      let rawText = '';

      if (typeof queryFn === 'function') {
        // Allows dependency injection for tests
        rawText = await queryFn(chosenModel, prompt);
      } else if (client?.session?.create && client?.session?.prompt) {
        // OpenCode SDK client interface
        const tempSession = await client.session.create({
          title: 'anti-loop-judge',
          model: chosenModel
        });

        const res = await client.session.prompt({
          sessionID: tempSession.id,
          model: chosenModel,
          prompt
        });

        rawText = res?.text || res?.content || (typeof res === 'string' ? res : '');

        // Cleanup temporary judge session
        try {
          if (client.session.delete) {
            await client.session.delete({ sessionID: tempSession.id });
          }
        } catch (_) {}
      }

      // Parse JSON from model output
      if (rawText) {
        const jsonMatch = rawText.match(/\{[\s\S]*?\}/);
        if (jsonMatch) {
          const parsed = JSON.parse(jsonMatch[0]);
          if (typeof parsed.is_loop === 'boolean') {
            return {
              is_loop: parsed.is_loop,
              confidence: Number(parsed.confidence) || (parsed.is_loop ? 0.9 : 0.1),
              reason: parsed.reason || 'Judge evaluation',
              modelUsed: chosenModel,
              attempts: attempt
            };
          }
        }
      }
    } catch (err) {
      // 429 Rate Limit / Outage: Loop back to pick another free model from pool
      continue;
    }
  }

  return {
    is_loop: false,
    confidence: 0.0,
    reason: 'Free model pool rate-limited or unavailable',
    modelUsed: null,
    attempts: maxRetries
  };
}

/**
 * OpenCode V2 Plugin Definition
 */
const pluginDefinition = {
  id: 'anti-loop',
  async setup(ctx) {
    const sessionStates = new Map();

    const handlePartUpdate = async (event) => {
      if (!event) return;
      const part = event.properties?.part || event.part;
      if (!part) return;

      const partType = part.type || '';
      if (partType !== 'reasoning' && partType !== 'thinking') return;

      const currentText = part.text || part.content || '';
      const textLen = currentText.length;
      if (textLen < MIN_REASONING_CHARS) return;

      const sessionID = event.sessionID || event.properties?.sessionID;
      if (!sessionID) return;

      let state = sessionStates.get(sessionID);
      if (!state) {
        state = { lastCheckedLength: 0, isChecking: false };
        sessionStates.set(sessionID, state);
      }

      if (state.isChecking) return;

      // Check cadence conditions
      const delta = textLen - state.lastCheckedLength;
      const repScore = detectLocalRepetition(currentText);
      const shouldCheck = delta >= CHECK_INTERVAL_CHARS || repScore >= REPETITION_HEURISTIC_SCORE;

      if (!shouldCheck) return;

      state.isChecking = true;
      state.lastCheckedLength = textLen;

      try {
        const excerpt = currentText.slice(-2500);
        const verdict = await inspectWithRandomFreeModel(ctx?.client, excerpt);

        if (verdict && verdict.is_loop && verdict.confidence >= CONFIDENCE_THRESHOLD) {
          const logMsg = `[Anti-Loop Plugin] Runaway reasoning loop detected by ${verdict.modelUsed}! Aborting session (${textLen} chars). Reason: ${verdict.reason}`;

          if (ctx?.client?.app?.log) {
            await ctx.client.app.log(logMsg);
          } else if (ctx?.app?.log) {
            await ctx.app.log(logMsg);
          } else {
            console.warn(logMsg);
          }

          // Terminate active session
          if (ctx?.client?.session?.abort) {
            await ctx.client.session.abort({ sessionID });
          } else if (ctx?.session?.abort) {
            await ctx.session.abort({ sessionID });
          }
        }
      } catch (err) {
        // Suppress background inspector errors
      } finally {
        state.isChecking = false;
      }
    };

    // OpenCode V2 event subscription pattern
    if (ctx?.event?.subscribe) {
      ctx.event.subscribe('message.part.updated', async (event) => {
        await handlePartUpdate(event);
      });
    }

    // OpenCode V1/hook return pattern for backwards & hybrid compatibility
    return {
      event: async ({ event }) => {
        if (event?.type === 'message.part.updated') {
          await handlePartUpdate(event);
        }
      }
    };
  }
};

// Export plugin and utility functions
pluginDefinition.default = pluginDefinition;
pluginDefinition.AntiLoopPlugin = pluginDefinition.setup;
pluginDefinition.FREE_MODELS_POOL = FREE_MODELS_POOL;
pluginDefinition.detectLocalRepetition = detectLocalRepetition;
pluginDefinition.inspectWithRandomFreeModel = inspectWithRandomFreeModel;

module.exports = pluginDefinition;
module.exports.default = pluginDefinition;

