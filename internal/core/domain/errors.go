package domain

import "errors"

// API 벤치마크에서 공통으로 사용할 에러 정의 (TC 7 용도)
var (
	ErrOrderNotFound = errors.New("order not found")
	ErrInvalidInput  = errors.New("invalid input parameter")
	ErrDatabaseQuery = errors.New("database query failed")
)
