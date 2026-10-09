// Builds the in-memory catalog the resolvers read: flat objects with parent links, so
// resolvers can look things up by slug. The source is Aurora (when PGHOST is set) or the
// Media Manager-shaped JSON files baked into the image (local dev, app 1, and boot fallback).
import { readFileSync } from 'node:fs';

const readJson = (rel) => JSON.parse(readFileSync(new URL(rel, import.meta.url), 'utf8'));

function buildCatalog(raw, stations) {
  const franchises = [];
  const showsBySlug = new Map();

  for (const fr of raw.franchises) {
    const franchise = { id: fr.id, ...fr.attributes, shows: [] };
    franchises.push(franchise);

    for (const sh of fr.shows) {
      const show = {
        id: sh.id,
        slug: sh.attributes.slug,
        title: sh.attributes.title,
        description: sh.attributes.description_short,
        franchise,
        seasons: sh.seasons.map((se) => ({
          id: se.id,
          number: se.attributes.ordinal,
          episodes: se.episodes.map((ep) => ({
            id: ep.id,
            slug: ep.attributes.slug,
            title: ep.attributes.title,
            number: ep.attributes.ordinal,
            durationSeconds: ep.attributes.duration,
            assets: ep.assets.map((as) => ({ id: as.id, ...as.attributes })),
          })),
        })),
      };
      franchise.shows.push(show);
      showsBySlug.set(show.slug, show);
    }
  }

  // Fail fast if a station points at a show that doesn't exist.
  for (const st of stations) {
    for (const row of st.homeRows) {
      for (const slug of row.shows) {
        if (!showsBySlug.has(slug)) throw new Error(`Station ${st.slug} row "${row.title}" references unknown show "${slug}"`);
      }
    }
  }

  return { franchises, showsBySlug, stations };
}

export function loadCatalog() {
  return buildCatalog(readJson('../data/catalog.json'), readJson('../data/stations.json'));
}

// Reads the tables and rebuilds the same raw shape the JSON files have, then reuses
// buildCatalog, so both sources produce an identical object. One REPEATABLE READ
// transaction means all eight queries see the same snapshot, even mid-migration.
export async function loadCatalogFromDb(pool) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY');
    const q = async (sql) => (await client.query(sql)).rows;
    const [franchises, shows, seasons, episodes, assets, stations, rows, rowShows] = [
      await q('SELECT * FROM franchises ORDER BY position'),
      await q('SELECT * FROM shows ORDER BY position'),
      await q('SELECT * FROM seasons ORDER BY position'),
      await q('SELECT * FROM episodes ORDER BY position'),
      await q('SELECT * FROM assets ORDER BY position'),
      await q('SELECT * FROM stations ORDER BY position'),
      await q('SELECT * FROM home_rows ORDER BY station_slug, position'),
      await q('SELECT * FROM home_row_shows ORDER BY station_slug, row_position, position'),
    ];
    await client.query('COMMIT');

    // Group children under their parent id once, instead of filtering per parent.
    const groupBy = (list, key) => {
      const m = new Map();
      for (const item of list) (m.get(item[key]) ?? m.set(item[key], []).get(item[key])).push(item);
      return m;
    };
    const showsByFranchise = groupBy(shows, 'franchise_id');
    const seasonsByShow = groupBy(seasons, 'show_id');
    const episodesBySeason = groupBy(episodes, 'season_id');
    const assetsByEpisode = groupBy(assets, 'episode_id');
    const rowsByStation = groupBy(rows, 'station_slug');
    const showsByRow = groupBy(rowShows, 'station_slug');

    const raw = {
      franchises: franchises.map((fr) => ({
        id: fr.id,
        attributes: { title: fr.title, slug: fr.slug },
        shows: (showsByFranchise.get(fr.id) ?? []).map((sh) => ({
          id: sh.id,
          attributes: { title: sh.title, slug: sh.slug, description_short: sh.description },
          seasons: (seasonsByShow.get(sh.id) ?? []).map((se) => ({
            id: se.id,
            attributes: { ordinal: se.number },
            episodes: (episodesBySeason.get(se.id) ?? []).map((ep) => ({
              id: ep.id,
              attributes: { slug: ep.slug, title: ep.title, ordinal: ep.number, duration: ep.duration_seconds },
              assets: (assetsByEpisode.get(ep.id) ?? []).map((as) => ({
                id: as.id,
                attributes: {
                  title: as.title,
                  object_type: as.object_type,
                  duration: as.duration,
                  availabilities: as.availabilities,
                  images: as.images,
                  videos: as.videos,
                },
              })),
            })),
          })),
        })),
      })),
    };

    const stationObjects = stations.map((st) => ({
      slug: st.slug,
      callSign: st.call_sign,
      name: st.name,
      tagline: st.tagline,
      brandColor: st.brand_color,
      theme: st.theme,
      homeRows: (rowsByStation.get(st.slug) ?? []).map((row) => ({
        title: row.title,
        shows: (showsByRow.get(st.slug) ?? []).filter((rs) => rs.row_position === row.position).map((rs) => rs.show_slug),
      })),
    }));

    return buildCatalog(raw, stationObjects);
  } catch (err) {
    await client.query('ROLLBACK').catch(() => {});
    throw err;
  } finally {
    client.release();
  }
}

// What the resolvers actually hold. It exposes `stations` and `showsBySlug` as getters over
// the current snapshot, so a refresh swaps the data without touching the resolvers.
//
// Strategy (stale-while-revalidate): always answer from memory. If the copy is older than
// ttlMs, refresh in the background. The catalog changes rarely, so database load doesn't
// depend on viewer count, and with no traffic there are no queries and Aurora can pause.
// If the database is down or waking up, keep serving the last good copy.
export function createCatalogStore({ pool, ttlMs = 60_000, cacheOff = false, log = () => {} }) {
  let current = loadCatalog(); // bundled JSON: instant, and the fallback if Aurora is unreachable
  let source = 'json';
  let loadedAt = Date.now();
  let inflight = null;
  let lastError = null;

  const install = (catalog) => {
    current = catalog;
    source = 'aurora';
    loadedAt = Date.now();
    lastError = null;
  };

  const fail = (err) => {
    // Connection errors (ECONNREFUSED, timeouts) can arrive with an empty message, so fall back to the code.
    lastError = err.message || err.code || err.name || 'unknown error';
    log({ msg: 'catalog refresh failed, serving last good copy', source, error: lastError });
  };

  // Single-flight: concurrent callers share one query instead of stampeding the database.
  const refresh = () => {
    if (!pool) return Promise.resolve();
    inflight ??= loadCatalogFromDb(pool)
      .then(install, fail)
      .finally(() => { inflight = null; });
    return inflight;
  };

  return {
    get stations() { return current.stations; },
    get showsBySlug() { return current.showsBySlug; },
    get source() { return source; },
    get ageSeconds() { return Math.round((Date.now() - loadedAt) / 1000); },
    get lastError() { return lastError; },
    refresh,
    // Called on each GraphQL request. Normally returns immediately; with CATALOG_CACHE=off
    // every request queries the database itself (load-test mode).
    async touch() {
      if (!pool) return;
      if (cacheOff) {
        await loadCatalogFromDb(pool).then(install, fail);
      } else if (Date.now() - loadedAt > ttlMs) {
        refresh(); // not awaited on purpose
      }
    },
  };
}
