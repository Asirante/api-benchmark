package database

import (
	"fmt"
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
			fmt.Printf("✅ Connected to Database: %s:%s\n", host, port)
			return db, nil
		}

		fmt.Printf("⏳ DB 대기 중... (%d/10)\n", i+1)
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
