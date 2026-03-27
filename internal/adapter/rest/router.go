package rest

import (
	"github.com/gin-gonic/gin"
)

func SetupRouter(controller *OrderController) *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())

	v1 := r.Group("/api/v1")
	{
		orders := v1.Group("/orders")
		{
			orders.GET("", controller.GetOrders)
			orders.POST("", controller.CreateOrder)
			orders.GET("/simple/:id", controller.GetSimpleOrder)
			orders.GET("/:id/items", controller.GetOrderItems)
			orders.GET("/details/:id", controller.GetOrderDetails)
		}
	}

	return r
}
