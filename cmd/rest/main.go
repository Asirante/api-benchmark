package main

import (
	"log"

	"api-benchmark/internal/adapter/database"
	"api-benchmark/internal/adapter/rest"
	"api-benchmark/internal/core/repository"
)

func main() {
	log.Println("🛠️ REST API 서버 초기화 중...")

	// 1. DB 연결
	db, err := database.ConnectDB()
	if err != nil {
		log.Fatalf("❌ DB 연결 실패: %v", err)
	}
	log.Println("✅ 데이터베이스 연결 성공")

	// 2. 공통 Repository 의존성 주입
	orderRepo := repository.NewOrderRepo(db)

	// 3. Controller 및 Router 초기화
	orderController := rest.NewOrderController(orderRepo)
	router := rest.SetupRouter(orderController)

	// 4. 서버 구동 (포트 8080)
	log.Println("🚀 REST API 서버가 포트 8080에서 실행되었습니다! (벤치마크 모드)")
	if err := router.Run(":8080"); err != nil {
		log.Fatalf("❌ 서버 실행 실패: %v", err)
	}
}
