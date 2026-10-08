// "Liked videos" for the Station Stream web UI: a Cloud Run function (GCP) backed by MongoDB Atlas.
//   GET  /  -> { likes: [episodeId, ...] }           newest first
//   POST /  { episodeId, liked: true|false } -> { episodeId, liked }
// Every request must carry a Firebase Auth ID token: "Authorization: Bearer <token>".
import functions from '@google-cloud/functions-framework';
import { initializeApp } from 'firebase-admin/app';
import { getAuth } from 'firebase-admin/auth';
import { MongoClient } from 'mongodb';

const ALLOWED_ORIGINS = (process.env.CORS_ORIGINS ?? '').split(',').map((s) => s.trim()).filter(Boolean);
const EPISODE_ID = /^[a-z0-9-]{1,64}$/;

// verifyIdToken only needs the project ID: it checks the token's signature against Google's public keys.
initializeApp({ projectId: process.env.PROJECT_ID });

const log = (fields) => console.log(JSON.stringify({ severity: 'INFO', ...fields }));

// One MongoDB client per instance, created on first use and reused by every later request
// (a new connection per request is the classic serverless mistake). Reset on failure so the next request retries.
let collectionPromise;
function likesCollection() {
  collectionPromise ??= (async () => {
    // Fail in 5 s instead of the driver's default 30 s: a slow "no" beats a hung request.
    const client = await new MongoClient(process.env.MONGODB_URI, { maxPoolSize: 5, serverSelectionTimeoutMS: 5000 }).connect();
    const col = client.db('station_stream').collection('likes');
    await col.createIndex({ uid: 1, episodeId: 1 }, { unique: true }); // one like per user per episode
    return col;
  })().catch((err) => {
    collectionPromise = undefined;
    throw err;
  });
  return collectionPromise;
}

functions.http('likes', async (req, res) => {
  // CORS: only the Firebase-hosted UI may read responses.
  const origin = req.get('Origin');
  if (origin && ALLOWED_ORIGINS.includes(origin)) {
    res.set('Access-Control-Allow-Origin', origin);
    res.set('Vary', 'Origin');
  }
  if (req.method === 'OPTIONS') {
    res.set('Access-Control-Allow-Methods', 'GET, POST');
    res.set('Access-Control-Allow-Headers', 'Authorization, Content-Type');
    res.set('Access-Control-Max-Age', '600');
    return res.status(204).send('');
  }

  // Who is calling? The token proves it; never trust a user ID sent in the body.
  const token = /^Bearer (.+)$/.exec(req.get('Authorization') ?? '')?.[1];
  if (!token) return res.status(401).json({ error: 'missing Authorization: Bearer <Firebase ID token>' });
  let uid;
  try {
    ({ uid } = await getAuth().verifyIdToken(token));
  } catch {
    return res.status(401).json({ error: 'invalid or expired token' });
  }

  try {
    return await handle(req, res, uid);
  } catch (err) {
    // Usually the database is unreachable (e.g. Atlas IP access list). Say so, with CORS headers intact.
    console.error(JSON.stringify({ severity: 'ERROR', msg: 'likes failed', error: err.message }));
    return res.status(503).json({ error: 'likes are temporarily unavailable' });
  }
});

async function handle(req, res, uid) {
  const likes = await likesCollection();

  if (req.method === 'GET') {
    const docs = await likes.find({ uid }).sort({ likedAt: -1 }).limit(500).toArray();
    return res.json({ likes: docs.map((d) => d.episodeId) });
  }

  if (req.method === 'POST') {
    const { episodeId, liked } = req.body ?? {};
    if (!EPISODE_ID.test(episodeId ?? '') || typeof liked !== 'boolean') {
      return res.status(400).json({ error: 'body must be { episodeId: string, liked: boolean }' });
    }
    if (liked) {
      // Upsert keeps it idempotent: liking twice is still one document.
      await likes.updateOne({ uid, episodeId }, { $setOnInsert: { uid, episodeId, likedAt: new Date() } }, { upsert: true });
    } else {
      await likes.deleteOne({ uid, episodeId });
    }
    log({ msg: 'like', uid, episodeId, liked });
    return res.json({ episodeId, liked });
  }

  res.set('Allow', 'GET, POST, OPTIONS');
  return res.status(405).json({ error: 'method not allowed' });
}
