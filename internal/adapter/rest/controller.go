package rest

import (
	"net/http"
	"strconv"

	"api-benchmark/internal/core/domain"
	"api-benchmark/internal/core/repository"

	"github.com/gin-gonic/gin"
)

// REST API 요청을 처리합니다.
type OrderController struct {
	repo *repository.OrderRepo
}

func NewOrderController(repo *repository.OrderRepo) *OrderController {
	return &OrderController{repo: repo}
}

// [TC 1 & 7] 단일 레코드 단순 조회
// GET /api/v1/orders/simple/:id
func (c *OrderController) GetSimpleOrder(ctx *gin.Context) {
	orderID := ctx.Param("id")

	order, err := c.repo.GetSimpleOrder(orderID)
	if err != nil {
		if err == domain.ErrOrderNotFound {
			ctx.JSON(http.StatusNotFound, gin.H{"error": "Order not found"})
			return
		}
		ctx.JSON(http.StatusInternalServerError, gin.H{"error": "Internal server error"})
		return
	}

	ctx.JSON(http.StatusOK, order)
}

// [TC 2] 대용량 페이징 조회
// GET /api/v1/orders?limit=1000&offset=0
func (c *OrderController) GetOrders(ctx *gin.Context) {
	// Query 파라미터 파싱 (기본값 설정)
	limitStr := ctx.DefaultQuery("limit", "100")
	offsetStr := ctx.DefaultQuery("offset", "0")

	limit, _ := strconv.Atoi(limitStr)
	offset, _ := strconv.Atoi(offsetStr)

	orders, err := c.repo.GetOrdersWithPaging(limit, offset)
	if err != nil {
		ctx.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to fetch orders"})
		return
	}

	ctx.JSON(http.StatusOK, orders)
}

// [TC 3] 언더페칭 시뮬레이션용 아이템 별도 조회
// GET /api/v1/orders/:id/items
func (c *OrderController) GetOrderItems(ctx *gin.Context) {
	orderID := ctx.Param("id")

	items, err := c.repo.GetItemsByOrderID(orderID)
	if err != nil {
		ctx.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to fetch order items"})
		return
	}

	ctx.JSON(http.StatusOK, items)
}

// [TC 4 & 5, TC 8] 극한의 다중 테이블 조인 (오버페칭 유발)
// GET /api/v1/orders/details/:id
func (c *OrderController) GetOrderDetails(ctx *gin.Context) {
	orderID := ctx.Param("id")

	order, err := c.repo.GetOrderWithFullDetails(orderID)
	if err != nil {
		if err == domain.ErrOrderNotFound {
			ctx.JSON(http.StatusNotFound, gin.H{"error": "Order not found"})
			return
		}
		ctx.JSON(http.StatusInternalServerError, gin.H{"error": "Internal server error"})
		return
	}

	// REST API의 단점: 클라이언트가 원하지 않는 데이터까지 거대한 JSON으로 모두 응답함
	ctx.JSON(http.StatusOK, order)
}

// [TC 6] 복합 트랜잭션 쓰기 (JSON 파싱 부하 측정)
// POST /api/v1/orders
func (c *OrderController) CreateOrder(ctx *gin.Context) {
	var newOrder domain.Order

	// JSON 페이로드를 Go 구조체로 변환 (역직렬화 오버헤드 발생 지점)
	if err := ctx.ShouldBindJSON(&newOrder); err != nil {
		ctx.JSON(http.StatusBadRequest, gin.H{"error": "Invalid request payload"})
		return
	}

	if err := c.repo.CreateOrderTransaction(&newOrder); err != nil {
		ctx.JSON(http.StatusInternalServerError, gin.H{"error": "Failed to create order"})
		return
	}

	ctx.JSON(http.StatusCreated, gin.H{"message": "Order created successfully"})
}
