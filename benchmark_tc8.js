import http from 'k6/http';
import grpc from 'k6/net/grpc';
import { check, group, sleep } from 'k6';

const client = new grpc.Client();
client.load(['proto'], 'order.proto');

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

export default function () {
  // 포트 고갈 방지를 위한 커넥션 재사용 (Connection Pooling)
  client.connect('benchmark_grpc:50051', { plaintext: true });

  const validId = 'e481f51cbdc54678b7cc49136f2d6af7'; 
  const gqlHeaders = { 'Content-Type': 'application/json' };

  // 다중 테이블 조인 API를 대상으로 프로토콜별 처리 효율 및 한계 검증
  group('TC8: Spike Load Evaluation', function () {
    
    // REST: 동시 연결에 따른 소켓 부족 및 다중 객체 매핑(JSON 파싱) 부하 관찰
    const resRest = http.get(`http://benchmark_rest:8080/api/v1/orders/details/${validId}`, { tags: { tc: 'tc8_spike', api: 'rest' } });
    check(resRest, { 'REST Spike OK': (r) => r.status === 200 });

    // GraphQL: 스파이크 트래픽에 따른 백엔드 리졸버(Resolver) 연산 병목 관찰
    const gqlPayload = JSON.stringify({ query: `query { getOrderDetails(id: "${validId}") { order_id items { product_name } customer { customer_city } } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc8_spike', api: 'graphql' } });
    check(resGql, { 'GQL Spike OK': (r) => r.status === 200 });

    // gRPC: HTTP/2 기반 단일 커넥션 멀티플렉싱(Multiplexing)을 통한 트래픽 방어 성능 검증
    const resGrpc = client.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc8_spike', api: 'grpc' } });
    check(resGrpc, { 'gRPC Spike OK': (r) => r && r.status === grpc.StatusOK });
  });

  sleep(1); 
}