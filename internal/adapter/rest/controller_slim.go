package rest

import (
	"net/http"

	"api-benchmark/internal/core/domain"

	"github.com/gin-gonic/gin"
)

// [실험 A] GraphQL TC5 쿼리와 동일한 필드·순서만 갖는 응답 구조체
type slimOrderItem struct {
	ProductID   string  `json:"product_id"`
	Price       float64 `json:"price"`
	ProductName string  `json:"product_name"`
}

type slimCustomer struct {
	CustomerCity  string `json:"customer_city"`
	CustomerState string `json:"customer_state"`
}

type slimOrder struct {
	OrderID     string          `json:"order_id"`
	OrderStatus string          `json:"order_status"`
	Items       []slimOrderItem `json:"items"`
	Customer    slimCustomer    `json:"customer"`
}

// [실험 A] TC5 응답 필드 축소 조건 (tc5_slim)
// GET /api/v1/orders/slim/:id
func (c *OrderController) GetOrderSlim(ctx *gin.Context) {
	orderID := ctx.Param("id")

	order, err := c.repo.GetOrderSlim(orderID)
	if err != nil {
		if err == domain.ErrOrderNotFound {
			ctx.JSON(http.StatusNotFound, gin.H{"error": "Order not found"})
			return
		}
		ctx.JSON(http.StatusInternalServerError, gin.H{"error": "Internal server error"})
		return
	}

	items := make([]slimOrderItem, len(order.Items))
	for i, item := range order.Items {
		items[i] = slimOrderItem{
			ProductID:   item.ProductID,
			Price:       item.Price,
			ProductName: item.Product.ProductCategoryName,
		}
	}

	ctx.JSON(http.StatusOK, slimOrder{
		OrderID:     order.OrderID,
		OrderStatus: order.OrderStatus,
		Items:       items,
		Customer: slimCustomer{
			CustomerCity:  order.Customer.CustomerCity,
			CustomerState: order.Customer.CustomerState,
		},
	})
}
