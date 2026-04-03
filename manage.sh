#!/bin/bash

# API 아키텍처 벤치마킹 통합 관리 스크립트
# 권한 부여: chmod +x manage.sh
# 실행 방법: ./manage.sh [명령어]

COMMAND=$1

case "$COMMAND" in
  start)
    echo "[진행] 벤치마크 서버 환경 빌드 및 백그라운드 실행..."
    docker compose up -d --build
    echo "[완료] 서버가 실행되었습니다. 'bm logs'로 상태를 확인하십시오."
    ;;
  
  stop)
    echo "[진행] 컨테이너 중지 및 네트워크 해제..."
    docker compose down
    echo "[완료] 서버가 중지되었습니다."
    ;;
  
  restart)
    echo "[진행] 서버 재시작 및 최신 코드 반영..."
    docker compose down
    docker compose up -d --build
    echo "[완료] 재시작이 완료되었습니다."
    ;;
  
  clean)
    echo "[진행] 도커 환경 초기화 진행 중..."
    echo "[경고] 데이터베이스 볼륨 및 빌드된 이미지가 삭제됩니다."
    docker compose down -v --rmi all
    echo "[완료] 초기화가 완료되었습니다."
    ;;

  logs)
    echo "[로그] 실시간 컨테이너 로그 출력 (종료: Ctrl+C)"
    docker compose logs -f
    ;;

  test)
    VUS=${2:-1000}
    echo "[테스트] 기본 아키텍처(REST, GraphQL, gRPC) 벤치마크 시작 (목표 VUs: ${VUS})"
    echo "데이터베이스 초기화 중..."
    docker exec benchmark_influxdb influx -execute "DROP DATABASE k6"
    docker exec benchmark_influxdb influx -execute "CREATE DATABASE k6"
    
    echo "부하 생성 시작 (benchmark.js 실행)"
    docker run --rm -i \
      --ulimit nofile=65535:65535 \
      -v $(pwd):/app -w /app \
      --network api-benchmark_default \
      -e VUS=$VUS \
      grafana/k6 run --out influxdb=http://benchmark_influxdb:8086/k6 benchmark.js
    
    echo "[완료] 테스트가 종료되었습니다."
    ;;
    
  test-proxy)
    VUS=${2:-1000}
    echo "[테스트] Envoy 프록시 오버헤드 벤치마크 시작 (목표 VUs: ${VUS})"
    echo "데이터베이스 초기화 중..."
    docker exec benchmark_influxdb influx -execute "DROP DATABASE k6"
    docker exec benchmark_influxdb influx -execute "CREATE DATABASE k6"
    
    echo "부하 생성 시작 (benchmark_envoy.js 실행)"
    docker run --rm -i \
      --ulimit nofile=65535:65535 \
      -v $(pwd):/app -w /app \
      --network api-benchmark_default \
      -e VUS=$VUS \
      grafana/k6 run --out influxdb=http://benchmark_influxdb:8086/k6 benchmark_envoy.js
    
    echo "[완료] 프록시 테스트가 종료되었습니다."
    ;;

  test-spike)
    echo "[테스트] 극단적 스파이크(Spike) 부하 테스트 시작 (목표 VUs: 최대 10,000)"
    echo "데이터베이스 초기화 중..."
    docker exec benchmark_influxdb influx -execute "DROP DATABASE k6"
    docker exec benchmark_influxdb influx -execute "CREATE DATABASE k6"
    
    echo "스파이크 부하 생성 시작 (benchmark_tc8.js 실행)"
    docker run --rm -i \
      --ulimit nofile=65535:65535 \
      -v $(pwd):/app -w /app \
      --network api-benchmark_default \
      grafana/k6 run --out influxdb=http://benchmark_influxdb:8086/k6 benchmark_tc8.js
    
    echo "[완료] 스파이크 테스트가 종료되었습니다."
    ;;

  *)
    echo "사용법: ./manage.sh [명령어]"
    echo "------------------------------------------------------------"
    echo "  start      : 컨테이너 새로 빌드 및 실행"
    echo "  stop       : 컨테이너 중지"
    echo "  restart    : 중지 후 다시 빌드 및 실행"
    echo "  clean      : 컨테이너, 이미지, DB 볼륨 완전 삭제"
    echo "  logs       : 컨테이너 실시간 로그 출력"
    echo "  test       : [TC1~7] 기본 아키텍처 비교 부하 테스트 (기본 VUs 1000)"
    echo "  test-proxy : [TC9] Envoy 프록시 오버헤드 측정 테스트 (기본 VUs 1000)"
    echo "  test-spike : [TC8] 스파이크 생존력 평가 테스트 (최대 10,000 VUs)"
    exit 1
    ;;
esac