import http from 'k6/http';
import { check } from 'k6';
import {
  BASE_URL,
  defaultHeaders,
  defaultOptions,
  writeSummary,
} from '../lib/common.js';

// Measures challenge-issue path: every request is unauthenticated → 403 + HTML.
// http_req_failed treats 4xx as failed by default; mark 403 as expected success.
export const options = defaultOptions('challenge_issue', {
  http_req_failed: ['rate<0.01'],
});

export default function () {
  const res = http.get(`${BASE_URL}/`, {
    headers: defaultHeaders,
    // 403 is the success status for this scenario
    responseCallback: http.expectedStatuses(403),
  });
  check(res, {
    'status is 403': (r) => r.status === 403,
    'has challenge body': (r) =>
      r.body && (r.body.includes('challenge') || r.body.includes('SHA') || r.body.length > 100),
    'sets challenge cookie': (r) => {
      const sc = r.headers['Set-Cookie'] || r.headers['set-cookie'] || '';
      const joined = Array.isArray(sc) ? sc.join(';') : String(sc);
      return joined.includes('challenge=');
    },
  });
}

export function handleSummary(data) {
  return writeSummary(data, { expected_status: 403 });
}
