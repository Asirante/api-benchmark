import http from 'k6/http';
import { check, group, sleep } from 'k6';

// ============================================================
// bench_gql.js — GraphQL API 격리 벤치마크 (TC1~TC7)
// 다른 프로토콜 서버와의 상호 간섭(Noisy Neighbor)을 제거하기 위해
// GraphQL 호출만 단독으로 실행합니다.
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
  const gqlHeaders = { 'Content-Type': 'application/json' };

  // [TC 1] 단건 조회
  group('TC1: Simple Read', function () {
    const payload = JSON.stringify({ query: `query { getSimpleOrder(id: "${validId}") { order_id order_status } }` });
    const res = http.post('http://benchmark_graphql:8081/query', payload, { headers: gqlHeaders, tags: { tc: 'tc1', api: 'graphql' } });
    check(res, { 'TC1 GQL OK': (r) => r.status === 200 && r.json().errors === undefined });
  });

  // [TC 2] 페이징 조회
  group('TC2: Paging', function () {
    const payload = JSON.stringify({ query: `query { getOrders(limit: 50, offset: 0) { order_id } }` });
    const res = http.post('http://benchmark_graphql:8081/query', payload, { headers: gqlHeaders, tags: { tc: 'tc2', api: 'graphql' } });
    check(res, { 'TC2 GQL OK': (r) => r.status === 200 && r.json().errors === undefined });
  });

  // [TC 3] 다중 호출 (Under-fetching) — GraphQL은 1회 쿼리로 해결
  group('TC3: Under-fetching', function () {
    const payload = JSON.stringify({ query: `query { getOrderDetails(id: "${validId}") { order_id items { product_id } } }` });
    const res = http.post('http://benchmark_graphql:8081/query', payload, { headers: gqlHeaders, tags: { tc: 'tc3', api: 'graphql' } });
    check(res, { 'TC3 GQL OK': (r) => r.status === 200 && r.json().errors === undefined });
  });

  // [TC 4] 부분 필드 추출 (Over-fetching)
  group('TC4: Partial Field', function () {
    const payload = JSON.stringify({ query: `query { getOrderDetails(id: "${validId}") { order_status customer { customer_city } } }` });
    const res = http.post('http://benchmark_graphql:8081/query', payload, { headers: gqlHeaders, tags: { tc: 'tc4', api: 'graphql' } });
    check(res, { 'TC4 GQL OK': (r) => r.status === 200 && r.json().errors === undefined });
  });

  // [TC 5] 다중 테이블 조인
  group('TC5: Full Heavy Join', function () {
    const payload = JSON.stringify({
      query: `query { getOrderDetails(id: "${validId}") { order_id order_status items { product_id price product_name } customer { customer_city customer_state } } }`
    });
    const res = http.post('http://benchmark_graphql:8081/query', payload, { headers: gqlHeaders, tags: { tc: 'tc5', api: 'graphql' } });
    check(res, { 'TC5 GQL OK': (r) => r.status === 200 && r.json().errors === undefined });
  });

  // [TC 6] 트랜잭션 쓰기
  group('TC6: Write Transaction', function () {
    const payload = JSON.stringify({ query: `mutation { createOrder(input: { customer_id: "${customerId}", status: "created" }) { order_id } }` });
    const res = http.post('http://benchmark_graphql:8081/query', payload, { headers: gqlHeaders, tags: { tc: 'tc6', api: 'graphql' } });
    check(res, { 'TC6 GQL OK': (r) => r.status === 200 && r.json().errors === undefined });
  });

  // [TC 7] 예외 처리
  group('TC7: Error Handling', function () {
    const payload = JSON.stringify({ query: `query { getSimpleOrder(id: "${invalidId}") { order_id } }` });
    const res = http.post('http://benchmark_graphql:8081/query', payload, { headers: gqlHeaders, tags: { tc: 'tc7', api: 'graphql_error' } });
    check(res, { 'TC7 GQL Error': (r) => r.status === 200 && r.json().errors !== undefined });
  });

  sleep(1);
}
