import http from 'k6/http';
import grpc from 'k6/net/grpc';
import { check, group, sleep } from 'k6';

// Direct 통신용 클라이언트
const clientDirect = new grpc.Client();
clientDirect.load(['proto'], 'order.proto');

// Envoy 프록시 통신용 클라이언트 추가
const clientEnvoy = new grpc.Client();
clientEnvoy.load(['proto'], 'order.proto');

// [TC 8] 스파이크(Spike) 부하 시나리오: 정상 -> 1차 폭증 -> 회복 -> 2차 최대 폭증 -> 회복
export const options = {
  setupTimeout: '2m',
  stages: [
    { duration: '10s', target: 100 },    // 1. 정상 부하 상태
    { duration: '5s',  target: 5000 },   // 2. 1차 스파이크 (VUs 급증 모사)
    { duration: '15s', target: 5000 },   // 3. 1차 스파이크 유지
    { duration: '5s',  target: 100 },    // 4. 1차 회복 구간
    { duration: '10s', target: 100 },    // 5. 시스템 안정화 확인
    { duration: '5s',  target: 10000 },  // 6. 2차 최대 스파이크 (극한의 트래픽 모사)
    { duration: '15s', target: 10000 },  // 7. 시스템 임계점 도달 및 생존력 확인
    { duration: '15s', target: 0 },      // 8. 최종 자원 회수 및 복구 확인
  ],
};

// 각 VU별 커넥션 상태 관리 변수
let isConnected = false;

export default function () {
  // 최초 1회만 Direct와 Envoy 모두 연결하여 커넥션 재사용
  if (!isConnected) {
    clientDirect.connect('benchmark_grpc:50051', { plaintext: true });
    clientEnvoy.connect('benchmark_envoy:8082', { plaintext: true }); // Envoy 포트(8082) 연결 추가
    isConnected = true;
  }

  const validId = 'e481f51cbdc54678b7cc49136f2d6af7'; 
  const gqlHeaders = { 'Content-Type': 'application/json' };

  group('TC8: Spike Load Evaluation', function () {
    
    // 1. REST
    const resRest = http.get(`http://benchmark_rest:8080/api/v1/orders/details/${validId}`, { tags: { tc: 'tc8_spike', api: 'rest' } });
    check(resRest, { 'REST Spike OK': (r) => r.status === 200 });

    // 2. GraphQL
    const gqlPayload = JSON.stringify({ query: `query { getOrderDetails(id: "${validId}") { order_id items { product_name } customer { customer_city } } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc8_spike', api: 'graphql' } });
    check(resGql, { 'GQL Spike OK': (r) => r.status === 200 && r.json().errors === undefined });

    // 3. gRPC Direct (순수 백엔드 통신)
    const resDirect = clientDirect.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc8_spike', api: 'grpc_direct' } });
    check(resDirect, { 'gRPC Direct Spike OK': (r) => r && r.status === grpc.StatusOK });

    // 4. gRPC Envoy (L7 프록시 경유 통신 - 차단율 관찰용)
    const resEnvoy = clientEnvoy.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc8_spike', api: 'grpc_envoy' } });
    check(resEnvoy, { 'gRPC Envoy Spike OK': (r) => r && r.status === grpc.StatusOK });
  });

  sleep(1); 
}