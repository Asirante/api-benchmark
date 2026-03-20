package rest

import (
	"github.com/gin-gonic/gin"
)

// SetupRouter는 벤치마킹을 위해 불필요한 미들웨어를 제거한 순수 API 라우터를 생성합니다.
func SetupRouter(controller *OrderController) *gin.Engine {
	// 벤치마크 테스트 결과의 공정성을 위해 로깅 I/O 오버헤드 제거
	gin.SetMode(gin.ReleaseMode)

	// Default 대신 New를 사용하여 기본 로거를 뺍니다. Panic 복구 미들웨어만 추가.
	r := gin.New()
	r.Use(gin.Recovery())

	// API 버저닝 및 엔드포인트 그룹화
	v1 := r.Group("/api/v1")
	{
		orders := v1.Group("/orders")
		{
			orders.GET("", controller.GetOrders)                   // TC 2: 페이징 조회
			orders.POST("", controller.CreateOrder)                // TC 6: 복합 쓰기
			orders.GET("/simple/:id", controller.GetSimpleOrder)   // TC 1 & 7: 단순 조회
			orders.GET("/:id/items", controller.GetOrderItems)     // TC 3: 언더페칭 조회
			orders.GET("/details/:id", controller.GetOrderDetails) // TC 4, 5, 8: 극한 조인
		}
	}

	return r
}
