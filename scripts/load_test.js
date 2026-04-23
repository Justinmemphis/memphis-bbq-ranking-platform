/**
 * k6 load test — Memphis BBQ Ranking Platform (prod)
 *
 * Usage:
 *   export API_BASE="https://6iq57bhwj5.execute-api.us-east-1.amazonaws.com"
 *   export JWT_TOKEN="<cognito id_token for a test user>"
 *   k6 run scripts/load_test.js
 *
 * Getting a JWT token (one-time, paste into shell):
 *   aws cognito-idp initiate-auth \
 *     --auth-flow USER_PASSWORD_AUTH \
 *     --client-id vssng3nfpfebn7snjuj4q044j \
 *     --auth-parameters USERNAME=<email>,PASSWORD=<password> \
 *     --query 'AuthenticationResult.IdToken' --output text
 *
 * Before running:
 *   aws cloudwatch disable-alarm-actions \
 *     --alarm-names bbq-prod-submit-rating-spike
 *
 * After running:
 *   aws cloudwatch enable-alarm-actions \
 *     --alarm-names bbq-prod-submit-rating-spike
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Rate, Trend } from "k6/metrics";

const errorRate = new Rate("errors");
const postLatency = new Trend("post_ratings_latency", true);

export const options = {
  stages: [
    { duration: "2m", target: 50 },  // ramp to 50 VUs
    { duration: "5m", target: 100 }, // hold at 100 VUs (GET-heavy load)
    { duration: "2m", target: 0 },   // ramp down
  ],
  thresholds: {
    // SLO: p99 latency < 500ms, error rate < 1%
    http_req_duration: ["p(99)<500"],
    errors: ["rate<0.01"],
  },
};

const BASE = __ENV.API_BASE || "https://6iq57bhwj5.execute-api.us-east-1.amazonaws.com";
const TOKEN = (__ENV.JWT_TOKEN || "").trim();

const AUTH_HEADERS = {
  headers: {
    Authorization: `Bearer ${TOKEN}`,
    "Content-Type": "application/json",
  },
};

const RESTAURANT_IDS = [
  "cozy-corner",
  "bar-b-q-shop",
  "paynes-bar-b-que",
  "central-bbq-downtown",
  "germantown-commissary",
];

function randomRestaurantId() {
  return RESTAURANT_IDS[Math.floor(Math.random() * RESTAURANT_IDS.length)];
}

function randomRating() {
  return Math.floor(Math.random() * 5) + 1;
}

export default function () {
  // Traffic mix: 70% GET /restaurants, 20% GET /leaderboard, 10% POST /ratings
  // Keeps DynamoDB Scan costs manageable (see cost estimate).
  const roll = Math.random();

  if (roll < 0.70) {
    const res = http.get(`${BASE}/v1/restaurants`, AUTH_HEADERS);
    check(res, { "restaurants 200": (r) => r.status === 200 });
    errorRate.add(res.status !== 200);
  } else if (roll < 0.90) {
    const res = http.get(`${BASE}/v1/leaderboard`, AUTH_HEADERS);
    check(res, { "leaderboard 200": (r) => r.status === 200 });
    errorRate.add(res.status !== 200);
  } else {
    // POST /v1/ratings — authenticated write (10% of traffic)
    if (!TOKEN) {
      errorRate.add(true);
      return;
    }
    const payload = JSON.stringify({
      restaurant_id: randomRestaurantId(),
      score: randomRating(),
    });
    const res = http.post(`${BASE}/v1/ratings`, payload, AUTH_HEADERS);
    check(res, { "ratings 200": (r) => r.status === 200 });
    errorRate.add(res.status !== 200);
    postLatency.add(res.timings.duration);
  }

  sleep(1);
}
