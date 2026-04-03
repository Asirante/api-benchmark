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
	db, err := database.ConnectDB()
	if err != nil {
		log.Fatalf("DB 연결 실패: %v", err)
	}

	orderRepo := repository.NewOrderRepo(db)

	srv := handler.NewDefaultServer(graph.NewExecutableSchema(graph.Config{
		Resolvers: &graph.Resolver{
			Repo: orderRepo,
		},
	}))

	http.Handle("/", playground.Handler("GraphQL playground", "/query"))
	http.Handle("/query", srv)

	if err := http.ListenAndServe(":8081", nil); err != nil {
		log.Fatalf("GraphQL 서버 실행 실패: %v", err)
	}
}
