// Stand-in for CloudFront during local development: serves video/out on its
// own port with CORS, so the API never serves video, even locally.
import http from 'node:http';
import { createReadStream, statSync } from 'node:fs';
import { extname, join, normalize } from 'node:path';

const PORT = Number(process.env.CDN_PORT ?? 8080);
const ROOT = new URL('../video/out', import.meta.url).pathname;
const TYPES = {
  '.m3u8': 'application/vnd.apple.mpegurl',
  '.ts': 'video/mp2t',
  '.m4s': 'video/iso.segment',
  '.mp4': 'video/mp4',
  '.jpg': 'image/jpeg',
};

http
  .createServer((req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    const urlPath = decodeURIComponent(new URL(req.url, 'http://x').pathname);
    const file = join(ROOT, normalize(urlPath));
    if (!file.startsWith(ROOT)) return res.writeHead(403).end();
    try {
      if (!statSync(file).isFile()) throw new Error('not a file');
    } catch {
      return res.writeHead(404).end();
    }
    res.writeHead(200, { 'Content-Type': TYPES[extname(file)] ?? 'application/octet-stream' });
    createReadStream(file).pipe(res);
  })
  .listen(PORT, () => console.log(`local CDN serving ${ROOT} on http://localhost:${PORT}`));
