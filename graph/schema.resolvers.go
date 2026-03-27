package graph

import (
	"context"
	"fmt"

	"api-benchmark/graph/model"
)

// Order는 단일 주문을 조회합니다.
func (r *queryResolver) Order(ctx context.Context, id string) (*model.Order, error) {
	// 1. 레포지토리에서 꽉 찬 데이터(Full Details)를 가져옵니다.
	// (가설 3: DB에서 다 가져와도 GraphQL이 메모리에서 필터링하느라 CPU를 얼마나 쓰는지 보기 위함)
	domainOrder, err := r.Repo.GetOrderWithFullDetails(id)
	if err != nil {
		return nil, err
	}

	// 2. Domain 모델을 GraphQL 모델로 변환 (Mapping)
	gqlOrder := &model.Order{
		OrderID:                domainOrder.OrderID,
		CustomerID:             domainOrder.CustomerID,
		OrderStatus:            domainOrder.OrderStatus,
		OrderPurchaseTimestamp: domainOrder.OrderPurchaseTimestamp,
	}

	// Customer 변환
	if domainOrder.Customer.CustomerID != "" {
		gqlOrder.Customer = &model.Customer{
			CustomerID:       domainOrder.Customer.CustomerID,
			CustomerUniqueID: domainOrder.Customer.CustomerUniqueID,
			CustomerCity:     domainOrder.Customer.CustomerCity,
			CustomerState:    domainOrder.Customer.CustomerState,
		}
	}

	return gqlOrder, nil
}

// Orders는 페이징 처리를 합니다.
func (r *queryResolver) Orders(ctx context.Context, limit *int, offset *int) ([]*model.Order, error) {
	// 벤치마킹 테스트를 위해 우선은 빈 배열 반환 (필요시 구현)
	return nil, fmt.Errorf("not implemented yet")
}

// Query returns QueryResolver implementation.
func (r *Resolver) Query() QueryResolver { return &queryResolver{r} }

type queryResolver struct{ *Resolver }
