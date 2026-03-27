package main

import (
	"log"
	"net/http"

	"api-benchmark/graph"
	"api-benchmark/internal/adapter/database"
	"api-benchmark/internal/core/repository"

	"github.com/99designs/gqlgen/graphql/handler"
	"github.com/99designs/gqlgen/graphql/playground"
)

func main() {
	log.Println("🛠️ GraphQL API 서버 초기화 중...")

	// 1. 공통 DB 연결
	db, err := database.ConnectDB()
	if err != nil {
		log.Fatalf("❌ DB 연결 실패: %v", err)
	}

	// 2. 레포지토리 생성
	orderRepo := repository.NewOrderRepo(db)

	// 3. GraphQL 서버 세팅
	srv := handler.NewDefaultServer(graph.NewExecutableSchema(graph.Config{
		Resolvers: &graph.Resolver{
			Repo: orderRepo,
		},
	}))

	// 4. 라우팅 (Gin 없이 순수 net/http 사용)
	http.Handle("/", playground.Handler("GraphQL playground", "/query"))
	http.Handle("/query", srv)

	log.Println("🚀 GraphQL 서버가 포트 8081에서 실행되었습니다! (Playground: http://localhost:8081/)")
	if err := http.ListenAndServe(":8081", nil); err != nil {
		log.Fatalf("❌ GraphQL 서버 실행 실패: %v", err)
	}
}
