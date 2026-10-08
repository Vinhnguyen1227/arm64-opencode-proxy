const assert = require('assert');
const {
  FREE_MODELS_POOL,
  detectLocalRepetition,
  inspectWithRandomFreeModel,
  AntiLoopPlugin
} = require('../.opencode/plugins/anti-loop');

console.log('--- Running OpenCode Anti-Loop Reasoning Plugin Test Suite ---\n');

let passed = 0;
let failed = 0;

function runTest(name, fn) {
  return Promise.resolve()
    .then(fn)
    .then(() => {
      console.log(`[PASS] ${name}`);
      passed++;
    })
    .catch((err) => {
      console.error(`[FAIL] ${name}: ${err.message}`);
      failed++;
    });
}

async function main() {
  // Test 1: Verify Free Models Pool
  await runTest('Free Models Pool contains 11 verified opencode/*-free models', () => {
    assert.strictEqual(FREE_MODELS_POOL.length, 11);
    assert.strictEqual(FREE_MODELS_POOL.includes('opencode/mimo-v2.6-flash-free'), true);
    assert.strictEqual(FREE_MODELS_POOL.includes('opencode/nemotron-3.5-lightning-free'), true);
    assert.strictEqual(FREE_MODELS_POOL.includes('opencode/ling-3.1-flash-free'), true);
    // Ensure no deepseek-v4 is in the pool
    assert.strictEqual(FREE_MODELS_POOL.some(m => m.includes('deepseek-v4')), false);
  });

  // Test 2: Local Repetition Heuristic on Normal vs Repeating Text
  await runTest('Heuristic: Low score on normal non-repeating reasoning text', () => {
    const normalText = 'We need to analyze the user request and implement the algorithm. ' +
      'First, let us check the input data and consider the edge cases. ' +
      'Next, we can structure the data flow and handle exceptions properly. ' +
      'Then we proceed to verify the output formatting.'.repeat(20);
    const score = detectLocalRepetition(normalText);
    assert.strictEqual(score <= 0.5, true, `Score ${score} should be <= 0.5 for linear reasoning`);
  });

  await runTest('Heuristic: High score on repetitive circular reasoning loop', () => {
    const loopSentence = 'Wait let me rethink this again and consider if there is an error in step one. ';
    const loopingText = ('Some initial context. ' + loopSentence.repeat(40));
    const score = detectLocalRepetition(loopingText);
    assert.strictEqual(score >= 0.8, true, `Score ${score} should be >= 0.8 for repetitive loop`);
  });

  // Test 3: Model Loop-Back Rotation on 429 Rate Limit
  await runTest('Rotation: Loops back on 429 Rate Limit and succeeds on subsequent free model', async () => {
    const attemptedModels = [];

    // Mock query function simulating 429 on first 2 attempts, then success
    const mockQueryFn = async (model, prompt) => {
      attemptedModels.push(model);
      if (attemptedModels.length < 3) {
        // Simulate HTTP 429 Too Many Requests
        const err = new Error('HTTP 429 Too Many Requests: Rate limit reached');
        err.status = 429;
        throw err;
      }
      return '{"is_loop": true, "confidence": 0.95, "reason": "Endless cycling detected"}';
    };

    const verdict = await inspectWithRandomFreeModel(null, 'test excerpt', mockQueryFn);

    assert.strictEqual(verdict.is_loop, true);
    assert.strictEqual(verdict.confidence, 0.95);
    assert.strictEqual(verdict.attempts, 3);
    assert.strictEqual(attemptedModels.length, 3);
    // Verify models tried are distinct
    const uniqueAttempts = new Set(attemptedModels);
    assert.strictEqual(uniqueAttempts.size, 3);
  });

  // Test 4: End-to-End Plugin Event Interception & Session Abort
  await runTest('Plugin Hook: Aborts session when reasoning loop confirmed', async () => {
    let abortedSession = null;
    let loggedMessage = null;

    const mockCtx = {
      client: {
        session: {
          abort: async ({ sessionID }) => {
            abortedSession = sessionID;
          },
          create: async () => ({ id: 'mock-judge-session' }),
          prompt: async () => ({
            text: '{"is_loop": true, "confidence": 0.92, "reason": "Repetitive reasoning loop"}'
          }),
          delete: async () => {}
        },
        app: {
          log: async (msg) => {
            loggedMessage = msg;
          }
        }
      }
    };

    const plugin = await AntiLoopPlugin(mockCtx);

    const loopPhrase = 'Wait, wait, let me recalculate the sum. No, wait, that was wrong, recalculate the sum. ';
    const fakeLoopTrace = loopPhrase.repeat(60); // > 4000 chars

    // Dispatch event to plugin
    await plugin.event({
      event: {
        type: 'message.part.updated',
        sessionID: 'session-xyz-123',
        part: {
          type: 'reasoning',
          text: fakeLoopTrace
        }
      }
    });

    assert.strictEqual(abortedSession, 'session-xyz-123', 'Session should be aborted');
    assert.strictEqual(loggedMessage !== null, true, 'Alert log should be emitted');
    assert.strictEqual(loggedMessage.includes('[Anti-Loop Plugin]'), true);
  });

  // Test 5: Plugin Hook: Does NOT abort on normal short reasoning
  await runTest('Plugin Hook: Skips short reasoning trace (< 3500 chars)', async () => {
    let abortedSession = null;

    const mockCtx = {
      client: {
        session: {
          abort: async () => { abortedSession = 'aborted'; }
        }
      }
    };

    const plugin = await AntiLoopPlugin(mockCtx);

    await plugin.event({
      event: {
        type: 'message.part.updated',
        sessionID: 'session-normal-456',
        part: {
          type: 'reasoning',
          text: 'Short normal thought. Calculating 2 + 2 = 4.'
        }
      }
    });

    assert.strictEqual(abortedSession, null, 'Short reasoning should not trigger check or abort');
  });

  console.log(`\nTest Summary: ${passed} Passed, ${failed} Failed`);
  if (failed > 0) process.exit(1);
}

main();
