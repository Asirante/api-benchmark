package domain

import "time"

// 1. 고객 (Customer)
type Customer struct {
	CustomerID            string `gorm:"primaryKey;column:customer_id"`
	CustomerUniqueID      string `gorm:"column:customer_unique_id"`
	CustomerZipCodePrefix string `gorm:"column:customer_zip_code_prefix"`
	CustomerCity          string `gorm:"column:customer_city"`
	CustomerState         string `gorm:"column:customer_state"`
}

func (Customer) TableName() string { return "olist_customers_dataset" }

// 2. 판매자 (Seller)
type Seller struct {
	SellerID            string `gorm:"primaryKey;column:seller_id"`
	SellerZipCodePrefix string `gorm:"column:seller_zip_code_prefix"`
	SellerCity          string `gorm:"column:seller_city"`
	SellerState         string `gorm:"column:seller_state"`
}

func (Seller) TableName() string { return "olist_sellers_dataset" }

// 3. 상품 (Product)
type Product struct {
	ProductID                string `gorm:"primaryKey;column:product_id"`
	ProductCategoryName      string `gorm:"column:product_category_name"`
	ProductNameLength        int    `gorm:"column:product_name_length"`
	ProductDescriptionLength int    `gorm:"column:product_description_length"`
	ProductPhotosQty         int    `gorm:"column:product_photos_qty"`
	ProductWeightG           int    `gorm:"column:product_weight_g"`
	ProductLengthCm          int    `gorm:"column:product_length_cm"`
	ProductHeightCm          int    `gorm:"column:product_height_cm"`
	ProductWidthCm           int    `gorm:"column:product_width_cm"`
}

func (Product) TableName() string { return "olist_products_dataset" }

// 4. 주문 (Order) - 핵심 허브 테이블
type Order struct {
	OrderID                    string    `gorm:"primaryKey;column:order_id"`
	CustomerID                 string    `gorm:"column:customer_id"`
	Customer                   Customer  `gorm:"foreignKey:CustomerID"` // 1:1 관계
	OrderStatus                string    `gorm:"column:order_status"`
	OrderPurchaseTimestamp     time.Time `gorm:"column:order_purchase_timestamp"`
	OrderApprovedAt            time.Time `gorm:"column:order_approved_at"`
	OrderDeliveredCarrierDate  time.Time `gorm:"column:order_delivered_carrier_date"`
	OrderDeliveredCustomerDate time.Time `gorm:"column:order_delivered_customer_date"`
	OrderEstimatedDeliveryDate time.Time `gorm:"column:order_estimated_delivery_date"`

	Items    []OrderItem    `gorm:"foreignKey:OrderID"`
	Payments []OrderPayment `gorm:"foreignKey:OrderID"`
	Reviews  []OrderReview  `gorm:"foreignKey:OrderID"`
}

func (Order) TableName() string { return "olist_orders_dataset" }

// 5. 주문 상세 아이템 (Order Item)
type OrderItem struct {
	OrderID           string    `gorm:"primaryKey;column:order_id"`
	OrderItemID       int       `gorm:"primaryKey;column:order_item_id"`
	ProductID         string    `gorm:"column:product_id"`
	Product           Product   `gorm:"foreignKey:ProductID"` // 1:1 관계
	SellerID          string    `gorm:"column:seller_id"`
	Seller            Seller    `gorm:"foreignKey:SellerID"` // 1:1 관계
	ShippingLimitDate time.Time `gorm:"column:shipping_limit_date"`
	Price             float64   `gorm:"column:price"`
	FreightValue      float64   `gorm:"column:freight_value"`
}

func (OrderItem) TableName() string { return "olist_order_items_dataset" }

// 6. 결제 내역 (Order Payment)
type OrderPayment struct {
	OrderID             string  `gorm:"column:order_id"`
	PaymentSequential   int     `gorm:"column:payment_sequential"`
	PaymentType         string  `gorm:"column:payment_type"`
	PaymentInstallments int     `gorm:"column:payment_installments"`
	PaymentValue        float64 `gorm:"column:payment_value"`
}

func (OrderPayment) TableName() string { return "olist_order_payments_dataset" }

// 7. 리뷰 (Order Review)
type OrderReview struct {
	ReviewID              string    `gorm:"column:review_id"`
	OrderID               string    `gorm:"column:order_id"`
	ReviewScore           int       `gorm:"column:review_score"`
	ReviewCommentTitle    *string   `gorm:"column:review_comment_title"`   // NULL 허용
	ReviewCommentMessage  *string   `gorm:"column:review_comment_message"` // NULL 허용
	ReviewCreationDate    time.Time `gorm:"column:review_creation_date"`
	ReviewAnswerTimestamp time.Time `gorm:"column:review_answer_timestamp"`
}

func (OrderReview) TableName() string { return "olist_order_reviews_dataset" }
