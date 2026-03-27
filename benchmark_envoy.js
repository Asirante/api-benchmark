import grpc from 'k6/net/grpc';
import { check, group, sleep } from 'k6';

const client = new grpc.Client();
client.load(['proto'], 'order.proto');

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

  // =======================================================
  // 🔍 [TC 9-1] 단순 조회: 프록시 연결 및 기본 통행료 측정
  // =======================================================
  group('TC9-1: Simple Read (Direct vs Envoy)', function () {
    // Direct (50051)
    client.connect('benchmark_grpc:50051', { plaintext: true });
    const resDirect = client.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc9_simple', api: 'grpc_direct' } });
    check(resDirect, { 'Direct Simple OK': (r) => r && r.status === grpc.StatusOK });
    client.close();

    // Envoy (8082)
    client.connect('benchmark_envoy:8082', { plaintext: true });
    const resEnvoy = client.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc9_simple', api: 'grpc_envoy' } });
    check(resEnvoy, { 'Envoy Simple OK': (r) => r && r.status === grpc.StatusOK });
    client.close();
  });

  // =======================================================
  // 📦 [TC 9-2] 대용량 조인: 데이터 크기가 커질 때 프록시 병목 측정
  // =======================================================
  group('TC9-2: Heavy Payload (Direct vs Envoy)', function () {
    client.connect('benchmark_grpc:50051', { plaintext: true });
    const resDirectHeavy = client.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc9_heavy', api: 'grpc_direct' } });
    check(resDirectHeavy, { 'Direct Heavy OK': (r) => r && r.status === grpc.StatusOK });
    client.close();

    client.connect('benchmark_envoy:8082', { plaintext: true });
    const resEnvoyHeavy = client.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc9_heavy', api: 'grpc_envoy' } });
    check(resEnvoyHeavy, { 'Envoy Heavy OK': (r) => r && r.status === grpc.StatusOK });
    client.close();
  });

  // =======================================================
  // 💥 [TC 9-3] 오류 처리: 에러 반환 시 프록시 지연 측정
  // =======================================================
  group('TC9-3: Error Handling (Direct vs Envoy)', function () {
    client.connect('benchmark_grpc:50051', { plaintext: true });
    const resDirectErr = client.invoke('order.OrderService/GetSimpleOrder', { order_id: invalidId }, { tags: { tc: 'tc9_error', api: 'grpc_direct' } });
    check(resDirectErr, { 'Direct Error Checked': (r) => r && r.status !== grpc.StatusOK });
    client.close();

    client.connect('benchmark_envoy:8082', { plaintext: true });
    const resEnvoyErr = client.invoke('order.OrderService/GetSimpleOrder', { order_id: invalidId }, { tags: { tc: 'tc9_error', api: 'grpc_envoy' } });
    check(resEnvoyErr, { 'Envoy Error Checked': (r) => r && r.status !== grpc.StatusOK });
    client.close();
  });

  sleep(1); 
}