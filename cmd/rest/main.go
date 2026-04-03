package main

import (
	"log"

	"api-benchmark/internal/adapter/database"
	"api-benchmark/internal/adapter/rest"
	"api-benchmark/internal/core/repository"
)

func main() {
	db, err := database.ConnectDB()
	if err != nil {
		log.Fatalf("DB 연결 실패: %v", err)
	}

	orderRepo := repository.NewOrderRepo(db)
	orderController := rest.NewOrderController(orderRepo)

	router := rest.SetupRouter(orderController)

	if err := router.Run(":8080"); err != nil {
		log.Fatalf("REST 서버 실행 실패: %v", err)
	}
}
