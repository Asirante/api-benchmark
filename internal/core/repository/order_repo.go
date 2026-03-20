package repository

import (
	"errors"

	"api-benchmark/internal/core/domain"

	"gorm.io/gorm"
)

type OrderRepo struct {
	db *gorm.DB
}

func NewOrderRepo(db *gorm.DB) *OrderRepo {
	return &OrderRepo{db: db}
}

// [TC 1 & TC 7] 단일 레코드 단순 조회 (순수 직렬화 속도 및 에러 처리 측정)
func (r *OrderRepo) GetSimpleOrder(orderID string) (*domain.Order, error) {
	var order domain.Order
	err := r.db.Where("order_id = ?", orderID).First(&order).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, domain.ErrOrderNotFound
		}
		return nil, domain.ErrDatabaseQuery
	}
	return &order, nil
}

// [TC 2] 대용량 페이로드 페이징 조회 (메모리 및 네트워크 대역폭 한계 측정)
// 조인 없이 Order 데이터만 1,000개씩 긁어와서 무거운 페이로드를 만듭니다.
func (r *OrderRepo) GetOrdersWithPaging(limit int, offset int) ([]domain.Order, error) {
	var orders []domain.Order
	err := r.db.Limit(limit).Offset(offset).Find(&orders).Error
	if err != nil {
		return nil, domain.ErrDatabaseQuery
	}
	return orders, nil
}

// [TC 3] 1:N 얕은 조인 (REST의 언더페칭/N+1 문제 시뮬레이션용)
// 주문 정보와 그에 속한 아이템 목록까지만 얕게 조인합니다.
func (r *OrderRepo) GetOrderWithShallowJoin(orderID string) (*domain.Order, error) {
	var order domain.Order
	err := r.db.Preload("Items").Where("order_id = ?", orderID).First(&order).Error
	if err != nil {
		if errors.Is(err, gorm.ErrRecordNotFound) {
			return nil, domain.ErrOrderNotFound
		}
		return nil, domain.ErrDatabaseQuery
	}
	return &order, nil
}

// [TC 3 보완] 언더페칭 시뮬레이션을 위한 추가 API용 쿼리
// 클라이언트가 주문 정보만 받고 데이터가 부족해서 아이템 목록을 별도로 추가 요청할 때 사용합니다.
func (r *OrderRepo) GetItemsByOrderID(orderID string) ([]domain.OrderItem, error) {
	var items []domain.OrderItem

	// 특정 order_id에 해당하는 OrderItem들만 DB에서 쏙 뽑아옴
	err := r.db.Where("order_id = ?", orderID).Find(&items).Error
	if err != nil {
		return nil, domain.ErrDatabaseQuery
	}

	return items, nil
}

// [TC 4 & TC 5] 극한의 7+ 다중 테이블 조인
// DB에서 연관된 모든 데이터를 끌어옵니다. (REST는 이걸 다 응답해서 오버페칭 발생, GraphQL은 필터링하며 CPU 소모)
func (r *OrderRepo) GetOrderWithFullDetails(orderID string) (*domain.Order, error) {
	var order domain.Order
	err := r.db.
		Preload("Customer").
		Preload("Items").
		Preload("Items.Product").
		Preload("Items.Seller").
		Preload("Payments").
		Preload("Reviews").
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

// [TC 6] 복합 트랜잭션 쓰기 (JSON vs Protobuf 파싱 및 DB 쓰기 속도 비교)
// 주문, 아이템, 결제 정보를 하나의 트랜잭션으로 묶어서 INSERT 합니다.
func (r *OrderRepo) CreateOrderTransaction(order *domain.Order) error {
	// GORM의 트랜잭션 블록 안에서 실행
	return r.db.Transaction(func(tx *gorm.DB) error {
		// Order 기본 정보 저장
		if err := tx.Create(order).Error; err != nil {
			return err
		}
		// (GORM은 order 구조체 안에 Items, Payments가 들어있으면 자동으로 함께 Insert 해줍니다.)
		return nil
	})
}
