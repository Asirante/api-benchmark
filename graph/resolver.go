package graph

import "api-benchmark/internal/core/repository"

// This file will not be regenerated automatically.
//
// It serves as dependency injection for your app, add any dependencies you require here.

type Resolver struct {
	Repo *repository.OrderRepo
}
