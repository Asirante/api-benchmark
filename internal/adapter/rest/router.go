package rest

import (
	"os"

	"github.com/gin-gonic/gin"
)

// SetupRouter는 Gin 엔진을 초기화하고 라우팅을 설정합니다.
func SetupRouter(controller *OrderController) *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())

	// GIN_LOG=1 환경변수가 설정된 경우에만 요청 로그 출력
	if os.Getenv("GIN_LOG") == "1" {
		r.Use(gin.Logger())
	}

	// API v1 그룹 생성
	v1 := r.Group("/api/v1")
	{
		// [TC 1, 7] 단순 조회
		v1.GET("/orders/simple/:id", controller.GetSimpleOrder)

		// [TC 2] 대용량 페이징
		v1.GET("/orders", controller.GetOrders)

		// [TC 3] 언더페칭 (N+1 시뮬레이션용 - 아이템만 따로 호출)
		v1.GET("/orders/:id/items", controller.GetOrderItems)

		// [TC 4, 5] 극한 조인 (무거운 전체 데이터 반환)
		v1.GET("/orders/details/:id", controller.GetOrderDetails)

		// [TC 6] 트랜잭션 쓰기
		v1.POST("/orders", controller.CreateOrder)
	}

	return r
}
