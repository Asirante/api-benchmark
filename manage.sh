#!/bin/bash

# 코딩 파트너가 작성한 벤치마킹 Docker 관리 스크립트 🐳
# 주의사항 : chmod +x manage.sh 입력 후 사용 가능
# 사용법: ./manage.sh [명령어]
# 팁: echo "alias bm='./manage.sh'" >> ~/.bashrc
#     source ~/.bashrc
#     후 사용시 bm으로 사용 가능

COMMAND=$1

case "$COMMAND" in
  start)
    echo "🚀 벤치마크 서버 환경을 빌드하고 백그라운드에서 실행합니다..."
    # --build 옵션: Go 코드를 수정하고 다시 실행할 때 최신 코드가 반영되도록 강제 빌드합니다.
    docker compose up -d --build
    echo "✅ 모든 서버가 실행되었습니다. 'bm logs'로 상태를 확인하세요."
    ;;
  
  stop)
    echo "🛑 컨테이너를 중지하고 네트워크를 해제합니다..."
    docker compose down
    echo "✅ 서버가 완전히 중지되었습니다."
    ;;
  
  restart)
    echo "🔄 서버를 중지하고 새 코드로 다시 빌드하여 재시작합니다..."
    docker compose down
    docker compose up -d --build
    echo "✅ 재시작이 완료되었습니다."
    ;;
  
  clean)
    echo "🧹 도커 환경을 완전히 초기화합니다..."
    echo "⚠️ 주의: DB 볼륨(저장된 데이터)과 빌드된 이미지가 모두 삭제됩니다."
    # -v: 볼륨(DB 데이터) 삭제 / --rmi all: 관련된 모든 도커 이미지 삭제
    docker compose down -v --rmi all
    echo "✅ 초기화 완료! 다시 시작하려면 'bm start'를 입력하세요."
    ;;

  logs)
    echo "📋 실시간 로그를 출력합니다. (종료하려면 Ctrl+C)"
    docker compose logs -f
    ;;

  test)
    # 두 번째 인자가 없으면 기본값 1000을 사용합니다.
    VUS=${2:-1000}
    
    echo "🔫 K6 부하 테스트를 시작합니다... (목표 가상 유저: ${VUS}명)"
    echo "🧹 1/2: InfluxDB의 기존 k6 데이터를 초기화합니다..."
    docker exec benchmark_influxdb influx -execute "DROP DATABASE k6"
    docker exec benchmark_influxdb influx -execute "CREATE DATABASE k6"
    
    echo "🚀 2/2: K6 컨테이너를 생성하여 타격을 시작합니다! (Grafana 화면을 확인하세요)"
    
    docker run --rm -i \
      --ulimit nofile=65535:65535 \
      -v $(pwd):/app -w /app \
      --network api-benchmark_default \
      -e VUS=$VUS \
      grafana/k6 run --out influxdb=http://benchmark_influxdb:8086/k6 benchmark.js
    
    echo "✅ 테스트가 완료되었습니다! Grafana 대시보드에서 결과를 확인하세요."
    ;;
    
  test-proxy)
    VUS=${2:-1000}
    echo "🛡️ Envoy 프록시 오버헤드 전용 벤치마크를 시작합니다... (목표 가상 유저: ${VUS}명)"
    echo "🧹 InfluxDB 데이터를 초기화합니다..."
    docker exec benchmark_influxdb influx -execute "DROP DATABASE k6"
    docker exec benchmark_influxdb influx -execute "CREATE DATABASE k6"
    
    echo "🚀 프록시 타격 시작! (benchmark_envoy.js 실행)"
    docker run --rm -i \
      --ulimit nofile=65535:65535 \
      -v $(pwd):/app -w /app \
      --network api-benchmark_default \
      -e VUS=$VUS \
      grafana/k6 run --out influxdb=http://benchmark_influxdb:8086/k6 benchmark_envoy.js
    
    echo "✅ 프록시 오버헤드 테스트 완료!"
    ;;
  *)
    echo "⚠️ 올바른 명령어를 입력해주세요."
    echo "사용법: bm [start | stop | restart | clean | logs | test]"
    echo "------------------------------------------------------------"
    echo "  start   : 컨테이너 새로 빌드 및 실행 (테스트 시작 전)"
    echo "  stop    : 컨테이너 중지 (잠시 쉴 때)"
    echo "  restart : 중지 후 다시 빌드 및 실행 (Go 코드 수정 후)"
    echo "  clean   : 컨테이너, 이미지, DB 볼륨 완전 삭제 (DB를 처음부터 다시 세팅할 때)"
    echo "  logs    : 모든 서버의 실시간 로그 보기 (에러 확인할 때)"
    echo "  test       : 기본 아키텍처 비교 테스트 (REST vs GQL vs gRPC)"
    echo "  test-proxy : 🛡️ [TC9] Envoy 프록시 오버헤드 집중 분석 테스트"
    exit 1
    ;;
esac