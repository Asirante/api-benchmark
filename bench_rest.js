import http from 'k6/http';
import { check, group, sleep } from 'k6';

// ============================================================
// bench_rest.js — REST API 격리 벤치마크 (TC1~TC7)
// 다른 프로토콜 서버와의 상호 간섭(Noisy Neighbor)을 제거하기 위해
// REST 호출만 단독으로 실행합니다.
// ============================================================

const maxVUs = __ENV.VUS ? parseInt(__ENV.VUS) : 1000;

export const options = {
  setupTimeout: '1m',
  stages: [
    { duration: '10s', target: Math.floor(maxVUs / 2) },
    { duration: '10s', target: maxVUs },
    { duration: '30s', target: maxVUs },
    { duration: '10s', target: 0 },
  ],
};

export default function () {
  const validId = 'e481f51cbdc54678b7cc49136f2d6af7';
  const invalidId = 'fake_invalid_id_9999';
  const customerId = '06b8999e2fba1a1fbc88172c00ba8bc7';

  // [TC 1] 단건 조회
  group('TC1: Simple Read', function () {
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${validId}`, { tags: { tc: 'tc1', api: 'rest' } });
    check(res, { 'TC1 REST OK': (r) => r.status === 200 });
  });

  // [TC 2] 페이징 조회
  group('TC2: Paging', function () {
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders?limit=50&offset=0`, { tags: { tc: 'tc2', api: 'rest' } });
    check(res, { 'TC2 REST OK': (r) => r.status === 200 });
  });

  // [TC 3] 다중 호출 (Under-fetching)
  group('TC3: Under-fetching', function () {
    http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${validId}`, { tags: { tc: 'tc3', api: 'rest_part1' } });
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders/${validId}/items`, { tags: { tc: 'tc3', api: 'rest_part2' } });
    check(res, { 'TC3 REST N+1 OK': (r) => r.status === 200 });
  });

  // [TC 4] 부분 필드 추출 (Over-fetching)
  group('TC4: Partial Field', function () {
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders/details/${validId}`, { tags: { tc: 'tc4', api: 'rest' } });
    check(res, { 'TC4 REST OK': (r) => r.status === 200 });
  });

  // [TC 5] 다중 테이블 조인
  group('TC5: Full Heavy Join', function () {
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders/details/${validId}`, { tags: { tc: 'tc5', api: 'rest' } });
    check(res, { 'TC5 REST OK': (r) => r.status === 200 });
  });

  // [TC 6] 트랜잭션 쓰기
  group('TC6: Write Transaction', function () {
    const payload = JSON.stringify({ customer_id: customerId, status: "created" });
    const res = http.post('http://benchmark_rest:8080/api/v1/orders', payload, { headers: { 'Content-Type': 'application/json' }, tags: { tc: 'tc6', api: 'rest' } });
    check(res, { 'TC6 REST OK': (r) => r.status === 201 || r.status === 200 });
  });

  // [TC 7] 예외 처리
  group('TC7: Error Handling', function () {
    const res = http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${invalidId}`, { tags: { tc: 'tc7', api: 'rest_error' } });
    check(res, { 'TC7 REST Error': (r) => r.status !== 200 });
  });

  sleep(1);
}
