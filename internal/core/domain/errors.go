package domain

import (
	"crypto/rand"
	"errors"
	"fmt"
)

// API 벤치마크에서 공통으로 사용할 에러 정의 (TC 7 용도)
var (
	ErrOrderNotFound = errors.New("order not found")
	ErrInvalidInput  = errors.New("invalid input parameter")
	ErrDatabaseQuery = errors.New("database query failed")
)

// GenerateOrderID는 UUID v4 기반의 고유한 주문 ID를 생성합니다.
func GenerateOrderID(prefix string) string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10
	return fmt.Sprintf("%s_%x%x%x%x%x", prefix, b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}
