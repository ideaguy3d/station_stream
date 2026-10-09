import http from 'node:http';
import express from 'express';
import cors from 'cors';
import { ApolloServer } from '@apollo/server';
import { ApolloServerPluginDrainHttpServer } from '@apollo/server/plugin/drainHttpServer';
import { expressMiddleware } from '@as-integrations/express5';
import { createCatalogStore } from './catalog.js';
import { createPool, dbConfigured } from './db/pool.js';
import { typeDefs, makeResolvers } from './schema.js';

const PORT = Number(process.env.PORT ?? 4000);
// Where HLS video lives. Locally: scripts/local-cdn.js. In AWS: the CloudFront URL.
const VIDEO_BASE_URL = (process.env.VIDEO_BASE_URL ?? 'http://localhost:8080').replace(/\/$/, '');
const APP_VERSION = process.env.APP_VERSION ?? 'dev';
// Other sites whose pages may call /graphql (e.g. the Firebase-hosted UI). Comma-separated.
// Empty = same-origin only, which is all the built-in player page needs.
const CORS_ORIGINS = (process.env.CORS_ORIGINS ?? '').split(',').map((s) => s.trim()).filter(Boolean);

const log = (fields) => console.log(JSON.stringify({ ts: new Date().toISOString(), ...fields }));

// CATALOG_CACHE=off makes every GraphQL request query the database (used for load tests).
const CATALOG_CACHE_OFF = process.env.CATALOG_CACHE === 'off';

// With PGHOST set the catalog comes from Aurora; otherwise from the bundled JSON.
const pool = dbConfigured() ? createPool() : null;
const catalog = createCatalogStore({ pool, cacheOff: CATALOG_CACHE_OFF, log });
catalog.refresh(); // boot on the bundled JSON, then switch to Aurora as soon as it answers

const app = express();
const httpServer = http.createServer(app);
// The ALB keeps idle connections to us open for 60 s. Node's default keep-alive is 5 s, so under
// load the ALB sometimes reuses a connection Node is closing and returns a 502 (seen in L2 run 3).
// Outlast the load balancer so it always closes first. headersTimeout must exceed keepAliveTimeout.
httpServer.keepAliveTimeout = 65_000;
httpServer.headersTimeout = 66_000;

// One JSON line per request, so CloudWatch Logs can filter on fields later.
app.use((req, res, next) => {
  const start = process.hrtime.bigint();
  res.on('finish', () => {
    const ms = Number(process.hrtime.bigint() - start) / 1e6;
    log({ msg: 'request', method: req.method, path: req.originalUrl.split('?')[0], status: res.statusCode, ms: Math.round(ms) });
  });
  next();
});

// Load balancer health check. Cheap and dependency-free on purpose: it REPORTS the catalog
// source but never fails because of it. If it queried Aurora, a database blip would mark every
// task unhealthy at once and turn a degraded dependency into a total outage (cascading failure).
app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    version: APP_VERSION,
    uptimeSeconds: Math.round(process.uptime()),
    stations: catalog.stations.length,
    catalogSource: catalog.source,
    catalogAgeSeconds: catalog.ageSeconds,
    ...(catalog.lastError && { catalogLastError: catalog.lastError }),
  });
});

const apollo = new ApolloServer({
  typeDefs,
  resolvers: makeResolvers({ catalog, videoBaseUrl: VIDEO_BASE_URL }),
  // On SIGTERM (what ECS sends before stopping a task), stop taking new
  // requests and let in-flight ones finish.
  plugins: [ApolloServerPluginDrainHttpServer({ httpServer })],
});
await apollo.start();

// cors() answers the browser's OPTIONS preflight and adds Access-Control-Allow-Origin
// only for listed origins; maxAge lets the browser skip the preflight for 10 minutes.
// Each GraphQL request nudges the catalog: refresh in the background if stale (or inline if the cache is off).
const touchCatalog = async (_req, _res, next) => {
  try { await catalog.touch(); } catch { /* touch() already logs; never fail a request over it */ }
  next();
};

app.use('/graphql', cors({ origin: CORS_ORIGINS, methods: ['GET', 'POST'], maxAge: 600 }), touchCatalog, express.json(), expressMiddleware(apollo));
app.use(express.static(new URL('../public', import.meta.url).pathname));

await new Promise((resolve) => httpServer.listen({ port: PORT }, resolve));
log({ msg: 'started', port: PORT, videoBaseUrl: VIDEO_BASE_URL, version: APP_VERSION, corsOrigins: CORS_ORIGINS, database: Boolean(pool), catalogCache: CATALOG_CACHE_OFF ? 'off' : 'on' });
