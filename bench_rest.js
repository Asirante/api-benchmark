import http from 'k6/http';
import { check, group, sleep } from 'k6';
// maxVUs는 쉘 스크립트에서 넘겨준 값 (스파이크일 때는 MAX_VU * 2 값)
const parsedVUs = parseInt(__ENV.VUS);
const maxVUs = isNaN(parsedVUs) ? 1000 : parsedVUs;

// 1. 일반 부하 (Standard / Proxy) 스테이지
const standardStages = [
  { duration: '10s', target: Math.floor(maxVUs / 2) },
  { duration: '10s', target: maxVUs },
  { duration: '30s', target: maxVUs },
  { duration: '10s', target: 0 },
];

// 2. 동적 스파이크 스테이지 (들어온 최대 부하를 기준으로 비율 자동 계산)
const spikeBase = Math.max(Math.floor(maxVUs * 0.1), 10); // 10% (안정화 구간)
const spikeMid = Math.max(Math.floor(maxVUs * 0.4), 50);  // 40% (1차 스파이크)
const spikeMax = maxVUs;                                  // 100% (2차 극한 스파이크)

const spikeStages = [
  { duration: '10s', target: spikeBase },  // 1. 정상 부하 (Warm-up)
  { duration: '5s',  target: spikeMid },   // 2. 1차 스파이크
  { duration: '15s', target: spikeMid },   // 3. 1차 스파이크 유지
  { duration: '5s',  target: spikeBase },  // 4. 1차 회복
  { duration: '10s', target: spikeBase },  // 5. 안정화 대기
  { duration: '5s',  target: spikeMax },   // 6. 2차 극한 스파이크 (최대치)
  { duration: '15s', target: spikeMax },   // 7. 시스템 임계점 타격
  { duration: '15s', target: 0 },          // 8. 완전 회수
];

export const options = {
  setupTimeout: '2m',
  stages: __ENV.TEST_MODE === 'spike' ? spikeStages : standardStages,
};

export default function () {
  const validId = 'e481f51cbdc54678b7cc49136f2d6af7';
  const invalidId = 'fake_invalid_id_9999';
  const customerId = '06b8999e2fba1a1fbc88172c00ba8bc7';

  group('TC1: Simple Read', function () {
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${validId}`, { tags: { tc: 'tc1', api: 'rest' } });
    check(res, { 'TC1 REST OK': (r) => r.status === 200 });
  });

  group('TC2: Paging', function () {
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders?limit=50&offset=0`, { tags: { tc: 'tc2', api: 'rest' } });
    check(res, { 'TC2 REST OK': (r) => r.status === 200 });
  });

  group('TC3: Under-fetching', function () {
    http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${validId}`, { tags: { tc: 'tc3', api: 'rest_part1' } });
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders/${validId}/items`, { tags: { tc: 'tc3', api: 'rest_part2' } });
    check(res, { 'TC3 REST N+1 OK': (r) => r.status === 200 });
  });

  group('TC4: Partial Field', function () {
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders/details/${validId}`, { tags: { tc: 'tc4', api: 'rest' } });
    check(res, { 'TC4 REST OK': (r) => r.status === 200 });
  });

  group('TC5: Full Heavy Join', function () {
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders/details/${validId}`, { tags: { tc: 'tc5', api: 'rest' } });
    check(res, { 'TC5 REST OK': (r) => r.status === 200 });
  });

  group('TC6: Write Transaction', function () {
    const payload = JSON.stringify({ customer_id: customerId, status: "created" });
    const res = http.post('http://benchmark_rest:8080/api/v1/orders', payload, { headers: { 'Content-Type': 'application/json' }, tags: { tc: 'tc6', api: 'rest' } });
    check(res, { 'TC6 REST OK': (r) => r.status === 201 || r.status === 200 });
  });

  group('TC7: Error Handling', function () {
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${invalidId}`, { tags: { tc: 'tc7', api: 'rest_error' } });
    check(res, { 'TC7 REST Error': (r) => r.status !== 200 });
  });

  sleep(1);
}