import grpc from 'k6/net/grpc';
import { check, group, sleep } from 'k6';

const clientDirect = new grpc.Client();
clientDirect.load(['proto'], 'order.proto');

const clientEnvoy = new grpc.Client();
clientEnvoy.load(['proto'], 'order.proto');

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
let isConnected = false;

export default function () {
  if (!isConnected) {
    clientDirect.connect('benchmark_grpc:50051', { plaintext: true });
    clientEnvoy.connect('benchmark_envoy:8082', { plaintext: true });
    isConnected = true;
  }

  const validId = 'e481f51cbdc54678b7cc49136f2d6af7';
  const invalidId = 'fake_invalid_id_9999';

  group('TC9-1: Simple Read (Direct vs Envoy)', function () {
    const resDirect = clientDirect.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc9_simple', api: 'grpc_direct' } });
    check(resDirect, { 'Direct Simple OK': (r) => r && r.status === grpc.StatusOK });

    const resEnvoy = clientEnvoy.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc9_simple', api: 'grpc_envoy' } });
    check(resEnvoy, { 'Envoy Simple OK': (r) => r && r.status === grpc.StatusOK });
  });

  group('TC9-2: Heavy Payload (Direct vs Envoy)', function () {
    const resDirectHeavy = clientDirect.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc9_heavy', api: 'grpc_direct' } });
    check(resDirectHeavy, { 'Direct Heavy OK': (r) => r && r.status === grpc.StatusOK });

    const resEnvoyHeavy = clientEnvoy.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc9_heavy', api: 'grpc_envoy' } });
    check(resEnvoyHeavy, { 'Envoy Heavy OK': (r) => r && r.status === grpc.StatusOK });
  });

  group('TC9-3: Error Handling (Direct vs Envoy)', function () {
    const resDirectErr = clientDirect.invoke('order.OrderService/GetSimpleOrder', { order_id: invalidId }, { tags: { tc: 'tc9_error', api: 'grpc_direct' } });
    check(resDirectErr, { 'Direct Error Checked': (r) => r && r.status !== grpc.StatusOK });

    const resEnvoyErr = clientEnvoy.invoke('order.OrderService/GetSimpleOrder', { order_id: invalidId }, { tags: { tc: 'tc9_error', api: 'grpc_envoy' } });
    check(resEnvoyErr, { 'Envoy Error Checked': (r) => r && r.status !== grpc.StatusOK });
  });

  sleep(1);
}