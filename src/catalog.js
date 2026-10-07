// Loads the Media Manager-shaped JSON once at startup and flattens it into
// plain objects with parent links, so resolvers can look things up by slug.
import { readFileSync } from 'node:fs';

const readJson = (rel) => JSON.parse(readFileSync(new URL(rel, import.meta.url), 'utf8'));

export function loadCatalog() {
  const raw = readJson('../data/catalog.json');
  const stations = readJson('../data/stations.json');

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

  // Fail fast at startup if a station points at a show that doesn't exist.
  for (const st of stations) {
    for (const row of st.homeRows) {
      for (const slug of row.shows) {
        if (!showsBySlug.has(slug)) throw new Error(`Station ${st.slug} row "${row.title}" references unknown show "${slug}"`);
      }
    }
  }

  return { franchises, showsBySlug, stations };
}
