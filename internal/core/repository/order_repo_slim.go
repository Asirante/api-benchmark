package repository

import (
	"errors"

	"api-benchmark/internal/core/domain"

	"gorm.io/gorm"
)

// [실험 A] TC5 응답 필드 축소 조건
// GetOrderWithFullDetails와 같은 Preload 경로를 쓰되, GraphQL TC5 쿼리가 선택하는
// 필드(order_id, order_status, items{product_id, price, product_name},
// customer{customer_city, customer_state})에 필요한 테이블·컬럼만 조회합니다.
// - Seller, Payments, Reviews 테이블은 조회하지 않음 (7회 → 4회 쿼리)
// - 연관 매핑에 필요한 키 컬럼(order_id, customer_id, order_item_id, product_id)은 포함
// - product_name 은 기존 리졸버와 동일하게 product_category_name 컬럼에서 가져옴
func (r *OrderRepo) GetOrderSlim(orderID string) (*domain.Order, error) {
	var order domain.Order
	err := r.db.
		Select("order_id", "customer_id", "order_status").
		Preload("Customer", func(db *gorm.DB) *gorm.DB {
			return db.Select("customer_id", "customer_city", "customer_state")
		}).
		Preload("Items", func(db *gorm.DB) *gorm.DB {
			return db.Select("order_id", "order_item_id", "product_id", "price")
		}).
		Preload("Items.Product", func(db *gorm.DB) *gorm.DB {
			return db.Select("product_id", "product_category_name")
		}).
		Where("order_id = ?", orderID).
		First(&order).Error

	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, domain.ErrOrderNotFound
		}
		return nil, domain.ErrDatabaseQuery
	}
	return &order, nil
}
