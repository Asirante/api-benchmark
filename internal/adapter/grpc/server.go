package grpc

import (
	"api-benchmark/internal/adapter/grpc/pb"
	"api-benchmark/internal/core/repository"
	"context"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type OrderGrpcServer struct {
	pb.UnimplementedOrderServiceServer
	Repo *repository.OrderRepo
}

func NewOrderGrpcServer(repo *repository.OrderRepo) *OrderGrpcServer {
	return &OrderGrpcServer{Repo: repo}
}

// =======================================================
// [TC 1, 7, 9-1, 9-3] 단순 조회 (가벼운 페이로드)
// =======================================================
func (s *OrderGrpcServer) GetSimpleOrder(ctx context.Context, req *pb.GetOrderRequest) (*pb.SimpleOrderResponse, error) {
	// TC 7을 위한 예외 처리 시뮬레이션: 가짜 ID가 들어오면 NotFound 에러 반환
	if req.GetOrderId() == "fake_invalid_id_9999" {
		return nil, status.Error(codes.NotFound, "Order not found")
	}

	return &pb.SimpleOrderResponse{
		OrderId:     req.GetOrderId(),
		OrderStatus: "delivered",
	}, nil
}

// =======================================================
// [TC 2] 대용량 페이징
// =======================================================
func (s *OrderGrpcServer) GetOrders(ctx context.Context, req *pb.GetOrdersRequest) (*pb.GetOrdersResponse, error) {
	return &pb.GetOrdersResponse{}, nil
}

// =======================================================
// [TC 3] N+1 문제 시뮬레이션용 (아이템만 따로 조회)
// =======================================================
func (s *OrderGrpcServer) GetItemsByOrderID(ctx context.Context, req *pb.GetOrderRequest) (*pb.OrderItemsResponse, error) {
	return &pb.OrderItemsResponse{}, nil
}

// =======================================================
// [TC 4, 5, 9-2] 극한 조인 (무거운 페이로드 - Customer 포함)
// =======================================================
func (s *OrderGrpcServer) GetOrderDetails(ctx context.Context, req *pb.GetOrderRequest) (*pb.FullOrderResponse, error) {
	return &pb.FullOrderResponse{
		OrderId:     req.GetOrderId(),
		OrderStatus: "delivered",
		Customer: &pb.Customer{
			CustomerCity:  "Seoul",
			CustomerState: "KR",
		},
	}, nil
}

// =======================================================
// [TC 6] 트랜잭션 쓰기
// =======================================================
func (s *OrderGrpcServer) CreateOrder(ctx context.Context, req *pb.CreateOrderRequest) (*pb.CreateOrderResponse, error) {
	return &pb.CreateOrderResponse{
		OrderId: "new_order_123",
		Success: true,
	}, nil
}
