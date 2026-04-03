package graph

import (
	"api-benchmark/graph/model"
	"api-benchmark/internal/core/domain"
	"context"
	"fmt"
	"time"
)

// =======================================================
// [TC 6] 트랜잭션 쓰기
// =======================================================
func (r *mutationResolver) CreateOrder(ctx context.Context, input model.OrderInput) (*model.CreateOrderPayload, error) {
	newOrder := &domain.Order{
		OrderID:                fmt.Sprintf("gql_%d", time.Now().UnixNano()),
		CustomerID:             input.CustomerID,
		OrderStatus:            input.Status,
		OrderPurchaseTimestamp: time.Now(),
	}

	if err := r.Repo.CreateOrderTransaction(newOrder); err != nil {
		return nil, fmt.Errorf("failed to create order: %w", err)
	}

	return &model.CreateOrderPayload{
		OrderID: newOrder.OrderID,
		Success: true,
	}, nil
}

// =======================================================
// [TC 1, 7] 단순 조회
// =======================================================
func (r *queryResolver) GetSimpleOrder(ctx context.Context, id string) (*model.SimpleOrder, error) {
	order, err := r.Repo.GetSimpleOrder(id)
	if err != nil {
		if err == domain.ErrOrderNotFound {
			return nil, fmt.Errorf("order not found")
		}
		return nil, fmt.Errorf("internal server error")
	}

	return &model.SimpleOrder{
		OrderID:     order.OrderID,
		OrderStatus: order.OrderStatus,
	}, nil
}

// =======================================================
// [TC 2] 대용량 페이징
// =======================================================
func (r *queryResolver) GetOrders(ctx context.Context, limit *int, offset *int) ([]*model.SimpleOrder, error) {
	l := 100
	o := 0
	if limit != nil {
		l = *limit
	}
	if offset != nil {
		o = *offset
	}

	orders, err := r.Repo.GetOrdersWithPaging(l, o)
	if err != nil {
		return nil, fmt.Errorf("failed to fetch orders")
	}

	result := make([]*model.SimpleOrder, len(orders))
	for i, order := range orders {
		result[i] = &model.SimpleOrder{
			OrderID:     order.OrderID,
			OrderStatus: order.OrderStatus,
		}
	}

	return result, nil
}

// =======================================================
// [TC 3, 4, 5] 극한 조인 및 오버페칭 방어
// =======================================================
func (r *queryResolver) GetOrderDetails(ctx context.Context, id string) (*model.FullOrder, error) {
	order, err := r.Repo.GetOrderWithFullDetails(id)
	if err != nil {
		if err == domain.ErrOrderNotFound {
			return nil, fmt.Errorf("order not found")
		}
		return nil, fmt.Errorf("internal server error")
	}

	items := make([]*model.OrderItem, len(order.Items))
	for i, item := range order.Items {
		items[i] = &model.OrderItem{
			ProductID:   item.ProductID,
			Price:       item.Price,
			ProductName: item.Product.ProductCategoryName,
		}
	}

	return &model.FullOrder{
		OrderID:     order.OrderID,
		OrderStatus: order.OrderStatus,
		Items:       items,
		Customer: &model.Customer{
			CustomerCity:  order.Customer.CustomerCity,
			CustomerState: order.Customer.CustomerState,
		},
	}, nil
}

// Query, Mutation 리졸버 인터페이스 반환 함수들 (기존에 생성된 것 유지)
func (r *Resolver) Mutation() MutationResolver { return &mutationResolver{r} }
func (r *Resolver) Query() QueryResolver       { return &queryResolver{r} }

type mutationResolver struct{ *Resolver }
type queryResolver struct{ *Resolver }
