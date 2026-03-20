// =============================================================================
// k6-load-test.js — Load test for multi-app-platform
//
// Usage:
//   k6 run test/k6-load-test.js
//   k6 run --vus 20 --duration 2m test/k6-load-test.js
//   k6 run --stage 0s:0,30s:10,1m:50,30s:0 test/k6-load-test.js
//
// Scenarios tested:
//   1. Health checks       — all 3 profiles
//   2. WAR health          — all 10 WAR endpoints
//   3. Intra-profile route — nexus → sentinel → carehub/scheduler
//   4. Cross-profile       — core → reporting, core → mobile
//   5. Full-chain          — end-to-end all 3 profiles
// =============================================================================

import http from 'k6/http';
import { check, sleep, group } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';

// -----------------------------------------------------------------------------
// Target configuration — update NODE_IP and ports if they change
// -----------------------------------------------------------------------------
const NODE_IP       = '52.91.155.184';
const CORE_PORT     = '30913';
const REPORTING_PORT = '31254';
const MOBILE_PORT   = '32401';

const CORE      = `http://${NODE_IP}:${CORE_PORT}`;
const REPORTING = `http://${NODE_IP}:${REPORTING_PORT}`;
const MOBILE    = `http://${NODE_IP}:${MOBILE_PORT}`;

// -----------------------------------------------------------------------------
// Custom metrics
// -----------------------------------------------------------------------------
const errorRate       = new Rate('error_rate');
const fullChainTrend  = new Trend('full_chain_duration_ms', true);
const crossProfileTrend = new Trend('cross_profile_duration_ms', true);
const intraRouteTrend = new Trend('intra_route_duration_ms', true);

// -----------------------------------------------------------------------------
// Load profile
// -----------------------------------------------------------------------------
export const options = {
  scenarios: {
    // Ramp up → sustained → ramp down
    load: {
      executor: 'ramping-vus',
      startVUs: 0,
      stages: [
        { duration: '30s', target: 10  },   // ramp up
        { duration: '1m',  target: 20  },   // sustained load
        { duration: '30s', target: 50  },   // spike
        { duration: '30s', target: 20  },   // recover
        { duration: '30s', target: 0   },   // ramp down
      ],
      gracefulRampDown: '10s',
    },
  },
  thresholds: {
    http_req_failed:          ['rate<0.01'],          // <1% errors
    http_req_duration:        ['p(95)<2000'],          // 95% under 2s
    full_chain_duration_ms:   ['p(95)<3000'],          // full-chain under 3s
    cross_profile_duration_ms:['p(95)<1500'],          // cross-profile under 1.5s
    intra_route_duration_ms:  ['p(95)<800'],           // intra-route under 800ms
    error_rate:               ['rate<0.01'],
  },
};

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------
const HEADERS = { headers: { 'Accept': 'application/json' } };

function ok(res, label) {
  const passed = check(res, {
    [`${label} status 200`]: (r) => r.status === 200,
    [`${label} has body`]:   (r) => r.body && r.body.length > 0,
  });
  errorRate.add(!passed);
  return passed;
}

// -----------------------------------------------------------------------------
// Main test function — each VU runs this in a loop
// -----------------------------------------------------------------------------
export default function () {

  // ── Group 1: Health checks ─────────────────────────────────────────────────
  group('1_health_checks', () => {
    ok(http.get(`${CORE}/healthz`,      HEADERS), 'core healthz');
    ok(http.get(`${REPORTING}/healthz`, HEADERS), 'reporting healthz');
    ok(http.get(`${MOBILE}/healthz`,    HEADERS), 'mobile healthz');
  });

  sleep(0.5);

  // ── Group 2: WAR health endpoints ─────────────────────────────────────────
  group('2_war_health', () => {
    ok(http.get(`${CORE}/nexus/health`,        HEADERS), 'core nexus health');
    ok(http.get(`${CORE}/sentinel/health`,     HEADERS), 'core sentinel health');
    ok(http.get(`${CORE}/carehub/health`,      HEADERS), 'core carehub health');
    ok(http.get(`${CORE}/scheduler/health`,    HEADERS), 'core scheduler health');
    ok(http.get(`${REPORTING}/nexus/health`,   HEADERS), 'reporting nexus health');
    ok(http.get(`${REPORTING}/sentinel/health`,HEADERS), 'reporting sentinel health');
    ok(http.get(`${REPORTING}/scheduler/health`,HEADERS),'reporting scheduler health');
    ok(http.get(`${MOBILE}/nexus/health`,      HEADERS), 'mobile nexus health');
    ok(http.get(`${MOBILE}/sentinel/health`,   HEADERS), 'mobile sentinel health');
    ok(http.get(`${MOBILE}/carehub/health`,    HEADERS), 'mobile carehub health');
  });

  sleep(0.5);

  // ── Group 3: Intra-profile routing ────────────────────────────────────────
  group('3_intra_profile_route', () => {
    let res;

    res = http.get(`${CORE}/nexus/route?target=carehub`, HEADERS);
    ok(res, 'core nexus→carehub');
    intraRouteTrend.add(res.timings.duration);

    res = http.get(`${CORE}/nexus/route?target=scheduler`, HEADERS);
    ok(res, 'core nexus→scheduler');
    intraRouteTrend.add(res.timings.duration);

    res = http.get(`${REPORTING}/nexus/route?target=scheduler`, HEADERS);
    ok(res, 'reporting nexus→scheduler');
    intraRouteTrend.add(res.timings.duration);

    res = http.get(`${MOBILE}/nexus/route?target=carehub`, HEADERS);
    ok(res, 'mobile nexus→carehub');
    intraRouteTrend.add(res.timings.duration);
  });

  sleep(0.5);

  // ── Group 4: Cross-profile routing ────────────────────────────────────────
  group('4_cross_profile', () => {
    let res;

    res = http.get(`${CORE}/nexus/cross-profile?to=reporting`, HEADERS);
    ok(res, 'core→reporting');
    crossProfileTrend.add(res.timings.duration);

    res = http.get(`${CORE}/nexus/cross-profile?to=mobile`, HEADERS);
    ok(res, 'core→mobile');
    crossProfileTrend.add(res.timings.duration);
  });

  sleep(0.5);

  // ── Group 5: Full-chain end-to-end ────────────────────────────────────────
  group('5_full_chain', () => {
    const res = http.get(`${CORE}/nexus/full-chain`, {
      ...HEADERS,
      timeout: '30s',
    });
    ok(res, 'full-chain');
    fullChainTrend.add(res.timings.duration);

    // Verify response structure
    check(res, {
      'full-chain has core section':      (r) => r.json('core') !== null,
      'full-chain has reporting section': (r) => r.json('reporting') !== null,
      'full-chain has mobile section':    (r) => r.json('mobile') !== null,
    });
  });

  sleep(1);
}

// -----------------------------------------------------------------------------
// Summary report printed at end of test
// -----------------------------------------------------------------------------
export function handleSummary(data) {
  return {
    stdout: JSON.stringify({
      total_requests:    data.metrics.http_reqs.values.count,
      error_rate:        data.metrics.http_req_failed.values.rate,
      p95_duration_ms:   data.metrics.http_req_duration.values['p(95)'],
      full_chain_p95_ms: data.metrics.full_chain_duration_ms
                           ? data.metrics.full_chain_duration_ms.values['p(95)']
                           : 'n/a',
      cross_profile_p95_ms: data.metrics.cross_profile_duration_ms
                              ? data.metrics.cross_profile_duration_ms.values['p(95)']
                              : 'n/a',
    }, null, 2),
  };
}
