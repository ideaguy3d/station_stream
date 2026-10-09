// Connection settings shared by the API and the migration task.
// `pg` reads PGHOST / PGPORT / PGUSER / PGPASSWORD / PGDATABASE from the environment itself,
// so the only thing decided here is "is there a database at all" and TLS.
import pg from 'pg';

// No PGHOST = local dev or app 1: the API falls back to the bundled JSON catalog.
export const dbConfigured = () => Boolean(process.env.PGHOST);

export function createPool(overrides = {}) {
  const pool = new pg.Pool({
    // Encrypt in transit. rejectUnauthorized:false skips CA verification (traffic still can't be
    // read); the stricter step is shipping the RDS CA bundle and using verify-full.
    ssl: process.env.PGSSL === 'off' ? false : { rejectUnauthorized: false },
    max: 10,
    // Close idle connections quickly: an open connection keeps Aurora from auto-pausing.
    idleTimeoutMillis: 30_000,
    // A paused Aurora cluster takes ~15 s to resume on the first connection, so wait for it.
    connectionTimeoutMillis: 30_000,
    ...overrides,
  });
  // An idle client can error if the database restarts or pauses. Without this listener
  // Node would treat it as an uncaught exception and kill the process.
  pool.on('error', (err) => console.error(JSON.stringify({ msg: 'pg pool error', error: err.message })));
  return pool;
}
