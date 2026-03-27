package graph

import (
	"api-benchmark/graph/model" // gqlgen이 생성한 model 패키지 경로 (프로젝트에 맞게 수정 필요)
	"context"
)

// =======================================================
// [TC 6] 트랜잭션 쓰기
// =======================================================
func (r *mutationResolver) CreateOrder(ctx context.Context, input model.OrderInput) (*model.CreateOrderPayload, error) {
	return &model.CreateOrderPayload{
		OrderID: "new_order_123",
		Success: true,
	}, nil
}

// =======================================================
// [TC 1, 7] 단순 조회
// =======================================================
func (r *queryResolver) GetSimpleOrder(ctx context.Context, id string) (*model.SimpleOrder, error) {
	return &model.SimpleOrder{
		OrderID:     id,
		OrderStatus: "delivered",
	}, nil
}

// =======================================================
// [TC 2] 대용량 페이징
// =======================================================
func (r *queryResolver) GetOrders(ctx context.Context, limit *int, offset *int) ([]*model.SimpleOrder, error) {
	return []*model.SimpleOrder{}, nil
}

// =======================================================
// [TC 3, 4, 5] 극한 조인 및 오버페칭 방어
// =======================================================
func (r *queryResolver) GetOrderDetails(ctx context.Context, id string) (*model.FullOrder, error) {
	return &model.FullOrder{
		OrderID:     id,
		OrderStatus: "delivered",
		Items: []*model.OrderItem{
			{ProductID: "p1", Price: 10.5, ProductName: "Item 1"},
		},
		Customer: &model.Customer{
			CustomerCity:  "Seoul",
			CustomerState: "KR",
		},
	}, nil
}

// Query, Mutation 리졸버 인터페이스 반환 함수들 (기존에 생성된 것 유지)
func (r *Resolver) Mutation() MutationResolver { return &mutationResolver{r} }
func (r *Resolver) Query() QueryResolver       { return &queryResolver{r} }

type mutationResolver struct{ *Resolver }
type queryResolver struct{ *Resolver }
