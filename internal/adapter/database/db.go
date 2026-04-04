package database

import (
	"fmt"
	"log"
	"os"
	"time"

	"github.com/joho/godotenv"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func ConnectDB() (*gorm.DB, error) {
	_ = godotenv.Load()

	host := getEnv("DB_HOST", "localhost")
	port := getEnv("DB_PORT", "5432")
	user := getEnv("DB_USER", "benchmark_user")
	pass := getEnv("DB_PASS", "benchmark_password")
	name := getEnv("DB_NAME", "olist_db")

	dsn := fmt.Sprintf("host=%s user=%s password=%s dbname=%s port=%s sslmode=disable TimeZone=UTC",
		host, user, pass, name, port)

	var db *gorm.DB
	var err error

	// DB 연결 재시도 로직
	for i := 0; i < 10; i++ {
		db, err = gorm.Open(postgres.Open(dsn), &gorm.Config{
			Logger:                 logger.Default.LogMode(logger.Error),
			SkipDefaultTransaction: true, // 성능 최적화를 위해 기본 트랜잭션 비활성화
		})

		if err == nil {
			sqlDB, sqlErr := db.DB()
			if sqlErr != nil {
				return nil, fmt.Errorf("connection pool setup failed: %w", sqlErr)
			}

			// 10,000 VU 스파이크 테스트를 위한 커넥션 풀 설정
			sqlDB.SetMaxOpenConns(500) // 최대 동시 연결 수
			sqlDB.SetMaxIdleConns(100) // 유휴 연결 유지 수
			sqlDB.SetConnMaxLifetime(1 * time.Hour)
			sqlDB.SetConnMaxIdleTime(10 * time.Minute)

			log.Printf("Database connected: %s:%s (MaxOpen: 500, MaxIdle: 100)\n", host, port)
			return db, nil
		}

		log.Printf("Waiting for database... (%d/10)\n", i+1)
		time.Sleep(2 * time.Second)
	}

	return nil, fmt.Errorf("database connection failed: %w", err)
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}
