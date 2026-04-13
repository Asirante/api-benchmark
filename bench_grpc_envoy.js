import grpc from 'k6/net/grpc';
import { check, group, sleep } from 'k6';

// ============================================================
// bench_grpc_envoy.js — gRPC Envoy 프록시 오버헤드 격리 벤치마크 (TC9)
// Direct와 Envoy를 동일 세션에서 비교하되,
// REST/GraphQL 서버는 idle 상태로 DB 경합이 없는 환경에서 측정합니다.
//
// TC9-1: 단건 조회 (기본 변환 오버헤드)
// TC9-2: 대용량 페이로드 (패킷 크기 증가에 따른 병목)
// TC9-3: 예외 처리 (에러 반환 시 프록시 지연)
// ============================================================

const clientDirect = new grpc.Client();
clientDirect.load(['proto'], 'order.proto');

const clientEnvoy = new grpc.Client();
clientEnvoy.load(['proto'], 'order.proto');

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

let isConnected = false;

export default function () {
  if (!isConnected) {
    clientDirect.connect('benchmark_grpc:50051', { plaintext: true });
    clientEnvoy.connect('benchmark_envoy:8082', { plaintext: true });
    isConnected = true;
  }

  const validId = 'e481f51cbdc54678b7cc49136f2d6af7';
  const invalidId = 'fake_invalid_id_9999';

  // [TC 9-1] 단건 조회: Envoy 프록시의 기본 변환 오버헤드 측정
  group('TC9-1: Simple Read (Direct vs Envoy)', function () {
    const resDirect = clientDirect.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc9_simple', api: 'grpc_direct' } });
    check(resDirect, { 'Direct Simple OK': (r) => r && r.status === grpc.StatusOK });

    const resEnvoy = clientEnvoy.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc9_simple', api: 'grpc_envoy' } });
    check(resEnvoy, { 'Envoy Simple OK': (r) => r && r.status === grpc.StatusOK });
  });

  // [TC 9-2] 대용량 페이로드: 패킷 크기 증가에 따른 병목 측정
  group('TC9-2: Heavy Payload (Direct vs Envoy)', function () {
    const resDirectHeavy = clientDirect.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc9_heavy', api: 'grpc_direct' } });
    check(resDirectHeavy, { 'Direct Heavy OK': (r) => r && r.status === grpc.StatusOK });

    const resEnvoyHeavy = clientEnvoy.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc9_heavy', api: 'grpc_envoy' } });
    check(resEnvoyHeavy, { 'Envoy Heavy OK': (r) => r && r.status === grpc.StatusOK });
  });

  // [TC 9-3] 예외 처리: 에러 반환 시 프록시 지연 시간 측정
  group('TC9-3: Error Handling (Direct vs Envoy)', function () {
    const resDirectErr = clientDirect.invoke('order.OrderService/GetSimpleOrder', { order_id: invalidId }, { tags: { tc: 'tc9_error', api: 'grpc_direct' } });
    check(resDirectErr, { 'Direct Error Checked': (r) => r && r.status !== grpc.StatusOK });

    const resEnvoyErr = clientEnvoy.invoke('order.OrderService/GetSimpleOrder', { order_id: invalidId }, { tags: { tc: 'tc9_error', api: 'grpc_envoy' } });
    check(resEnvoyErr, { 'Envoy Error Checked': (r) => r && r.status !== grpc.StatusOK });
  });

  sleep(1);
}
