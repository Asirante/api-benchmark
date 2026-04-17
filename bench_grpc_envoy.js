import grpc from 'k6/net/grpc';
import { check, group, sleep } from 'k6';

const clientDirect = new grpc.Client();
clientDirect.load(['proto'], 'order.proto');

const clientEnvoy = new grpc.Client();
clientEnvoy.load(['proto'], 'order.proto');

const parsedVUs = parseInt(__ENV.VUS);
const maxVUs = isNaN(parsedVUs) ? 1000 : parsedVUs;

const standardStages = [
  { duration: '10s', target: Math.floor(maxVUs / 2) },
  { duration: '10s', target: maxVUs },
  { duration: '30s', target: maxVUs },
  { duration: '10s', target: 0 },
];

const spikeStages = [
  { duration: '10s', target: 100 },
  { duration: '5s',  target: 2000 },
  { duration: '15s', target: 2000 },
  { duration: '5s',  target: 100 },
  { duration: '10s', target: 100 },
  { duration: '5s',  target: 5000 },
  { duration: '15s', target: 5000 },
  { duration: '15s', target: 0 },
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