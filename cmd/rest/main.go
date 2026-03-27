package main

import (
	"log"

	"api-benchmark/internal/adapter/database"
	"api-benchmark/internal/adapter/rest"
	"api-benchmark/internal/core/repository"
)

func main() {
	log.Println("🛠️ REST API 서버 초기화 중...")

	db, err := database.ConnectDB()
	if err != nil {
		log.Fatalf("❌ DB 연결 실패: %v", err)
	}

	orderRepo := repository.NewOrderRepo(db)
	orderController := rest.NewOrderController(orderRepo)

	// 이제 다시 Controller 1개만 받습니다.
	router := rest.SetupRouter(orderController)

	log.Println("🚀 REST 서버가 포트 8080에서 실행되었습니다!")
	if err := router.Run(":8080"); err != nil {
		log.Fatalf("❌ REST 서버 실행 실패: %v", err)
	}
}
