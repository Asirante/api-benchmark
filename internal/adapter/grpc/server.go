package grpc

import (
	"context"

	"api-benchmark/internal/adapter/grpc/pb"
	"api-benchmark/internal/core/repository"

	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// 자동 생성된 gRPC 서버 인터페이스를 구현하는 구조체입니다.
type OrderGrpcServer struct {
	pb.UnimplementedOrderServiceServer
	Repo *repository.OrderRepo // DB 무기 장착
}

// 생성자
func NewOrderGrpcServer(repo *repository.OrderRepo) *OrderGrpcServer {
	return &OrderGrpcServer{Repo: repo}
}

// GetOrder 구현 (proto 파일에서 정의한 RPC 메서드)
func (s *OrderGrpcServer) GetOrder(ctx context.Context, req *pb.GetOrderRequest) (*pb.OrderResponse, error) {
	// 1. 레포지토리에서 데이터 가져오기
	domainOrder, err := s.Repo.GetOrderWithFullDetails(req.GetOrderId())
	if err != nil {
		return nil, status.Errorf(codes.NotFound, "주문을 찾을 수 없습니다: %v", err)
	}

	// 2. Protobuf 응답 객체(pb.OrderResponse)로 변환 (Mapping)
	resp := &pb.OrderResponse{
		OrderId:     domainOrder.OrderID,
		OrderStatus: domainOrder.OrderStatus,
	}

	// Customer 정보가 있다면 세팅
	if domainOrder.Customer.CustomerID != "" {
		resp.Customer = &pb.Customer{
			CustomerCity:  domainOrder.Customer.CustomerCity,
			CustomerState: domainOrder.Customer.CustomerState,
		}
	}

	return resp, nil
}
