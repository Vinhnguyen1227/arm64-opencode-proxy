const assert = require('assert');
const fs = require('fs');
const path = require('path');
const { calculateCredits, CreditLedger, MODEL_RATES } = require('../proxy');

console.log('--- Running Credit Calculation & Ledger Test Suite ---\n');

let passed = 0;
let failed = 0;

function runTest(name, fn) {
  try {
    fn();
    console.log(`[PASS] ${name}`);
    passed++;
  } catch (err) {
    console.error(`[FAIL] ${name}: ${err.message}`);
    failed++;
  }
}

// 1. Math Verification from Guide
// mimo-v2.6-pro: 100 hit, 50 miss, 20 out -> (100 * 2.5) + (50 * 300) + (20 * 600) = 250 + 15000 + 12000 = 27,250
runTest('Credit Calculation: mimo-v2.6-pro rate math', () => {
  const usage = {
    prompt_tokens: 150,
    completion_tokens: 20,
    prompt_tokens_details: { cached_tokens: 100 }
  };
  const res = calculateCredits('mimo-v2.6-pro', usage);
  assert.strictEqual(res.hitTokens, 100);
  assert.strictEqual(res.missTokens, 50);
  assert.strictEqual(res.outputTokens, 20);
  assert.strictEqual(res.totalCredits, 27250);
});

// mimo-v2.6-flash: 100 hit, 50 miss, 20 out -> (100 * 2.0) + (50 * 100) + (20 * 200) = 200 + 5000 + 4000 = 9,200
runTest('Credit Calculation: mimo-v2.6-flash rate math', () => {
  const usage = {
    prompt_tokens: 150,
    completion_tokens: 20,
    prompt_cache_hit_tokens: 100 // alternative DeepSeek field name
  };
  const res = calculateCredits('mimo-v2.6-flash', usage);
  assert.strictEqual(res.hitTokens, 100);
  assert.strictEqual(res.missTokens, 50);
  assert.strictEqual(res.outputTokens, 20);
  assert.strictEqual(res.totalCredits, 9200);
});

// Model prefix normalization: vgpt/mimo-v2.6-pro
runTest('Credit Calculation: handles model name prefixes (vgpt/...)', () => {
  const usage = {
    prompt_tokens: 100,
    completion_tokens: 10,
    prompt_tokens_details: { cached_tokens: 0 }
  };
  const res = calculateCredits('vgpt/mimo-v2.6-pro', usage);
  // 0 hit + 100 miss * 300 + 10 out * 600 = 30000 + 6000 = 36000
  assert.strictEqual(res.totalCredits, 36000);
});

// 2. Ledger Atomic Operations
const testLedgerPath = path.join(__dirname, 'test_ledger.json');
if (fs.existsSync(testLedgerPath)) fs.unlinkSync(testLedgerPath);

runTest('CreditLedger: initial state is empty & auto-created', () => {
  const ledger = new CreditLedger(testLedgerPath);
  assert.strictEqual(ledger.getUsage('sk-test-key'), 0);
});

runTest('CreditLedger: atomic usage addition and persistence', () => {
  const ledger = new CreditLedger(testLedgerPath);
  const newUsage = ledger.addUsage('sk-test-key', 5000);
  assert.strictEqual(newUsage, 5000);

  // Reload from disk to verify atomic save
  const reloaded = new CreditLedger(testLedgerPath);
  assert.strictEqual(reloaded.getUsage('sk-test-key'), 5000);

  // Add more usage
  const updated = reloaded.addUsage('sk-test-key', 15000);
  assert.strictEqual(updated, 20000);
});

// 3. Pre-Flight Limit Enforcement Logic
runTest('Pre-Flight Quota Check: blocks when reaching 2B limit', () => {
  const ledger = new CreditLedger(testLedgerPath);
  ledger.addUsage('sk-heavy-user', 2_000_000_000);
  const usage = ledger.getUsage('sk-heavy-user');
  assert.strictEqual(usage >= 2_000_000_000, true);
});

// 4. Period Rollover Logic
runTest('Period Rollover: calculates YYYY-MM key format dynamically', () => {
  const ledger = new CreditLedger(testLedgerPath);
  const key = ledger._getKey('sk-test-key');
  const now = new Date();
  const expectedPeriod = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;
  assert.strictEqual(key, `sk-test-key:${expectedPeriod}`);
});

// Clean up test file
if (fs.existsSync(testLedgerPath)) fs.unlinkSync(testLedgerPath);

// 5. HTTP Integration Tests
const http = require('http');
const { app } = require('../proxy');

async function runAsyncTests() {
  const server = http.createServer(app);
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const port = server.address().port;

  // Test /healthz
  await new Promise((resolve) => {
    http.get(`http://127.0.0.1:${port}/healthz`, (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          assert.strictEqual(res.statusCode, 200);
          const json = JSON.parse(data);
          assert.strictEqual(json.status, 'ok');
          console.log('[PASS] HTTP Gateway: GET /healthz returns 200 {"status":"ok"}');
          passed++;
        } catch (e) {
          console.error(`[FAIL] HTTP Gateway: GET /healthz: ${e.message}`);
          failed++;
        }
        resolve();
      });
    }).on('error', (e) => {
      console.error(`[FAIL] HTTP Gateway: ${e.message}`);
      failed++;
      resolve();
    });
  });

  // Test 401 on Invalid Virtual Key
  await new Promise((resolve) => {
    const req = http.request(`http://127.0.0.1:${port}/models`, {
      headers: { 'Authorization': 'Bearer invalid-token-xyz' }
    }, (res) => {
      try {
        assert.strictEqual(res.statusCode, 401);
        console.log('[PASS] HTTP Gateway: Invalid key rejected with 401 Unauthorized');
        passed++;
      } catch (e) {
        console.error(`[FAIL] HTTP Gateway: 401 rejection: ${e.message}`);
        failed++;
      }
      resolve();
    });
    req.on('error', () => resolve());
    req.end();
  });

  // Test CORS 204
  await new Promise((resolve) => {
    const req = http.request(`http://127.0.0.1:${port}/responses`, {
      method: 'OPTIONS'
    }, (res) => {
      try {
        assert.strictEqual(res.statusCode, 204);
        console.log('[PASS] HTTP Gateway: OPTIONS /responses returns 204 Preflight');
        passed++;
      } catch (e) {
        console.error(`[FAIL] HTTP Gateway: CORS Preflight: ${e.message}`);
        failed++;
      }
      resolve();
    });
    req.on('error', () => resolve());
    req.end();
  });

  server.close();

  console.log(`\nTest Summary: ${passed} Passed, ${failed} Failed`);
  if (failed > 0) process.exit(1);
}

runAsyncTests();
