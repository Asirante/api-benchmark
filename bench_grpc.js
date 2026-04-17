import grpc from 'k6/net/grpc';
import { check, group, sleep } from 'k6';

const clientDirect = new grpc.Client();
clientDirect.load(['proto'], 'order.proto');

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
    isConnected = true;
  }

  const validId = 'e481f51cbdc54678b7cc49136f2d6af7';
  const invalidId = 'fake_invalid_id_9999';
  const customerId = '06b8999e2fba1a1fbc88172c00ba8bc7';

  group('TC1: Simple Read', function () {
    const res = clientDirect.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc1', api: 'grpc' } });
    check(res, { 'TC1 gRPC OK': (r) => r && r.status === grpc.StatusOK });
  });

  group('TC2: Paging', function () {
    const res = clientDirect.invoke('order.OrderService/GetOrders', { limit: 50, offset: 0 }, { tags: { tc: 'tc2', api: 'grpc' } });
    check(res, { 'TC2 gRPC OK': (r) => r && r.status === grpc.StatusOK });
  });

  group('TC3: Under-fetching', function () {
    clientDirect.invoke('order.OrderService/GetSimpleOrder', { order_id: validId }, { tags: { tc: 'tc3', api: 'grpc_part1' } });
    const res = clientDirect.invoke('order.OrderService/GetItemsByOrderID', { order_id: validId }, { tags: { tc: 'tc3', api: 'grpc_part2' } });
    check(res, { 'TC3 gRPC OK': (r) => r && r.status === grpc.StatusOK });
  });

  group('TC4: Partial Field', function () {
    const res = clientDirect.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc4', api: 'grpc' } });
    check(res, { 'TC4 gRPC OK': (r) => r && r.status === grpc.StatusOK });
  });

  group('TC5: Full Heavy Join', function () {
    const res = clientDirect.invoke('order.OrderService/GetOrderDetails', { order_id: validId }, { tags: { tc: 'tc5', api: 'grpc' } });
    check(res, { 'TC5 gRPC OK': (r) => r && r.status === grpc.StatusOK });
  });

  group('TC6: Write Transaction', function () {
    const res = clientDirect.invoke('order.OrderService/CreateOrder', { customer_id: customerId, status: "created" }, { tags: { tc: 'tc6', api: 'grpc' } });
    check(res, { 'TC6 gRPC OK': (r) => r && r.status === grpc.StatusOK });
  });

  group('TC7: Error Handling', function () {
    const res = clientDirect.invoke('order.OrderService/GetSimpleOrder', { order_id: invalidId }, { tags: { tc: 'tc7', api: 'grpc_error' } });
    check(res, { 'TC7 gRPC Error': (r) => r && r.status !== grpc.StatusOK });
  });

  sleep(1);
}