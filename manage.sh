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
    docker-compose up -d --build
    echo "✅ 모든 서버가 실행되었습니다. './manage.sh logs'로 상태를 확인하세요."
    ;;
  
  stop)
    echo "🛑 컨테이너를 중지하고 네트워크를 해제합니다..."
    docker-compose down
    echo "✅ 서버가 완전히 중지되었습니다."
    ;;
  
  restart)
    echo "🔄 서버를 중지하고 새 코드로 다시 빌드하여 재시작합니다..."
    docker-compose down
    docker-compose up -d --build
    echo "✅ 재시작이 완료되었습니다."
    ;;
  
  clean)
    echo "🧹 도커 환경을 완전히 초기화합니다..."
    echo "⚠️ 주의: DB 볼륨(저장된 데이터)과 빌드된 이미지가 모두 삭제됩니다."
    # -v: 볼륨(DB 데이터) 삭제 / --rmi all: 관련된 모든 도커 이미지 삭제
    docker-compose down -v --rmi all
    echo "✅ 초기화 완료! 다시 시작하려면 './manage.sh start'를 입력하세요."
    ;;

  logs)
    echo "📋 실시간 로그를 출력합니다. (종료하려면 Ctrl+C)"
    docker-compose logs -f
    ;;

  *)
    echo "⚠️ 올바른 명령어를 입력해주세요."
    echo "사용법: ./manage.sh [start | stop | restart | clean | logs]"
    echo "------------------------------------------------------------"
    echo "  start   : 컨테이너 새로 빌드 및 실행 (테스트 시작 전)"
    echo "  stop    : 컨테이너 중지 (잠시 쉴 때)"
    echo "  restart : 중지 후 다시 빌드 및 실행 (Go 코드 수정 후)"
    echo "  clean   : 컨테이너, 이미지, DB 볼륨 완전 삭제 (DB를 처음부터 다시 세팅할 때)"
    echo "  logs    : 모든 서버의 실시간 로그 보기 (에러 확인할 때)"
    exit 1
    ;;
esac