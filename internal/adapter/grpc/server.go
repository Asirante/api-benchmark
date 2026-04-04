package grpc

import (
	"api-benchmark/internal/adapter/grpc/pb"
	"api-benchmark/internal/core/domain"
	"api-benchmark/internal/core/repository"
	"context"
	"time"

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
	order, err := s.Repo.GetSimpleOrder(req.GetOrderId())
	if err != nil {
		if err == domain.ErrOrderNotFound {
			return nil, status.Error(codes.NotFound, "Order not found")
		}
		return nil, status.Error(codes.Internal, "Internal server error")
	}

	return &pb.SimpleOrderResponse{
		OrderId:     order.OrderID,
		OrderStatus: order.OrderStatus,
	}, nil
}

// =======================================================
// [TC 2] 대용량 페이징
// =======================================================
func (s *OrderGrpcServer) GetOrders(ctx context.Context, req *pb.GetOrdersRequest) (*pb.GetOrdersResponse, error) {
	limit := int(req.GetLimit())
	offset := int(req.GetOffset())
	if limit <= 0 {
		limit = 100
	}

	orders, err := s.Repo.GetOrdersWithPaging(limit, offset)
	if err != nil {
		return nil, status.Error(codes.Internal, "Failed to fetch orders")
	}

	pbOrders := make([]*pb.SimpleOrderResponse, len(orders))
	for i, o := range orders {
		pbOrders[i] = &pb.SimpleOrderResponse{
			OrderId:     o.OrderID,
			OrderStatus: o.OrderStatus,
		}
	}

	return &pb.GetOrdersResponse{Orders: pbOrders}, nil
}

// =======================================================
// [TC 3] N+1 문제 시뮬레이션용 (아이템만 따로 조회)
// =======================================================
func (s *OrderGrpcServer) GetItemsByOrderID(ctx context.Context, req *pb.GetOrderRequest) (*pb.OrderItemsResponse, error) {
	items, err := s.Repo.GetItemsByOrderID(req.GetOrderId())
	if err != nil {
		return nil, status.Error(codes.Internal, "Failed to fetch order items")
	}

	pbItems := make([]*pb.OrderItem, len(items))
	for i, item := range items {
		pbItems[i] = &pb.OrderItem{
			ProductId:   item.ProductID,
			Price:       float32(item.Price),
			ProductName: item.Product.ProductCategoryName,
		}
	}

	return &pb.OrderItemsResponse{Items: pbItems}, nil
}

// =======================================================
// [TC 4, 5, 9-2] 극한 조인 (무거운 페이로드 - Customer 포함)
// =======================================================
func (s *OrderGrpcServer) GetOrderDetails(ctx context.Context, req *pb.GetOrderRequest) (*pb.FullOrderResponse, error) {
	order, err := s.Repo.GetOrderWithFullDetails(req.GetOrderId())
	if err != nil {
		if err == domain.ErrOrderNotFound {
			return nil, status.Error(codes.NotFound, "Order not found")
		}
		return nil, status.Error(codes.Internal, "Internal server error")
	}

	pbItems := make([]*pb.OrderItem, len(order.Items))
	for i, item := range order.Items {
		pbItems[i] = &pb.OrderItem{
			ProductId:   item.ProductID,
			Price:       float32(item.Price),
			ProductName: item.Product.ProductCategoryName,
		}
	}

	return &pb.FullOrderResponse{
		OrderId:     order.OrderID,
		OrderStatus: order.OrderStatus,
		Items:       pbItems,
		Customer: &pb.Customer{
			CustomerCity:  order.Customer.CustomerCity,
			CustomerState: order.Customer.CustomerState,
		},
	}, nil
}

// =======================================================
// [TC 6] 트랜잭션 쓰기
// =======================================================
func (s *OrderGrpcServer) CreateOrder(ctx context.Context, req *pb.CreateOrderRequest) (*pb.CreateOrderResponse, error) {
	newOrder := &domain.Order{
		OrderID:                domain.GenerateOrderID("grpc"),
		CustomerID:             req.GetCustomerId(),
		OrderStatus:            req.GetStatus(),
		OrderPurchaseTimestamp: time.Now(),
	}

	if err := s.Repo.CreateOrderTransaction(newOrder); err != nil {
		return nil, status.Error(codes.Internal, "Failed to create order")
	}

	return &pb.CreateOrderResponse{
		OrderId: newOrder.OrderID,
		Success: true,
	}, nil
}
