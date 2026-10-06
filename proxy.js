require('dotenv').config();
const express = require('express');
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { Transform } = require('stream');

const PORT = parseInt(process.env.PORT, 10) || 8080;
const MONTHLY_LIMIT = parseInt(process.env.MONTHLY_LIMIT, 10) || 2_000_000_000;

const UPSTREAM_HOST = process.env.UPSTREAM_HOST || 'token-plan-cn.xiaomimimo.com';
const UPSTREAM_PORT = parseInt(process.env.UPSTREAM_PORT, 10) || 443;
const UPSTREAM_SCHEME = process.env.UPSTREAM_SCHEME || 'https';
const UPSTREAM_KEY = process.env.MIMO_TOKEN_PLAN_KEY || process.env.MIMO_API_KEY || 'tp-master-plan-secret';
const CANONICAL_USER_AGENT = 'opencode/1.18.21 ai-sdk/openai';

const DATA_DIR = path.join(__dirname, 'data');
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}

const USER_A = process.env.USER_A_KEY || 'sk-userA-vkey-001';
const USER_B = process.env.USER_B_KEY || 'sk-userB-vkey-002';
const USER_C = process.env.USER_C_KEY || 'sk-userC-vkey-003';

const VIRTUAL_KEYS = new Set([USER_A, USER_B, USER_C].filter(Boolean));
const KEY_TENANTS = {
  [USER_A]: 'userA',
  [USER_B]: 'userB',
  [USER_C]: 'userC'
};

const MODEL_RATES = {
  'mimo-v2.6-pro':   { hit: 2.5, miss: 300, output: 600 },
  'mimo-v2.6-flash': { hit: 2.0, miss: 100, output: 200 },
  'mimo-v2.5-pro':   { hit: 2.5, miss: 300, output: 600 },
  'mimo-v2.5':       { hit: 2.0, miss: 100, output: 200 }
};
const DEFAULT_RATE = MODEL_RATES['mimo-v2.6-pro'];

