// Load test for app 2's API (through its CloudFront HTTPS front door).
// Each virtual user (VU) behaves like a viewer opening a station's home screen: the same
// GraphQL "Home" query public/index.html sends, then ~1 s of "reading" before the next one.
//
//   PROFILE=baseline  10 VUs for 5 minutes: normal latency and what one task handles
//   PROFILE=spike     10 VUs -> 300 VUs in 30 s, hold 5 min, back to 10 (18 min total)
//
// Run (Docker, no install):
//   docker run --rm -i -e PROFILE=baseline -v "$PWD/loadtest:/scripts" grafana/k6:2.3.0 run /scripts/spike.js
//
// Only ever point this at our own endpoint.
import http from 'k6/http';
import { check, sleep } from 'k6';

const BASE = __ENV.API_BASE || 'https://d1436kyrcdypmk.cloudfront.net';
const PROFILE = __ENV.PROFILE || 'baseline';
const STATIONS = ['north', 'south'];

// Copied from public/index.html so the server does the same work a real page load causes.
const HOME = `query Home($slug: String!) {
  stations { slug name }
  station(slug: $slug) {
    callSign name tagline brandColor theme
    homeRows { title shows { title description franchise { title }
      seasons { number episodes { id title number durationSeconds imageUrl
        fullLength { availability hlsUrl } } } } }
  }
}`;

const profiles = {
  baseline: { executor: 'constant-vus', vus: 10, duration: '5m' },
  spike: {
    executor: 'ramping-vus',
    startVUs: 10,
    stages: [
      { duration: '2m', target: 10 },   // normal evening
      { duration: '30s', target: 300 }, // a pledge-drive premiere starts: 30x in 30 seconds
      { duration: '5m', target: 300 },  // hold
      { duration: '30s', target: 10 },  // back to normal
      { duration: '10m', target: 10 },  // watch the scale-in
    ],
    gracefulRampDown: '10s',
  },
};

export const options = {
  scenarios: { [PROFILE]: profiles[PROFILE] },
  // Pass/fail for the whole run: under 1% errors and 95% of Home loads under 800 ms.
  thresholds: {
    http_req_failed: ['rate<0.01'],
    'http_req_duration{name:Home}': ['p(95)<800'],
  },
  summaryTrendStats: ['avg', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  const slug = STATIONS[Math.floor(Math.random() * STATIONS.length)];
  const res = http.post(`${BASE}/graphql`, JSON.stringify({ query: HOME, variables: { slug } }), {
    headers: { 'content-type': 'application/json' },
    tags: { name: 'Home' },
    timeout: '10s',
  });
  check(res, {
    'Home 200': (r) => r.status === 200,
    'Home has data': (r) => r.status === 200 && r.json('data.station.name') !== undefined,
  });

  if (Math.random() < 0.1) {
    const h = http.get(`${BASE}/health`, { tags: { name: 'health' }, timeout: '10s' });
    check(h, { 'health 200': (r) => r.status === 200 });
  }

  sleep(1);
}
