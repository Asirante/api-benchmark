import http from 'k6/http';
import grpc from 'k6/net/grpc';
import { check, group, sleep } from 'k6';

const client = new grpc.Client();
client.load(['proto'], 'order.proto');

// 외부에서 주입받은 목표 유저 수 (기본값 1,000명)
const maxVUs = __ENV.VUS ? parseInt(__ENV.VUS) : 1000;

export const options = {
  setupTimeout: '1m',
  stages: [
    { duration: '10s', target: Math.floor(maxVUs / 2) }, // 1단계: 웜업
    { duration: '10s', target: maxVUs },                 // 2단계: 타겟 도달
    { duration: '30s', target: maxVUs },                 // 3단계: 최고 부하 유지
    { duration: '10s', target: 0 },                      // 4단계: 쿨다운
  ],
};

export default function () {
  const validId = 'e481f51cbdc54678b7cc49136f2d6af7'; 
  const invalidId = 'fake_invalid_id_9999';            
  const gqlHeaders = { 'Content-Type': 'application/json' };

  // =======================================================
  // [TC 1] 단순 조회 & Envoy 프록시 오버헤드
  // =======================================================
  group('TC1: Read & Envoy Proxy', function () {
    // 1. REST
    const resRest = http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${validId}`, { tags: { tc: 'tc1', api: 'rest' } });
    check(resRest, { 'TC1 REST OK': (r) => r.status === 200 });

    // 2. GraphQL
    const gqlPayload = JSON.stringify({ query: `query { getSimpleOrder(id: "${validId}") { order_id order_status } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc1', api: 'graphql' } });
    check(resGql, { 'TC1 GQL OK': (r) => r.status === 200 });

    // 3. gRPC Direct (순수 백엔드 속도)
    client.connect('benchmark_grpc:50051', { plaintext: true });
    const resGrpc = client.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc1', api: 'grpc_direct' } });
    check(resGrpc, { 'TC1 gRPC Direct OK': (r) => r && r.status === grpc.StatusOK });
    client.close();

    // 4. gRPC Envoy Proxy (통행료 오버헤드 측정)
    client.connect('benchmark_envoy:8082', { plaintext: true });
    const resEnvoy = client.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc1', api: 'grpc_envoy' } });
    check(resEnvoy, { 'TC1 gRPC Envoy OK': (r) => r && r.status === grpc.StatusOK });
    client.close();
  });

  // =======================================================
  // [TC 2] 대용량 페이징
  // =======================================================
  group('TC2: Paging', function () {
    const resRest = http.get(`http://benchmark_rest:8080/api/v1/orders?limit=50&offset=0`, { tags: { tc: 'tc2', api: 'rest' } });
    check(resRest, { 'TC2 REST OK': (r) => r.status === 200 });

    const gqlPayload = JSON.stringify({ query: `query { getOrders(limit: 50, offset: 0) { order_id } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc2', api: 'graphql' } });
    check(resGql, { 'TC2 GQL OK': (r) => r.status === 200 });
    
    // gRPC 페이징
    client.connect('benchmark_grpc:50051', { plaintext: true });
    const resGrpc = client.invoke('order.OrderService/GetOrders', { limit: 50, offset: 0 }, { tags: { tc: 'tc2', api: 'grpc' } });
    check(resGrpc, { 'TC2 gRPC OK': (r) => r && r.status === grpc.StatusOK });
    client.close();
  });

  // =======================================================
  // [TC 3] 언더페칭 (N+1 약점 찌르기 vs GraphQL의 강점)
  // =======================================================
  group('TC3: Under-fetching', function () {
    // REST (2번 호출해야 함)
    http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${validId}`, { tags: { tc: 'tc3', api: 'rest_part1' } });
    const resRest2 = http.get(`http://benchmark_rest:8080/api/v1/orders/${validId}/items`, { tags: { tc: 'tc3', api: 'rest_part2' } });
    check(resRest2, { 'TC3 REST N+1 OK': (r) => r.status === 200 });

    // GraphQL (1번 호출로 싹쓸이)
    const gqlPayload = JSON.stringify({ query: `query { getOrderDetails(id: "${validId}") { order_id items { product_name } } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc3', api: 'graphql' } });
    check(resGql, { 'TC3 GQL OK': (r) => r.status === 200 });
  });

  // =======================================================
  // [TC 4 & 5] 극한 조인 및 오버페칭
  // =======================================================
  group('TC4_5: Heavy Join Payload', function () {
    // REST: 무거운 JSON 전체 응답
    const resRestHeavy = http.get(`http://benchmark_rest:8080/api/v1/orders/details/${validId}`, { tags: { tc: 'tc4', api: 'rest' } });
    check(resRestHeavy, { 'TC4 REST OK': (r) => r.status === 200 });

    // GraphQL: 필요한 데이터만 필터링하지만 서버 CPU 연산 부하 발생
    const gqlPayload = JSON.stringify({ query: `query { getOrderDetails(id: "${validId}") { order_id order_status customer_city } }` });
    const resGqlHeavy = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc4', api: 'graphql' } });
    check(resGqlHeavy, { 'TC4 GQL OK': (r) => r.status === 200 });

    // gRPC Direct: 거대 데이터를 Protobuf로 꽉꽉 압축해서 전송
    client.connect('benchmark_grpc:50051', { plaintext: true });
    const resGrpcHeavy = client.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc4', api: 'grpc' } });
    check(resGrpcHeavy, { 'TC4 gRPC OK': (r) => r && r.status === grpc.StatusOK });
    client.close();
  });

  // =======================================================
  // [TC 6] 트랜잭션 쓰기 (JSON 파싱 vs Protobuf 파싱)
  // =======================================================
  group('TC6: Write Transaction', function () {
    const payload = JSON.stringify({ customer_id: "cust_1", status: "created" });
    
    // REST
    const resRest = http.post('http://benchmark_rest:8080/api/v1/orders', payload, { headers: { 'Content-Type': 'application/json' }, tags: { tc: 'tc6', api: 'rest' } });
    check(resRest, { 'TC6 REST OK': (r) => r.status === 201 || r.status === 200 });

    // GraphQL
    const gqlPayload = JSON.stringify({ query: `mutation { createOrder(input: { customer_id: "cust_1", status: "created" }) { order_id } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc6', api: 'graphql' } });
    check(resGql, { 'TC6 GQL OK': (r) => r.status === 200 });

    // gRPC
    client.connect('benchmark_grpc:50051', { plaintext: true });
    const resGrpc = client.invoke('order.OrderService/CreateOrder', { customer_id: "cust_1", status: "created" }, { tags: { tc: 'tc6', api: 'grpc' } });
    check(resGrpc, { 'TC6 gRPC OK': (r) => r && r.status === grpc.StatusOK });
    client.close();
  });

  // =======================================================
  // [TC 7] 오류 처리 오버헤드
  // =======================================================
  group('TC7: Error Handling Overhead', function () {
    // REST
    const resRestErr = http.get(`http://benchmark_rest:8080/api/v1/orders/simple/${invalidId}`, { tags: { tc: 'tc7', api: 'rest_error' } });
    check(resRestErr, { 'TC7 REST Error': (r) => r.status !== 200 }); 

    // GraphQL
    const gqlPayload = JSON.stringify({ query: `query { getSimpleOrder(id: "${invalidId}") { order_id } }` });
    const resGqlErr = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc7', api: 'graphql_error' } });
    // GraphQL은 에러가 나도 HTTP 200을 뱉고 errors 배열을 포함함
    check(resGqlErr, { 'TC7 GQL Error': (r) => r.status === 200 }); 

    // gRPC
    client.connect('benchmark_grpc:50051', { plaintext: true });
    const resGrpcErr = client.invoke('order.OrderService/GetSimpleOrder', { order_id: invalidId }, { tags: { tc: 'tc7', api: 'grpc_error' } });
    check(resGrpcErr, { 'TC7 gRPC Error': (r) => r && r.status !== grpc.StatusOK });
    client.close();
  });

  sleep(1); 
}