function calculateCredits(modelName, usage) {
  if (!usage) return { totalCredits: 0, hitTokens: 0, missTokens: 0, outputTokens: 0 };

  const cleanName = (modelName || '').replace(/^.*\//, '');
  const rates = MODEL_RATES[cleanName] || MODEL_RATES[modelName] || DEFAULT_RATE;
  const promptTokens = usage.prompt_tokens ?? usage.input_tokens ?? 0;
  const outputTokens = usage.completion_tokens ?? usage.output_tokens ?? 0;

  const hitTokens = usage.prompt_tokens_details?.cached_tokens
                 ?? usage.input_tokens_details?.cached_tokens
                 ?? usage.prompt_cache_hit_tokens
                 ?? 0;
  const missTokens = Math.max(0, promptTokens - hitTokens);

  const totalCredits = (hitTokens * rates.hit) +
                       (missTokens * rates.miss) +
                       (outputTokens * rates.output);

  return {
    model: modelName,
    hitTokens,
    missTokens,
    outputTokens,
    totalCredits: Math.round(totalCredits * 100) / 100
  };
}

class CreditLedger {
  constructor(filePath = path.join(DATA_DIR, 'credits_ledger.json')) {
    this.filePath = filePath;
    this.data = this._load();
  }

  _getKey(apiKey) {
    const now = new Date();
    const period = `${now.getUTCFullYear()}-${String(now.getUTCMonth() + 1).padStart(2, '0')}`;
    return `${apiKey}:${period}`;
  }

  _load() {
    try {
      if (fs.existsSync(this.filePath)) {
        return JSON.parse(fs.readFileSync(this.filePath, 'utf8'));
      }
    } catch (err) {
      console.error(`[Ledger] Initializing new state (load error: ${err.message})`);
    }
    return {};
  }

  _save() {
    try {
      const tempPath = `${this.filePath}.${Date.now()}.${Math.random().toString(36).slice(2)}.tmp`;
      fs.writeFileSync(tempPath, JSON.stringify(this.data, null, 2), 'utf8');
      fs.renameSync(tempPath, this.filePath);
    } catch (err) {
      console.error(`[Ledger] Atomic save failed: ${err.message}`);
    }
  }

  getUsage(apiKey) {
    return this.data[this._getKey(apiKey)] || 0;
  }

  addUsage(apiKey, amount) {
    const key = this._getKey(apiKey);
    this.data[key] = (this.data[key] || 0) + amount;
    this._save();
    return this.data[key];
  }
}

const ledger = new CreditLedger();

function createStreamUsageMeter(apiKey, fallbackModel, ledgerInstance, reqIdShort, onMeter) {
  let sseBuffer = '';

  return new Transform({
    transform(chunk, encoding, callback) {
      this.push(chunk);

      sseBuffer += chunk.toString('utf8');
      const lines = sseBuffer.split('\n');
      sseBuffer = lines.pop();

      for (const line of lines) {
        const trimmed = line.trim();
        if (!trimmed.startsWith('data:') || trimmed === 'data: [DONE]') continue;

        try {
          const payload = JSON.parse(trimmed.replace(/^data:\s*/, ''));
          const usageObj = payload.usage || payload.response?.usage;
          if (usageObj) {
            const activeModel = payload.model || payload.response?.model || fallbackModel;
            const res = calculateCredits(activeModel, usageObj);
            const updatedUsage = ledgerInstance.addUsage(apiKey, res.totalCredits);

            if (typeof onMeter === 'function') {
              onMeter(res, updatedUsage);
            }

            console.log(
              `[${new Date().toISOString()}] METER [${reqIdShort}] Key: ${apiKey.slice(0, 10)}... | Model: ${res.model} | ` +
              `Hit: ${res.hitTokens} | Miss: ${res.missTokens} | Out: ${res.outputTokens} | ` +
              `Charged: ${res.totalCredits.toLocaleString()} Credits | ` +
              `Month Total: ${updatedUsage.toLocaleString()} / ${MONTHLY_LIMIT.toLocaleString()}`
            );
          }
        } catch {
          // Skip intermediate stream chunks
        }
      }
      callback();
    }
  });
}

const app = express();
app.disable('x-powered-by');

// Scanner Shield: drop crawler probes immediately
const SCANNER_REGEX = /(\.git|\.env|wp-admin|wp-login|\.php|setup\.cgi|xmlrpc\.php)/i;
app.use((req, res, next) => {
  if (SCANNER_REGEX.test(req.url)) {
    return req.destroy();
  }
  next();
});

// Health check
app.get('/healthz', (req, res) => {
  res.status(200).json({ status: 'ok' });
});

// Large buffer (50MB in RAM) for OpenCode 35KB-50KB tool schema payloads
app.use(express.raw({ type: '*/*', limit: '50mb' }));

app.all(['/responses', '/models', '/chat/completions', '/embeddings', '/v1/*'], (req, res) => {
  const startTime = Date.now();
  const reqId = crypto.randomBytes(16).toString('hex');
  const reqIdShort = reqId.slice(0, 8);
  res.setHeader('X-Request-ID', reqId);
  res.setHeader('Access-Control-Allow-Origin', '*');

  // 1. CORS Preflight
  if (req.method === 'OPTIONS') {
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Authorization, Content-Type, Accept');
    return res.status(204).end();
  }

  // 2. Virtual Key Authentication
  const authHeader = req.headers['authorization'] || '';
  const apiKey = authHeader.replace(/^Bearer\s+/i, '').trim();
  const authTenant = KEY_TENANTS[apiKey] || 'unauthorized';

  if (!VIRTUAL_KEYS.has(apiKey)) {
    const duration = Date.now() - startTime;
    console.error(`[${new Date().toISOString()}] ERROR [${reqIdShort}] error_code=PX011 error=UNAUTHORIZED upstream=- auth=unauthorized client=${req.ip} duration=${duration}ms`);
    console.log(`[${new Date().toISOString()}] INFO  [${reqIdShort}] ${req.method} ${req.url} -> local-proxy 401 ${duration}ms auth=unauthorized req=0B resp=96B`);
    return res.status(401).json({
      error: { message: 'Invalid Virtual API Key. Unauthorized proxy access.', code: 'invalid_api_key' }
    });
  }

  // 3. Pre-Flight Rate Limit: Check 2B Credit Ceiling
  const currentUsage = ledger.getUsage(apiKey);
  if (currentUsage >= MONTHLY_LIMIT) {
    const duration = Date.now() - startTime;
    console.error(`[${new Date().toISOString()}] ERROR [${reqIdShort}] error_code=PX012 error=QUOTA_EXHAUSTED upstream=- auth=${authTenant} usage=${currentUsage} limit=${MONTHLY_LIMIT}`);
    console.log(`[${new Date().toISOString()}] INFO  [${reqIdShort}] ${req.method} ${req.url} -> local-proxy 429 ${duration}ms auth=${authTenant} req=0B resp=140B`);
    return res.status(429).json({
      error: {
        message: `Monthly credit quota exceeded: Used ${currentUsage.toLocaleString()} / ${MONTHLY_LIMIT.toLocaleString()} credits.`,
        type: 'insufficient_quota',
        code: 'quota_exhausted'
      }
    });
  }

  // 4. Path Unification for OpenCode v2 protocol
  let targetPath = req.url;
  const rewriteMatch = req.url.match(/^\/(responses|models|chat\/completions|embeddings)(.*)$/);
  if (rewriteMatch) {
    targetPath = `/v1/${rewriteMatch[1]}${rewriteMatch[2]}`;
  }

  // 5. Parse body, inject stream_options, capture model
  let outboundBody = req.body && req.body.length > 0 ? req.body : null;
  let requestedModel = 'mimo-v2.6-pro';
  let isStream = false;

  if (outboundBody) {
    try {
      const parsed = JSON.parse(outboundBody.toString('utf8'));
      if (parsed.model) requestedModel = parsed.model;
      if (parsed.stream) {
        isStream = true;
        parsed.stream_options = { ...parsed.stream_options, include_usage: true };
        outboundBody = Buffer.from(JSON.stringify(parsed));
      }
    } catch {
      // Non-JSON or binary payload forwarded unchanged
    }
  }

  // 6. Canonical Outbound Headers (Scrub client fingerprints)
  const outboundHeaders = {
    'host': UPSTREAM_HOST,
    'content-type': req.headers['content-type'] || 'application/json',
    'accept': req.headers['accept'] || '*/*',
    'user-agent': CANONICAL_USER_AGENT,
    'authorization': `Bearer ${UPSTREAM_KEY}`,
    'x-request-id': reqId,
    'content-length': outboundBody ? outboundBody.length : 0
  };

  const clientModule = UPSTREAM_SCHEME === 'http' ? http : https;
  const upstreamReq = clientModule.request({
    hostname: UPSTREAM_HOST,
    port: UPSTREAM_PORT,
    path: targetPath,
    method: req.method,
    headers: outboundHeaders,
    timeout: 600000
  }, (upstreamRes) => {
    res.status(upstreamRes.statusCode);
    for (const [key, value] of Object.entries(upstreamRes.headers)) {
      if (!['transfer-encoding', 'content-length'].includes(key.toLowerCase())) {
        res.setHeader(key, value);
      }
    }

    let responseBytes = 0;
    let streamMeterData = null;

    if (isStream) {
      const meterStream = createStreamUsageMeter(apiKey, requestedModel, ledger, reqIdShort, (resObj, monthTotal) => {
        streamMeterData = { res: resObj, monthTotal };
      });
      meterStream.on('data', (chunk) => { responseBytes += chunk.length; });
      meterStream.on('end', () => {
        const duration = Date.now() - startTime;
        const creditTag = streamMeterData
          ? `credits=${streamMeterData.res.totalCredits.toLocaleString()} (hit:${streamMeterData.res.hitTokens} miss:${streamMeterData.res.missTokens} out:${streamMeterData.res.outputTokens}) month_total=${streamMeterData.monthTotal.toLocaleString()}`
          : `credits=0`;
        console.log(`[${new Date().toISOString()}] INFO  [${reqIdShort}] ${req.method} ${targetPath} -> ${UPSTREAM_HOST} ${upstreamRes.statusCode} ${duration}ms auth=${authTenant} ${creditTag} req=${outboundBody ? outboundBody.length : 0}B resp=${responseBytes}B`);
      });
      upstreamRes.pipe(meterStream).pipe(res);
    } else {
      // Non-streaming response handling
      const chunks = [];
      upstreamRes.on('data', (chunk) => {
        chunks.push(chunk);
        responseBytes += chunk.length;
      });
      upstreamRes.on('end', () => {
        const bodyBuf = Buffer.concat(chunks);
        let creditTag = 'credits=0';
        try {
          const json = JSON.parse(bodyBuf.toString('utf8'));
          const usageObj = json.usage || json.response?.usage;
          if (usageObj) {
            const activeModel = json.model || json.response?.model || requestedModel;
            const creditsRes = calculateCredits(activeModel, usageObj);
            const updatedUsage = ledger.addUsage(apiKey, creditsRes.totalCredits);
            creditTag = `credits=${creditsRes.totalCredits.toLocaleString()} (hit:${creditsRes.hitTokens} miss:${creditsRes.missTokens} out:${creditsRes.outputTokens}) month_total=${updatedUsage.toLocaleString()}`;
            console.log(
              `[${new Date().toISOString()}] METER [${reqIdShort}] Key: ${apiKey.slice(0, 10)}... | Model: ${creditsRes.model} | ` +
              `Hit: ${creditsRes.hitTokens} | Miss: ${creditsRes.missTokens} | Out: ${creditsRes.outputTokens} | ` +
              `Charged: ${creditsRes.totalCredits.toLocaleString()} Credits | ` +
              `Month Total: ${updatedUsage.toLocaleString()} / ${MONTHLY_LIMIT.toLocaleString()}`
            );
          }
        } catch {
          // Response is not JSON
        }
        res.end(bodyBuf);
        const duration = Date.now() - startTime;
        console.log(`[${new Date().toISOString()}] INFO  [${reqIdShort}] ${req.method} ${targetPath} -> ${UPSTREAM_HOST} ${upstreamRes.statusCode} ${duration}ms auth=${authTenant} ${creditTag} req=${outboundBody ? outboundBody.length : 0}B resp=${responseBytes}B`);
      });
    }
  });

  upstreamReq.on('error', (err) => {
    const duration = Date.now() - startTime;
    console.error(`[${new Date().toISOString()}] ERROR [${reqIdShort}] error_code=PX003 error=UPSTREAM_UNREACHABLE upstream=${UPSTREAM_HOST}:${UPSTREAM_PORT} detail="${err.message}"`);
    console.log(`[${new Date().toISOString()}] INFO  [${reqIdShort}] ${req.method} ${targetPath} -> ${UPSTREAM_HOST} 502 ${duration}ms auth=${authTenant} req=${outboundBody ? outboundBody.length : 0}B resp=64B`);
    res.status(502).json({ error: { message: 'Bad Gateway: Upstream inference cluster unreachable.', code: 'upstream_error' } });
  });

  if (outboundBody) {
    upstreamReq.write(outboundBody);
  }
  upstreamReq.end();
});

// Generic 404 for unknown endpoints (no route hints)
app.use((req, res) => {
  res.status(404).json({ error: { message: 'Not found', code: 'not_found' } });
});

if (require.main === module) {
  app.listen(PORT, '0.0.0.0', () => {
    console.log(`[Gateway] Credit-Metered Proxy listening on 0.0.0.0:${PORT}`);
    console.log(`[Gateway] Monthly Limit: ${MONTHLY_LIMIT.toLocaleString()} Credits / key`);
    console.log(`[Gateway] Registered Keys: ${VIRTUAL_KEYS.size}`);
  });
}

module.exports = { app, calculateCredits, CreditLedger, MODEL_RATES };
