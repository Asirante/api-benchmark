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

	for i := 0; i < 10; i++ {
		db, err = gorm.Open(postgres.Open(dsn), &gorm.Config{
			Logger:                 logger.Default.LogMode(logger.Error),
			SkipDefaultTransaction: true,
		})

		if err == nil {
			sqlDB, sqlErr := db.DB()
			if sqlErr != nil {
				return nil, fmt.Errorf("DB 커넥션 풀 설정 실패: %w", sqlErr)
			}
			sqlDB.SetMaxOpenConns(100)
			sqlDB.SetMaxIdleConns(20)
			sqlDB.SetConnMaxLifetime(30 * time.Minute)
			sqlDB.SetConnMaxIdleTime(5 * time.Minute)

			log.Printf("Connected to Database: %s:%s (pool: maxOpen=100, maxIdle=20)\n", host, port)
			return db, nil
		}

		log.Printf("DB 대기 중... (%d/10): %v\n", i+1, err)
		time.Sleep(2 * time.Second)
	}

	return nil, fmt.Errorf("DB 연결 실패: %w", err)
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}
