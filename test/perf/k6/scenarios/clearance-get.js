import http from 'k6/http';
import { check } from 'k6';
import {
  BASE_URL,
  defaultHeaders,
  defaultOptions,
  writeSummary,
} from '../lib/common.js';

// Hot path: valid challenge-clearance cookie → pass through to backend (200).
// CLEARANCE_COOKIE is minted by run-k6.sh for the k6 peer IP (127.0.0.1 when
// sharing the Envoy network namespace).
const CLEARANCE = __ENV.CLEARANCE_COOKIE || '';

export const options = defaultOptions('clearance_get');

export default function () {
  const headers = Object.assign({}, defaultHeaders, {
    Cookie: `challenge-clearance=${CLEARANCE}`,
  });
  const res = http.get(`${BASE_URL}/`, { headers });
  check(res, {
    'status is 200': (r) => r.status === 200,
    'clearance configured': () => CLEARANCE.length > 0,
  });
}

export function handleSummary(data) {
  return writeSummary(data, { expected_status: 200 });
}
