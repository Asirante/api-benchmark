import http from 'k6/http';
import grpc from 'k6/net/grpc';
import { check, group, sleep } from 'k6';

const client = new grpc.Client();
client.load(['proto'], 'order.proto');

// TC8: 스파이크(Spike) 부하 테스트 환경 설정 (정상 상태 -> 1차 폭증 -> 회복 -> 2차 최대 폭증 -> 회복)
export const options = {
  setupTimeout: '2m',
  stages: [
    // 1. 정상 부하 상태 유지 (10초)
    { duration: '10s', target: 100 },
    
    // 2. 1차 스파이크: 5초 내 5,000 VUs로 급증 (돌발 트래픽 모사)
    { duration: '5s', target: 5000 },
    // 3. 1차 스파이크 유지: 5,000 VUs 지속 상태에서의 시스템 처리량 확인 (15초)
    { duration: '15s', target: 5000 },
    
    // 4. 1차 회복: 트래픽 급감 후 시스템 안정화 및 자원 회수 여부 관찰 (15초)
    { duration: '5s', target: 100 },
    { duration: '10s', target: 100 },

    // 5. 2차 최대 스파이크: 5초 내 10,000 VUs로 극단적 폭증 모사
    { duration: '5s', target: 10000 },
    // 6. 2차 스파이크 유지: 시스템 임계점 도달 및 커넥션 타임아웃 발생 여부 확인 (15초)
    { duration: '15s', target: 10000 },

    // 7. 최종 회복: 부하 완전 종료 후 메모리 및 커넥션 풀 정상화 확인 (15초)
    { duration: '15s', target: 0 },
  ],
};

export default function () {
  const validId = 'e481f51cbdc54678b7cc49136f2d6af7'; 
  const gqlHeaders = { 'Content-Type': 'application/json' };

  // TC8 테스트 그룹: 다중 테이블 조인(Heavy Join) API를 타겟으로 프로토콜별 성능 한계 검증
  group('TC8: True Spike Load (Heavy Join)', function () {
    
    // 1. REST: JSON 데이터 파싱 및 다중 객체 매핑 오버헤드 관찰
    const resRest = http.get(`http://benchmark_rest:8080/api/v1/orders/details/${validId}`, { tags: { tc: 'tc8_spike', api: 'rest' } });
    check(resRest, { 'REST Spike OK': (r) => r.status === 200 });

    // 2. GraphQL: 리졸버(Resolver) 기반 필드 필터링에 따른 백엔드 CPU 연산 부하 관찰
    const gqlPayload = JSON.stringify({ query: `query { getOrderDetails(id: "${validId}") { order_id items { product_name } customer { customer_city } } }` });
    const resGql = http.post('http://benchmark_graphql:8081/query', gqlPayload, { headers: gqlHeaders, tags: { tc: 'tc8_spike', api: 'graphql' } });
    check(resGql, { 'GQL Spike OK': (r) => r.status === 200 });

    // 3. gRPC: HTTP/2 멀티플렉싱 및 Protobuf 바이너리 압축을 통한 방어 능력 검증
    client.connect('benchmark_grpc:50051', { plaintext: true });
    const resGrpc = client.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc8_spike', api: 'grpc_direct' } });
    check(resGrpc, { 'gRPC Spike OK': (r) => r && r.status === grpc.StatusOK });
    client.close();
  });

  sleep(1); 
}