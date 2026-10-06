const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');

const indexHtml = fs.readFileSync(path.join(__dirname, 'public', 'index.html'));

const securityHeaders = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'no-referrer',
  'Content-Security-Policy': "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:",
};

function handler(req, res) {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { ...securityHeaders, Allow: 'GET, HEAD' });
    return res.end();
  }

  if (req.url === '/' || req.url === '/index.html') {
    res.writeHead(200, { ...securityHeaders, 'Content-Type': 'text/html; charset=utf-8' });
    return res.end(indexHtml);
  }

  if (req.url === '/health') {
    res.writeHead(200, { ...securityHeaders, 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ status: 'ok' }));
  }

  res.writeHead(404, { ...securityHeaders, 'Content-Type': 'text/plain' });
  res.end('Not Found');
}

const server = http.createServer(handler);

if (require.main === module) {
  const port = process.env.PORT || 3000;
  server.listen(port, () => console.log(`Listening on port ${port}`));
}

module.exports = { server };
