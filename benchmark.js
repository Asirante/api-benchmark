import http from 'k6/http';
import grpc from 'k6/net/grpc';
import { uuidv4 } from 'https://jslib.k6.io/k6-utils/1.4.0/index.js';
import { check, group, sleep } from 'k6';

// Direct 통신용과 Envoy 프록시 통신용 클라이언트 객체 분리
const clientDirect = new grpc.Client();
clientDirect.load(['proto'], 'order.proto');

const clientEnvoy = new grpc.Client();
clientEnvoy.load(['proto'], 'order.proto');

const maxVUs = __ENV.VUS ? parseInt(__ENV.VUS) : 1000;

export const options = {
  setupTimeout: '1m',
  stages: [
    { duration: '10s', target: Math.floor(maxVUs / 2) }, // 1단계: 웜업 (Warm-up)
    { duration: '10s', target: maxVUs },                 // 2단계: 목표 부하 도달
    { duration: '30s', target: maxVUs },                 // 3단계: 부하 유지 (Steady-state)
    { duration: '10s', target: 0 },                      // 4단계: 쿨다운 (Cool-down)
  ],
};

export default function () {
  // 포트 고갈 방지를 위한 커넥션 재사용 (Connection Pooling)
  clientDirect.connect('benchmark_grpc:50051', { plaintext: true });
  clientEnvoy.connect('benchmark_envoy:8082', { plaintext: true });

  const validId = 'e481f51cbdc54678b7cc49136f2d6af7'; 
  const invalidId = 'fake_invalid_id_9999';            
  const gqlHeaders = { 'Content-Type': 'application/json' };
  const customerId = '06b8999e2fba1a1fbc88172c00ba8bc7';

  // =======================================================
  // [TC 1] 단건 조회: 통신 프로토콜별 기본 지연 시간 측정
  // =======================================================
  group('TC1: Simple Read', function () {
    const resRest = http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${validId}`, { tags: { tc: 'tc1', api: 'rest' } });
    check(resRest, { 'TC1 REST OK': (r) => r.status === 200 });

    const gqlPayload = JSON.stringify({ query: `query { getSimpleOrder(id: "${validId}") { order_id order_status } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc1', api: 'graphql' } });
    check(resGql, { 'TC1 GQL OK': (r) => r.status === 200 });

    const resGrpc = clientDirect.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc1', api: 'grpc' } });
    check(resGrpc, { 'TC1 gRPC Direct OK': (r) => r && r.status === grpc.StatusOK });

    // const resEnvoy = clientEnvoy.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc1', api: 'grpc_envoy' } });
    // check(resEnvoy, { 'TC1 gRPC Envoy OK': (r) => r && r.status === grpc.StatusOK });
  });

  // =======================================================
  // [TC 2] 페이징 조회: 대용량 데이터 다건 처리 성능 측정
  // =======================================================
  group('TC2: Paging', function () {
    const resRest = http.get(`http://benchmark_rest:8080/api/v1/orders?limit=50&offset=0`, { tags: { tc: 'tc2', api: 'rest' } });
    check(resRest, { 'TC2 REST OK': (r) => r.status === 200 });

    const gqlPayload = JSON.stringify({ query: `query { getOrders(limit: 50, offset: 0) { order_id } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc2', api: 'graphql' } });
    check(resGql, { 'TC2 GQL OK': (r) => r.status === 200 });
    
    const resGrpc = clientDirect.invoke('order.OrderService/GetOrders', { limit: 50, offset: 0 }, { tags: { tc: 'tc2', api: 'grpc' } });
    check(resGrpc, { 'TC2 gRPC OK': (r) => r && r.status === grpc.StatusOK });
  });

  // =======================================================
  // [TC 3] 다중 호출 (Under-fetching): REST API의 구조적 한계 검증
  // =======================================================
  group('TC3: Under-fetching', function () {
    http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${validId}`, { tags: { tc: 'tc3', api: 'rest_part1' } });
    const resRest2 = http.get(`http://benchmark_rest:8080/api/v1/orders/${validId}/items`, { tags: { tc: 'tc3', api: 'rest_part2' } });
    check(resRest2, { 'TC3 REST N+1 OK': (r) => r.status === 200 });

    const gqlPayload = JSON.stringify({ query: `query { getOrderDetails(id: "${validId}") { order_id items { product_name } } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc3', api: 'graphql' } });
    check(resGql, { 'TC3 GQL OK': (r) => r.status === 200 });
  });

  // =======================================================
  // [TC 4] 부분 필드 추출: GraphQL의 네트워크 페이로드 최적화 검증
  // =======================================================
  group('TC4: Partial Field (Over-fetching)', function () {
    const resRest = http.get(`http://benchmark_rest:8080/api/v1/orders/details/${validId}`, { tags: { tc: 'tc4', api: 'rest' } });
    check(resRest, { 'TC4 REST OK': (r) => r.status === 200 });

    const gqlPayload = JSON.stringify({ query: `query { getOrderDetails(id: "${validId}") { order_status customer { customer_city } } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc4', api: 'graphql' } });
    check(resGql, { 'TC4 GQL OK': (r) => r.status === 200 });

    const resGrpc = clientDirect.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc4', api: 'grpc' } });
    check(resGrpc, { 'TC4 gRPC OK': (r) => r && r.status === grpc.StatusOK });
  });

  // =======================================================
  // [TC 5] 다중 테이블 조인: 대용량 페이로드 환경에서의 압축 성능 측정
  // =======================================================
  group('TC5: Full Heavy Join', function () {
    const resRest = http.get(`http://benchmark_rest:8080/api/v1/orders/details/${validId}`, { tags: { tc: 'tc5', api: 'rest' } });
    check(resRest, { 'TC5 REST OK': (r) => r.status === 200 });

    const gqlPayload = JSON.stringify({ 
      query: `query { getOrderDetails(id: "${validId}") { order_id order_status items { product_id price product_name } customer { customer_city customer_state } } }` 
    });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc5', api: 'graphql' } });
    check(resGql, { 'TC5 GQL OK': (r) => r.status === 200 });

    const resGrpc = clientDirect.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc5', api: 'grpc' } });
    check(resGrpc, { 'TC5 gRPC OK': (r) => r && r.status === grpc.StatusOK });
  });

  // =======================================================
  // [TC 6] 트랜잭션 쓰기: 파싱(역직렬화) 속도 측정
  // =======================================================
  group('TC6: Write Transaction', function () {
    const payload = JSON.stringify({ customer_id: customerId, status: "created" });
    
    const resRest = http.post('http://benchmark_rest:8080/api/v1/orders', payload, { headers: { 'Content-Type': 'application/json' }, tags: { tc: 'tc6', api: 'rest' } });
    check(resRest, { 'TC6 REST OK': (r) => r.status === 201 || r.status === 200 });

    const gqlPayload = JSON.stringify({ query: `mutation { createOrder(input: { customer_id: customerId, status: "created" }) { order_id } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc6', api: 'graphql' } });
    check(resGql, { 'TC6 GQL OK': (r) => r.status === 200 });

    const resGrpc = clientDirect.invoke('order.OrderService/CreateOrder', { customer_id: customerId, status: "created" }, { tags: { tc: 'tc6', api: 'grpc' } });
    check(resGrpc, { 'TC6 gRPC OK': (r) => r && r.status === grpc.StatusOK });
  });

  // =======================================================
  // [TC 7] 예외 처리: 에러 응답 객체 생성 지연 시간 측정
  // =======================================================
  group('TC7: Error Handling Overhead', function () {
    const resRestErr = http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${invalidId}`, { tags: { tc: 'tc7', api: 'rest_error' } });
    check(resRestErr, { 'TC7 REST Error': (r) => r.status !== 200 }); 

    const gqlPayload = JSON.stringify({ query: `query { getSimpleOrder(id: "${invalidId}") { order_id } }` });
    const resGqlErr = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc7', api: 'graphql_error' } });
    check(resGqlErr, { 'TC7 GQL Error': (r) => r.status === 200 }); 

    const resGrpcErr = clientDirect.invoke('order.OrderService/GetSimpleOrder', { order_id: invalidId }, { tags: { tc: 'tc7', api: 'grpc_error' } });
    check(resGrpcErr, { 'TC7 gRPC Error': (r) => r && r.status !== grpc.StatusOK });
  });

  sleep(1); 
}