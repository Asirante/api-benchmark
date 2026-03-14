package database

import (
	"fmt"
	"log"

	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

// ConnectDB 는 PostgreSQL 데이터베이스에 연결하고 GORM 객체를 반환합니다.
func ConnectDB() *gorm.DB {
	// Docker Compose 설정과 일치하는 DSN (Data Source Name)
	dsn := "host=localhost user=benchmark_user password=benchmark_password dbname=olist_db port=5432 sslmode=disable TimeZone=UTC"

	db, err := gorm.Open(postgres.Open(dsn), &gorm.Config{
		// 벤치마크 테스트 성능을 위해 로그 출력을 에러만 나오게 최소화
		Logger: logger.Default.LogMode(logger.Error),
		// 성능 최적화: 트랜잭션 자동 생성 끄기 (읽기 위주의 벤치마크이므로 속도 향상)
		SkipDefaultTransaction: true,
	})

	if err != nil {
		log.Fatalf("Failed to connect to database: %v", err)
	}

	fmt.Println("✅ Successfully connected to the database!")
	return db
}
