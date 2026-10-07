export const typeDefs = `#graphql
  enum Availability {
    PUBLIC
    MEMBERS
    UNAVAILABLE
  }

  type Query {
    stations: [Station!]!
    station(slug: String!): Station
    show(slug: String!): Show
  }

  "A local station: its own branding and home screen over the shared catalog."
  type Station {
    slug: ID!
    callSign: String!
    name: String!
    tagline: String
    brandColor: String!
    "Visual theme the apps use: alpine | coastal"
    theme: String!
    homeRows: [HomeRow!]!
  }

  type HomeRow {
    title: String!
    shows: [Show!]!
  }

  type Franchise {
    id: ID!
    slug: String!
    title: String!
    shows: [Show!]!
  }

  type Show {
    id: ID!
    slug: String!
    title: String!
    description: String
    "Thumbnail from the first episode."
    imageUrl: String
    franchise: Franchise!
    seasons: [Season!]!
  }

  type Season {
    id: ID!
    number: Int!
    episodes: [Episode!]!
  }

  type Episode {
    id: ID!
    slug: String!
    title: String!
    number: Int!
    durationSeconds: Int!
    imageUrl: String
    assets: [Asset!]!
    "The full_length asset, if there is one."
    fullLength: Asset
  }

  type Asset {
    id: ID!
    title: String!
    objectType: String!
    durationSeconds: Int
    availability: Availability!
    "Only returned for PUBLIC assets; members-only video needs sign-in."
    hlsUrl: String
  }
`;

const isOpen = (window, now) =>
  !!window && new Date(window.start) <= now && (!window.end || now < new Date(window.end));

function availability(asset, now = new Date()) {
  const a = asset.availabilities ?? {};
  if (isOpen(a.public, now)) return 'PUBLIC';
  if (isOpen(a.all_members, now) || isOpen(a.station_members, now)) return 'MEMBERS';
  return 'UNAVAILABLE';
}

export function makeResolvers({ catalog, videoBaseUrl }) {
  const fullLength = (ep) => ep.assets.find((a) => a.object_type === 'full_length') ?? null;
  const episodeImage = (ep) => {
    const path = fullLength(ep)?.images?.[0]?.path;
    return path ? `${videoBaseUrl}/${path}` : null;
  };

  return {
    Query: {
      stations: () => catalog.stations,
      station: (_, { slug }) => catalog.stations.find((s) => s.slug === slug) ?? null,
      show: (_, { slug }) => catalog.showsBySlug.get(slug) ?? null,
    },
    HomeRow: {
      shows: (row) => row.shows.map((slug) => catalog.showsBySlug.get(slug)),
    },
    Show: {
      imageUrl: (show) => episodeImage(show.seasons[0].episodes[0]),
    },
    Episode: {
      fullLength,
      imageUrl: episodeImage,
    },
    Asset: {
      objectType: (a) => a.object_type,
      durationSeconds: (a) => a.duration,
      availability: (a) => availability(a),
      hlsUrl: (a) => {
        if (availability(a) !== 'PUBLIC') return null;
        const video = a.videos.find((v) => v.format === 'hls');
        return video ? `${videoBaseUrl}/${video.path}` : null;
      },
    },
  };
}
