package database

import (
	"database/sql"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"strconv"
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
			// [실험 D] 풀 크기 스윕을 위해 환경변수로 조절 (기본값은 기존 500 / 100)
			maxOpen := getEnvInt("DB_MAX_OPEN_CONNS", 500)
			maxIdle := getEnvInt("DB_MAX_IDLE_CONNS", 100)
			sqlDB.SetMaxOpenConns(maxOpen) // 최대 동시 연결 수
			sqlDB.SetMaxIdleConns(maxIdle) // 유휴 연결 유지 수 (database/sql 이 MaxOpen 을 넘지 않게 자동으로 낮춤)
			sqlDB.SetConnMaxLifetime(1 * time.Hour)
			sqlDB.SetConnMaxIdleTime(10 * time.Minute)

			if maxIdle > maxOpen {
				maxIdle = maxOpen
			}
			log.Printf("Database connected: %s:%s (MaxOpen: %d, MaxIdle: %d)\n", host, port, maxOpen, maxIdle)

			// [실험 D] DB_POOL_STATS_INTERVAL (예: 1s) 이 있으면 풀 통계를 주기적으로 한 줄 JSON 으로 기록
			if interval, perr := time.ParseDuration(getEnv("DB_POOL_STATS_INTERVAL", "")); perr == nil && interval > 0 {
				go logPoolStats(sqlDB, interval)
			}
			return db, nil
		}

		log.Printf("Waiting for database... (%d/10)\n", i+1)
		time.Sleep(2 * time.Second)
	}

	return nil, fmt.Errorf("database connection failed: %w", err)
}

// logPoolStats 는 database/sql 풀 통계를 interval 마다 "[pool] {...}" 형식으로 출력합니다.
// WaitCount/WaitDuration 은 풀이 가득 차 커넥션을 기다린 누적 횟수·시간, MaxIdleClosed 는 유휴 한도 초과로 닫힌 누적 연결 수입니다.
func logPoolStats(sqlDB *sql.DB, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for t := range ticker.C {
		st := sqlDB.Stats()
		line, _ := json.Marshal(map[string]int64{
			"unix_ms":              t.UnixMilli(),
			"max_open":             int64(st.MaxOpenConnections),
			"open":                 int64(st.OpenConnections),
			"in_use":               int64(st.InUse),
			"idle":                 int64(st.Idle),
			"wait_count":           st.WaitCount,
			"wait_duration_us":     st.WaitDuration.Microseconds(),
			"max_idle_closed":      st.MaxIdleClosed,
			"max_idle_time_closed": st.MaxIdleTimeClosed,
			"max_lifetime_closed":  st.MaxLifetimeClosed,
		})
		log.Printf("[pool] %s", line)
	}
}

func getEnvInt(key string, fallback int) int {
	value := getEnv(key, "")
	if value == "" {
		return fallback
	}
	n, err := strconv.Atoi(value)
	if err != nil || n <= 0 {
		log.Printf("invalid %s=%q, using %d\n", key, value, fallback)
		return fallback
	}
	return n
}

func getEnv(key, fallback string) string {
	if value, ok := os.LookupEnv(key); ok {
		return value
	}
	return fallback
}
