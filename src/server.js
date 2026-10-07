import http from 'node:http';
import express from 'express';
import { ApolloServer } from '@apollo/server';
import { ApolloServerPluginDrainHttpServer } from '@apollo/server/plugin/drainHttpServer';
import { expressMiddleware } from '@as-integrations/express5';
import { loadCatalog } from './catalog.js';
import { typeDefs, makeResolvers } from './schema.js';

const PORT = Number(process.env.PORT ?? 4000);
// Where HLS video lives. Locally: scripts/local-cdn.js. In AWS: the CloudFront URL.
const VIDEO_BASE_URL = (process.env.VIDEO_BASE_URL ?? 'http://localhost:8080').replace(/\/$/, '');
const APP_VERSION = process.env.APP_VERSION ?? 'dev';

const log = (fields) => console.log(JSON.stringify({ ts: new Date().toISOString(), ...fields }));

const catalog = loadCatalog();
const app = express();
const httpServer = http.createServer(app);

// One JSON line per request, so CloudWatch Logs can filter on fields later.
app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - start) / 1e6;
    log({ msg: 'request', method: req.method, path: req.originalUrl.split('?')[0], status: res.statusCode, ms: Math.round(ms) });
  });
  next();
});

// Load balancer health check. Cheap and dependency-free on purpose.
app.get('/health', (_req, res) => {
  res.json({ status: 'ok', version: APP_VERSION, uptimeSeconds: Math.round(process.uptime()), stations: catalog.stations.length });
});

const apollo = new ApolloServer({
  typeDefs,
  resolvers: makeResolvers({ catalog, videoBaseUrl: VIDEO_BASE_URL }),
  // On SIGTERM (what ECS sends before stopping a task), stop taking new
  // requests and let in-flight ones finish.
  plugins: [ApolloServerPluginDrainHttpServer({ httpServer })],
});
await apollo.start();

app.use('/graphql', express.json(), expressMiddleware(apollo));
app.use(express.static(new URL('../public', import.meta.url).pathname));

await new Promise((resolve) => httpServer.listen({ port: PORT }, resolve));
log({ msg: 'started', port: PORT, videoBaseUrl: VIDEO_BASE_URL, version: APP_VERSION });
