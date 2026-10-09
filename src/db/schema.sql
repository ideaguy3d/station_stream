-- The catalog as relational tables. Idempotent: safe to run on every deploy.
-- Text primary keys on purpose: the catalog already has stable ids like 'sh-code-lab'.
-- `position` columns keep the order the JSON had (the API relies on "first season, first episode").

CREATE TABLE IF NOT EXISTS franchises (
  id    text PRIMARY KEY,
  slug  text NOT NULL UNIQUE,
  title text NOT NULL,
  position int NOT NULL
);

CREATE TABLE IF NOT EXISTS shows (
  id           text PRIMARY KEY,
  slug         text NOT NULL UNIQUE,
  title        text NOT NULL,
  description  text,
  franchise_id text NOT NULL REFERENCES franchises (id) ON DELETE CASCADE,
  position     int NOT NULL
);

CREATE TABLE IF NOT EXISTS seasons (
  id       text PRIMARY KEY,
  show_id  text NOT NULL REFERENCES shows (id) ON DELETE CASCADE,
  number   int NOT NULL,
  position int NOT NULL
);

CREATE TABLE IF NOT EXISTS episodes (
  id               text PRIMARY KEY,
  season_id        text NOT NULL REFERENCES seasons (id) ON DELETE CASCADE,
  slug             text NOT NULL,
  title            text NOT NULL,
  number           int NOT NULL,
  duration_seconds int NOT NULL,
  position         int NOT NULL
);

-- Assets keep their flexible bits as JSONB: availability windows, image and video renditions
-- vary by asset type, which is exactly what a document column is for.
CREATE TABLE IF NOT EXISTS assets (
  id             text PRIMARY KEY,
  episode_id     text NOT NULL REFERENCES episodes (id) ON DELETE CASCADE,
  title          text NOT NULL,
  object_type    text NOT NULL,
  duration       int,
  availabilities jsonb NOT NULL DEFAULT '{}',
  images         jsonb NOT NULL DEFAULT '[]',
  videos         jsonb NOT NULL DEFAULT '[]',
  position       int NOT NULL
);

CREATE TABLE IF NOT EXISTS stations (
  slug        text PRIMARY KEY,
  call_sign   text NOT NULL,
  name        text NOT NULL,
  tagline     text,
  brand_color text NOT NULL,
  theme       text NOT NULL,
  position    int NOT NULL
);

-- A station's home screen: ordered rows, each an ordered list of shows.
CREATE TABLE IF NOT EXISTS home_rows (
  station_slug text NOT NULL REFERENCES stations (slug) ON DELETE CASCADE,
  position     int NOT NULL,
  title        text NOT NULL,
  PRIMARY KEY (station_slug, position)
);

CREATE TABLE IF NOT EXISTS home_row_shows (
  station_slug text NOT NULL,
  row_position int NOT NULL,
  position     int NOT NULL,
  show_slug    text NOT NULL REFERENCES shows (slug) ON DELETE CASCADE,
  PRIMARY KEY (station_slug, row_position, position),
  FOREIGN KEY (station_slug, row_position) REFERENCES home_rows (station_slug, position) ON DELETE CASCADE
);

-- Foreign keys don't create indexes on the child side; these make parent lookups and cascades cheap.
CREATE INDEX IF NOT EXISTS shows_franchise_idx   ON shows (franchise_id);
CREATE INDEX IF NOT EXISTS seasons_show_idx      ON seasons (show_id);
CREATE INDEX IF NOT EXISTS episodes_season_idx   ON episodes (season_id);
CREATE INDEX IF NOT EXISTS assets_episode_idx    ON assets (episode_id);
