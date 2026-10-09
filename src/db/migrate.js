// One-off job: create the tables, load the catalog JSON into them, and create the read-only
// role the API uses. Idempotent, so running it twice changes nothing.
//
// Runs as an ECS task (the database is private, so a laptop can't reach it) with the ADMIN
// credentials injected from the RDS-managed secret. The API itself never sees them.
import { readFileSync } from 'node:fs';
import { setTimeout as sleep } from 'node:timers/promises';
import { createPool } from './pool.js';

const readText = (rel) => readFileSync(new URL(rel, import.meta.url), 'utf8');
const readJson = (rel) => JSON.parse(readText(rel));
const log = (fields) => console.log(JSON.stringify({ ts: new Date().toISOString(), ...fields }));

const API_ROLE = 'api_reader';

// A paused Aurora cluster refuses or times out the first connections while it resumes.
async function connectWithRetry(pool, attempts = 8) {
  for (let i = 1; ; i++) {
    try {
      return await pool.connect();
    } catch (err) {
      if (i >= attempts) throw err;
      log({ msg: 'database not ready, retrying', attempt: i, error: err.message });
      await sleep(5000);
    }
  }
}

async function seed(client) {
  const raw = readJson('../../data/catalog.json');
  const stations = readJson('../../data/stations.json');

  let fi = 0;
  for (const fr of raw.franchises) {
    await client.query(
      `INSERT INTO franchises (id, slug, title, position) VALUES ($1,$2,$3,$4)
       ON CONFLICT (id) DO UPDATE SET slug = EXCLUDED.slug, title = EXCLUDED.title, position = EXCLUDED.position`,
      [fr.id, fr.attributes.slug, fr.attributes.title, fi++],
    );
    let shi = 0;
    for (const sh of fr.shows) {
      await client.query(
        `INSERT INTO shows (id, slug, title, description, franchise_id, position) VALUES ($1,$2,$3,$4,$5,$6)
         ON CONFLICT (id) DO UPDATE SET slug = EXCLUDED.slug, title = EXCLUDED.title,
           description = EXCLUDED.description, franchise_id = EXCLUDED.franchise_id, position = EXCLUDED.position`,
        [sh.id, sh.attributes.slug, sh.attributes.title, sh.attributes.description_short ?? null, fr.id, shi++],
      );
      let sei = 0;
      for (const se of sh.seasons) {
        await client.query(
          `INSERT INTO seasons (id, show_id, number, position) VALUES ($1,$2,$3,$4)
           ON CONFLICT (id) DO UPDATE SET show_id = EXCLUDED.show_id, number = EXCLUDED.number, position = EXCLUDED.position`,
          [se.id, sh.id, se.attributes.ordinal, sei++],
        );
        let epi = 0;
        for (const ep of se.episodes) {
          await client.query(
            `INSERT INTO episodes (id, season_id, slug, title, number, duration_seconds, position) VALUES ($1,$2,$3,$4,$5,$6,$7)
             ON CONFLICT (id) DO UPDATE SET season_id = EXCLUDED.season_id, slug = EXCLUDED.slug, title = EXCLUDED.title,
               number = EXCLUDED.number, duration_seconds = EXCLUDED.duration_seconds, position = EXCLUDED.position`,
            [ep.id, se.id, ep.attributes.slug, ep.attributes.title, ep.attributes.ordinal, ep.attributes.duration, epi++],
          );
          let asi = 0;
          for (const as of ep.assets) {
            const a = as.attributes;
            await client.query(
              `INSERT INTO assets (id, episode_id, title, object_type, duration, availabilities, images, videos, position)
               VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)
               ON CONFLICT (id) DO UPDATE SET episode_id = EXCLUDED.episode_id, title = EXCLUDED.title,
                 object_type = EXCLUDED.object_type, duration = EXCLUDED.duration, availabilities = EXCLUDED.availabilities,
                 images = EXCLUDED.images, videos = EXCLUDED.videos, position = EXCLUDED.position`,
              [as.id, ep.id, a.title, a.object_type, a.duration ?? null,
                JSON.stringify(a.availabilities ?? {}), JSON.stringify(a.images ?? []), JSON.stringify(a.videos ?? []), asi++],
            );
          }
        }
      }
    }
  }

  let sti = 0;
  for (const st of stations) {
    await client.query(
      `INSERT INTO stations (slug, call_sign, name, tagline, brand_color, theme, position) VALUES ($1,$2,$3,$4,$5,$6,$7)
       ON CONFLICT (slug) DO UPDATE SET call_sign = EXCLUDED.call_sign, name = EXCLUDED.name, tagline = EXCLUDED.tagline,
         brand_color = EXCLUDED.brand_color, theme = EXCLUDED.theme, position = EXCLUDED.position`,
      [st.slug, st.callSign, st.name, st.tagline ?? null, st.brandColor, st.theme, sti++],
    );
    // Home rows are small and owned by the station: replace them wholesale (cascades to home_row_shows).
    await client.query('DELETE FROM home_rows WHERE station_slug = $1', [st.slug]);
    let ri = 0;
    for (const row of st.homeRows) {
      await client.query('INSERT INTO home_rows (station_slug, position, title) VALUES ($1,$2,$3)', [st.slug, ri, row.title]);
      let si = 0;
      for (const showSlug of row.shows) {
        await client.query(
          'INSERT INTO home_row_shows (station_slug, row_position, position, show_slug) VALUES ($1,$2,$3,$4)',
          [st.slug, ri, si++, showSlug],
        );
      }
      ri++;
    }
  }
}

// The API's database user: can read the catalog, can't change anything.
async function ensureReaderRole(client, password) {
  const exists = await client.query('SELECT 1 FROM pg_roles WHERE rolname = $1', [API_ROLE]);
  // CREATE/ALTER ROLE can't take bind parameters, so the password is escaped as a literal.
  const pw = client.escapeLiteral(password);
  await client.query(exists.rowCount ? `ALTER ROLE ${API_ROLE} WITH LOGIN PASSWORD ${pw}` : `CREATE ROLE ${API_ROLE} WITH LOGIN PASSWORD ${pw}`);
  await client.query(`GRANT USAGE ON SCHEMA public TO ${API_ROLE}`);
  await client.query(`GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${API_ROLE}`);
  // Tables added by later migrations are readable too, without re-running grants by hand.
  await client.query(`ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO ${API_ROLE}`);
}

const pool = createPool({ max: 1 });
const client = await connectWithRetry(pool);
try {
  await client.query('BEGIN');
  await client.query(readText('./schema.sql'));
  await seed(client);
  const readerPassword = process.env.API_READER_PASSWORD;
  if (readerPassword) await ensureReaderRole(client, readerPassword);
  else log({ msg: 'API_READER_PASSWORD not set, skipping role setup' });
  await client.query('COMMIT');

  const counts = {};
  for (const t of ['franchises', 'shows', 'seasons', 'episodes', 'assets', 'stations', 'home_rows', 'home_row_shows']) {
    counts[t] = Number((await client.query(`SELECT count(*) FROM ${t}`)).rows[0].count);
  }
  log({ msg: 'migration complete', counts });
} catch (err) {
  await client.query('ROLLBACK').catch(() => {});
  log({ msg: 'migration failed', error: err.message });
  process.exitCode = 1;
} finally {
  client.release();
  await pool.end();
}
