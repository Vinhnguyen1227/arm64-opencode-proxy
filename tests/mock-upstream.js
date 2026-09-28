/**
 * Standalone Mock Upstream AI API Server
 * Listens on port 9000 to simulate an upstream OpenAI/MiMo provider.
 * Intercepts, logs, and asserts all incoming headers from Nginx.
 */

const http = require('http');

const PORT = 9000;
let lastRequest = {
  timestamp: null,
  method: null,
  url: null,
  headers: {},
  body: null
};

const server = http.createServer((req, res) => {
  let bodyChunks = [];
  req.on('data', chunk => bodyChunks.push(chunk));
  req.on('end', () => {
    const rawBody = Buffer.concat(bodyChunks).toString('utf8');
    let parsedBody = null;
    try {
      if (rawBody) parsedBody = JSON.parse(rawBody);
    } catch (_) {
      parsedBody = rawBody;
    }

    // Only record actual AI completion / model requests, not internal inspector calls
    if (req.url.startsWith('/v1/')) {
      lastRequest = {
        timestamp: new Date().toISOString(),
        method: req.method,
        url: req.url,
        headers: req.headers,
        body: parsedBody
      };

      console.log(`[Mock Upstream] Intercepted ${req.method} ${req.url}`);
      console.log(`  > Host           : ${req.headers['host']}`);
      console.log(`  > User-Agent     : ${req.headers['user-agent']}`);
      console.log(`  > Authorization  : ${req.headers['authorization']}`);
      console.log(`  > X-Forwarded-For: ${req.headers['x-forwarded-for'] || '<DROPPED / ABSENT>'}`);
      console.log(`  > X-Real-IP      : ${req.headers['x-real-ip'] || '<DROPPED / ABSENT>'}`);
    }

    // Route: Inspector endpoint for automated test assertion
    if (req.method === 'GET' && req.url === '/_inspect') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify(lastRequest, null, 2));
    }

    // Route: Health check
    if (req.method === 'GET' && req.url === '/healthz') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ status: 'ok', server: 'mock-upstream' }));
    }

    // Route: Models list
    if (req.method === 'GET' && req.url === '/v1/models') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({
        object: 'list',
        data: [
          { id: 'hana/mimo-v2.5', object: 'model', owned_by: 'mock-upstream' },
          { id: 'mimo-v1', object: 'model', owned_by: 'mock-upstream' }
        ]
      }));
    }

    // Route: Chat completions
    if (req.method === 'POST' && req.url === '/v1/chat/completions') {
      const isStream = parsedBody && parsedBody.stream === true;

      if (isStream) {
        // SSE Streaming
        res.writeHead(200, {
          'Content-Type': 'text/event-stream; charset=utf-8',
          'Cache-Control': 'no-cache',
          'Connection': 'keep-alive',
          'Access-Control-Allow-Origin': '*'
        });

        const chunk1 = JSON.stringify({
          id: 'chatcmpl-mock-101',
          object: 'chat.completion.chunk',
          choices: [{ index: 0, delta: { role: 'assistant', content: 'Hello' } }]
        });
        const chunk2 = JSON.stringify({
          id: 'chatcmpl-mock-101',
          object: 'chat.completion.chunk',
          choices: [{ index: 0, delta: { content: ' from Mock Upstream!' } }]
        });

        res.write(`data: ${chunk1}\n\n`);
        setTimeout(() => {
          res.write(`data: ${chunk2}\n\n`);
          setTimeout(() => {
            res.write('data: [DONE]\n\n');
            res.end();
          }, 50);
        }, 50);
        return;
      } else {
        // Standard JSON response
        res.writeHead(200, { 'Content-Type': 'application/json' });
        return res.end(JSON.stringify({
          id: 'chatcmpl-mock-101',
          object: 'chat.completion',
          choices: [{
            index: 0,
            message: { role: 'assistant', content: 'Hello from Mock Upstream!' },
            finish_reason: 'stop'
          }],
          usage: { prompt_tokens: 10, completion_tokens: 5, total_tokens: 15 }
        }));
      }
    }

    // Default fallback
    res.writeHead(404, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: 'Endpoint Not Found' }));
  });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[Mock Upstream Server] Running at http://0.0.0.0:${PORT}`);
});

