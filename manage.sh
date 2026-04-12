#!/bin/bash

# API 아키텍처 벤치마킹 통합 관리 스크립트 (v8.0 - 에러율 분석 + 백업 복원 지원)
# 권한 부여: chmod +x manage.sh

COMMAND=$1
VUS_ARG=${2:-1000} # 두 번째 인자가 없으면 기본 1000 VUs
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 인플럭스 DB 연결 정보
INFLUX_DB_NAME="k6"
INFLUX_URL="http://benchmark_influxdb:8086"
BACKUP_DIR="./influxdb_backups"
CSV_DIR="./csv_results"

# [핵심 1] DB 상태 체크 및 자동 생성
init_influx_db() {
    echo "[진행] InfluxDB 컨테이너 상태 및 데이터베이스 확인 중..."
    
    if ! docker ps | grep -q benchmark_influxdb; then
        echo "[에러] benchmark_influxdb 컨테이너가 실행 중이지 않습니다. './manage.sh start'를 먼저 실행하세요."
        exit 1
    fi

    docker exec benchmark_influxdb influx -execute "CREATE DATABASE $INFLUX_DB_NAME"
    if [ $? -eq 0 ]; then
        echo "[완료] '$INFLUX_DB_NAME' 데이터베이스 준비 완료."
    else
        echo "[에러] 데이터베이스 생성/연결 실패"
        exit 1
    fi
}

# [핵심 2] 바이너리 데이터 추출 (백업) 함수
export_data() {
    local prefix=${1:-"k6_backup"}
    echo "[진행] InfluxDB 바이너리 데이터 백업을 시작합니다..."
    
    mkdir -p $BACKUP_DIR
    local backup_name="${prefix}_${TIMESTAMP}"
    local container_backup_path="/var/lib/influxdb/${backup_name}"
    
    echo "  - 컨테이너 내부 백업 생성 중..."
    docker exec benchmark_influxdb influxd backup -portable -database $INFLUX_DB_NAME $container_backup_path
    
    echo "  - 로컬 환경($BACKUP_DIR)으로 데이터 복사 중..."
    docker cp benchmark_influxdb:$container_backup_path "${BACKUP_DIR}/${backup_name}"
    
    echo "  - 컨테이너 내부 찌꺼기 삭제 중..."
    docker exec benchmark_influxdb rm -rf $container_backup_path
    
    echo "[완료] 바이너리 데이터 백업 완료. 경로: ${BACKUP_DIR}/${backup_name}"
}

# [핵심 3] CSV 다중 추출 함수 (세션 분리 기능 추가)
export_csv() {
    local mode=$1
    local current_csv_dir="${CSV_DIR}/export_${TIMESTAMP}"
    mkdir -p "$current_csv_dir"

    echo "============================================================"
    echo "  [진행] InfluxDB 데이터를 CSV로 추출합니다. (한국 시간 기준)"
    
    # 쿼리 조건 설정 (current면 방금 실행한 테스트 세션만, all이면 전체)
    local condition=""
    if [ "$mode" == "current" ]; then
        echo "  - 추출 범위: [방금 실행된 테스트 세션] 전용 데이터만 단독 추출"
        condition="WHERE \"session_id\"='${TIMESTAMP}'"
    elif [ -z "$mode" ] || [ "$mode" == "all" ]; then
        echo "  - 추출 범위: 역대 저장된 [전체 데이터]"
    else
        echo "  - 추출 범위: [VUs = ${mode}] 조건에 맞는 데이터만"
        condition="WHERE \"vus_group\"='${mode}'"
    fi
    echo "============================================================"

    # 뽑아낼 핵심 지표들 (성능 + 에러율)
    local metrics=("http_req_duration" "grpc_req_duration" "http_reqs" "checks" "http_req_failed" "vus")
    
    for metric in "${metrics[@]}"; do
        echo "  - [${metric}] 데이터 추출 중..."
        
        local query="SELECT \"time\", \"api\", \"tc\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" ${condition} tz('Asia/Seoul')"
        
        if [ "$metric" == "vus" ]; then
             query="SELECT \"time\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" ${condition} tz('Asia/Seoul')"
        fi

        docker exec benchmark_influxdb influx -database "$INFLUX_DB_NAME" -precision rfc3339 -execute "$query" -format csv > "${current_csv_dir}/${metric}.csv"
        
        if [ ! -s "${current_csv_dir}/${metric}.csv" ] || [ $(wc -l < "${current_csv_dir}/${metric}.csv") -le 1 ]; then
            echo "    -> (데이터 없음)"
        fi
    done
    
    echo "============================================================"
    echo " [완료] CSV 추출이 완료되었습니다! 엑셀에서 바로 열어보세요."
    echo " 저장 위치: $current_csv_dir"
    echo "============================================================"
}

# [핵심 4] k6 실행기 (session_id 태그 추가)
run_k6() {
    local script_file=$1
    local test_type=$2
    local vus=$3

    echo "------------------------------------------------------------"
    echo "[실행] 테스트 유형: $test_type | 대상: $script_file | VUs: $vus"
    echo "------------------------------------------------------------"

    docker run --rm -i \
      --ulimit nofile=65535:65535 \
      -v $(pwd):/app -w /app \
      --network api-benchmark_default \
      -e VUS=$vus \
      grafana/k6 run \
      --out influxdb=$INFLUX_URL/$INFLUX_DB_NAME \
      --tag run_id="${test_type}_${vus}_${TIMESTAMP}" \
      --tag test_type="$test_type" \
      --tag vus_group="$vus" \
      --tag session_id="${TIMESTAMP}" \
      "$script_file"
}

# [핵심 5] 기존 CSV 폴더에 에러 metric 보충 추출
patch_error_csv() {
    local target_dir=$1
    local dir_name=$(basename "$target_dir")

    # 해당 폴더의 기존 CSV에서 session_id(=타임스탬프)를 추출
    # 폴더명에서 타임스탬프 부분 추출 (export_YYYYMMDD_HHMMSS → YYYYMMDD_HHMMSS)
    local session_ts=$(echo "$dir_name" | sed 's/^export_//')

    # session_id 기반 조건 구성
    local condition="WHERE \"session_id\"='${session_ts}'"

    # 에러 metric만 보충
    local error_metrics=("checks" "http_req_failed")

    for metric in "${error_metrics[@]}"; do
        local target_file="${target_dir}/${metric}.csv"

        # 이미 존재하고 데이터가 있으면 스킵
        if [ -f "$target_file" ] && [ $(wc -l < "$target_file") -gt 1 ]; then
            echo "    -> [${metric}] 이미 존재 (스킵)"
            continue
        fi

        echo "    -> [${metric}] 보충 추출 중..."
        local query="SELECT \"time\", \"api\", \"tc\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" ${condition} tz('Asia/Seoul')"
        docker exec benchmark_influxdb influx -database "$INFLUX_DB_NAME" -precision rfc3339 -execute "$query" -format csv > "$target_file"

        if [ ! -s "$target_file" ] || [ $(wc -l < "$target_file") -le 1 ]; then
            echo "       (해당 세션에 데이터 없음, 전체 범위로 재시도)"
            # session_id로 못 찾으면 전체에서 추출 시도
            query="SELECT \"time\", \"api\", \"tc\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" tz('Asia/Seoul')"
            docker exec benchmark_influxdb influx -database "$INFLUX_DB_NAME" -precision rfc3339 -execute "$query" -format csv > "$target_file"

            if [ ! -s "$target_file" ] || [ $(wc -l < "$target_file") -le 1 ]; then
                echo "       (데이터 없음)"
            else
                local lines=$(wc -l < "$target_file")
                echo "       ✅ 전체 데이터로 보충 완료 (${lines}행)"
            fi
        else
            local lines=$(wc -l < "$target_file")
            echo "       ✅ 세션 데이터 보충 완료 (${lines}행)"
        fi
    done
}

case "$COMMAND" in
  setup-alias)
    echo "[진행] 터미널에 'bm' 단축 명령어(Alias)를 영구 등록합니다..."
    
    SHELL_RC="$HOME/.bashrc"
    if [[ "$SHELL" == *"zsh"* ]] || [ -f "$HOME/.zshrc" ]; then
        SHELL_RC="$HOME/.zshrc"
    fi
    
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SCRIPT_PATH="${SCRIPT_DIR}/manage.sh"
    
    if grep -q "alias bm=" "$SHELL_RC"; then
        echo "[알림] 이미 $SHELL_RC 파일에 'bm' alias가 등록되어 있습니다."
    else
        echo "" >> "$SHELL_RC"
        echo "# API Benchmark Alias" >> "$SHELL_RC"
        echo "alias bm='$SCRIPT_PATH'" >> "$SHELL_RC"
        echo "[완료] $SHELL_RC 파일에 등록을 완료했습니다!"
    fi
    
    echo "============================================================"
    echo " [필수] 변경사항을 적용하려면 터미널에 아래 명령어를 직접 입력하세요:"
    echo " source $SHELL_RC"
    echo "============================================================"
    ;;

  start)
    echo "[진행] 환경 빌드 및 실행..."
    docker compose up -d --build
    echo "[진행] InfluxDB가 완전히 켜질 때까지 5초 대기..."
    sleep 5 
    init_influx_db
    ;;
  
  stop)
    echo "[진행] 컨테이너 중지 및 네트워크 해제..."
    docker compose down
    echo "[완료] 서버가 중지되었습니다."
    ;;

  restart)
    echo "[진행] 기존 컨테이너를 완전히 중지하고 새롭게 빌드하여 재시작합니다..."
    docker compose down
    docker compose up -d --build
    sleep 5 
    init_influx_db
    ;;

  clean)
    echo "[경고] 모든 데이터와 이미지를 삭제합니다."
    docker compose down -v --rmi all
    ;;

  test)
    init_influx_db
    echo "[테스트] 기본 아키텍처 벤치마크 시작 (목표 VUs: ${VUS_ARG})"
    run_k6 "benchmark.js" "standard" "$VUS_ARG"
    ;;

  test-proxy)
    init_influx_db
    echo "[알림] Envoy 프록시 오버헤드 측정을 시작합니다."
    run_k6 "benchmark_envoy.js" "proxy_overhead" "$VUS_ARG"
    ;;

  test-spike)
    init_influx_db
    echo "[알림] 스파이크 부하 테스트를 시작합니다. (스크립트 내 하드코딩된 최대 10,000 VUs로 동작)"
    run_k6 "benchmark_tc8.js" "spike" "max_10k"
    
    echo -e "\n>>> 스파이크 테스트 결과 단독 자동 추출 <<<"
    export_data "spike_backup"
    export_csv "current"
    ;;

  test-all)
    init_influx_db
    echo "============================================================"
    echo "  [자동화] 모든 벤치마크 시나리오 순차 실행 (목표: $VUS_ARG VUs) "
    echo "  * 주의: 스파이크 테스트(TC8)는 과부하 방지를 위해 자동 실행에서 제외됩니다."
    echo "============================================================"
    
    echo -e "\n>>> 1단계: 표준 아키텍처 테스트 시작 <<<"
    run_k6 "benchmark.js" "standard" "$VUS_ARG"
    sleep 5
    
    echo -e "\n>>> 2단계: Envoy 프록시 오버헤드 테스트 시작 <<<"
    run_k6 "benchmark_envoy.js" "proxy_overhead" "$VUS_ARG"
    sleep 5
    
    echo -e "\n>>> 3단계: 테스트 결과 데이터 자동 추출 <<<"
    export_data "k6_backup"
    export_csv "current"
    
    echo "============================================================"
    echo " [완료] 테스트가 종료되고 현재 세션의 데이터만 분리 백업되었습니다."
    echo "============================================================"
    ;;

  export)
    export_data
    ;;

  export-csv)
    TARGET_VUS=${3:-all}
    export_csv "$TARGET_VUS"
    ;;

  restore-all)
    init_influx_db
    echo "============================================================"
    echo "  [복원] 모든 백업본을 InfluxDB에 순차 복원합니다."
    echo "  백업 경로: $BACKUP_DIR"
    echo "============================================================"

    if [ ! -d "$BACKUP_DIR" ]; then
        echo "[에러] 백업 폴더($BACKUP_DIR)가 존재하지 않습니다."
        exit 1
    fi

    BACKUP_COUNT=0
    FAIL_COUNT=0

    for backup_dir in "$BACKUP_DIR"/*/; do
        if [ ! -d "$backup_dir" ]; then
            continue
        fi

        backup_name=$(basename "$backup_dir")
        echo ""
        echo "  ──────────────────────────────────────"
        echo "  [${BACKUP_COUNT}] 복원 중: ${backup_name}"

        # 컨테이너 안으로 백업 복사
        docker cp "$backup_dir" "benchmark_influxdb:/var/lib/influxdb/restore_temp"

        # 복원 실행 (이미 존재하는 데이터는 스킵됨)
        docker exec benchmark_influxdb influxd restore -portable -db "$INFLUX_DB_NAME" "/var/lib/influxdb/restore_temp" 2>&1

        if [ $? -eq 0 ]; then
            echo "  -> ✅ 복원 성공"
            BACKUP_COUNT=$((BACKUP_COUNT + 1))
        else
            echo "  -> ⚠️  복원 실패 또는 중복 데이터 (계속 진행)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
        fi

        # 임시 파일 정리
        docker exec benchmark_influxdb rm -rf "/var/lib/influxdb/restore_temp"
    done

    echo ""
    echo "============================================================"
    echo " [완료] 백업 복원 결과"
    echo "   - 성공: ${BACKUP_COUNT}개"
    echo "   - 실패/중복: ${FAIL_COUNT}개"
    echo ""
    echo " 확인 명령어:"
    echo "   docker exec benchmark_influxdb influx -database k6 -execute 'SHOW MEASUREMENTS' -format csv"
    echo "============================================================"
    ;;

  export-full)
    init_influx_db
    echo "============================================================"
    echo "  [전체 추출] 백업 복원 → 기존 CSV 폴더에 에러 데이터 보충"
    echo "============================================================"

    # 1단계: 모든 백업 복원
    echo -e "\n>>> 1단계: 모든 백업본 InfluxDB 복원 <<<"

    if [ -d "$BACKUP_DIR" ]; then
        for backup_dir in "$BACKUP_DIR"/*/; do
            [ ! -d "$backup_dir" ] && continue
            backup_name=$(basename "$backup_dir")
            echo "  - 복원 중: ${backup_name}"
            docker cp "$backup_dir" "benchmark_influxdb:/var/lib/influxdb/restore_temp"
            docker exec benchmark_influxdb influxd restore -portable -db "$INFLUX_DB_NAME" "/var/lib/influxdb/restore_temp" 2>/dev/null
            docker exec benchmark_influxdb rm -rf "/var/lib/influxdb/restore_temp"
        done
        echo "  -> 백업 복원 완료"
    else
        echo "  -> 백업 폴더 없음 (현재 DB 데이터만 사용)"
    fi

    # 2단계: 기존 CSV 폴더 스캔 → 에러 CSV 없는 폴더에 보충
    echo -e "\n>>> 2단계: 기존 CSV 폴더에 에러 데이터 보충 <<<"

    PATCHED=0
    SKIPPED=0

    if [ -d "$CSV_DIR" ]; then
        for csv_dir in "$CSV_DIR"/export_*/; do
            [ ! -d "$csv_dir" ] && continue
            dir_name=$(basename "$csv_dir")

            # 기존 성능 CSV가 있는 폴더만 대상 (빈 폴더 제외)
            if [ ! -f "${csv_dir}/http_req_duration.csv" ] && [ ! -f "${csv_dir}/grpc_req_duration.csv" ]; then
                continue
            fi

            has_checks=false
            has_failed=false
            [ -f "${csv_dir}/checks.csv" ] && [ $(wc -l < "${csv_dir}/checks.csv") -gt 1 ] && has_checks=true
            [ -f "${csv_dir}/http_req_failed.csv" ] && [ $(wc -l < "${csv_dir}/http_req_failed.csv") -gt 1 ] && has_failed=true

            if $has_checks && $has_failed; then
                echo "  [${dir_name}] 에러 CSV 이미 존재 (스킵)"
                SKIPPED=$((SKIPPED + 1))
            else
                echo "  [${dir_name}] 에러 CSV 보충 중..."
                patch_error_csv "$csv_dir"
                PATCHED=$((PATCHED + 1))
            fi
        done
    else
        echo "  -> CSV 폴더가 없습니다. 먼저 테스트를 실행하세요."
    fi

    echo ""
    echo "============================================================"
    echo " [완료] 에러 데이터 보충 결과"
    echo "   - 보충된 폴더: ${PATCHED}개"
    echo "   - 이미 완료된 폴더: ${SKIPPED}개"
    echo ""
    echo " 각 폴더의 CSV를 Analyzer에 드래그하세요:"
    echo "   http_req_duration / grpc_req_duration / http_reqs"
    echo "   + checks / http_req_failed / vus"
    echo "============================================================"
    ;;

  package)
    echo "============================================================"
    echo "  [패키징] CSV 폴더를 VUs별 이름으로 정리하여 ZIP 압축"
    echo "============================================================"

    if [ ! -d "$CSV_DIR" ]; then
        echo "[에러] csv_results 폴더가 없습니다."
        exit 1
    fi

    # zip 설치 확인
    if ! command -v zip &> /dev/null; then
        echo "[에러] zip 명령어가 없습니다. sudo apt install zip 으로 설치하세요."
        exit 1
    fi

    PACKAGE_DIR="${CSV_DIR}/packaged_${TIMESTAMP}"
    mkdir -p "$PACKAGE_DIR"

    PACK_COUNT=0

    for csv_dir in "$CSV_DIR"/export_*/; do
        [ ! -d "$csv_dir" ] && continue
        dir_name=$(basename "$csv_dir")

        # vus.csv에서 vus_group 값 추출
        vus_file="${csv_dir}/vus.csv"
        VUS_LABEL="unknown"

        if [ -f "$vus_file" ] && [ $(wc -l < "$vus_file") -gt 1 ]; then
            # vus.csv의 헤더에서 vus_group 컬럼 위치 찾기
            header=$(head -1 "$vus_file")

            # vus_group 컬럼이 있는 경우
            if echo "$header" | grep -q "vus_group"; then
                col_idx=$(echo "$header" | tr ',' '\n' | grep -n "vus_group" | head -1 | cut -d: -f1)
                # 데이터 행에서 vus_group 값 추출 (빈 값이 아닌 첫 번째 값)
                vus_val=$(tail -n +2 "$vus_file" | awk -F',' -v col="$col_idx" '{
                    val=$col;
                    gsub(/^[ \t]+|[ \t]+$/, "", val);
                    if (val != "" && val != "null") { print val; exit; }
                }')
                if [ -n "$vus_val" ]; then
                    VUS_LABEL="$vus_val"
                fi
            fi
        fi

        # test_type도 추출 (standard, spike, proxy_overhead 구분용)
        TEST_TYPE=""
        if [ -f "$vus_file" ] && echo "$header" | grep -q "test_type"; then
            type_col=$(echo "$header" | tr ',' '\n' | grep -n "test_type" | head -1 | cut -d: -f1)
            type_val=$(tail -n +2 "$vus_file" | awk -F',' -v col="$type_col" '{
                val=$col;
                gsub(/^[ \t]+|[ \t]+$/, "", val);
                if (val != "" && val != "null") { print val; exit; }
            }')
            if [ -n "$type_val" ]; then
                TEST_TYPE="_${type_val}"
            fi
        fi

        # 새 폴더명 생성: VUs_1000_standard 같은 형태
        NEW_NAME="VUs_${VUS_LABEL}${TEST_TYPE}"

        # 동일 이름 충돌 방지 (같은 VUs로 여러 세션이 있을 수 있음)
        FINAL_NAME="$NEW_NAME"
        COUNTER=1
        while [ -d "${PACKAGE_DIR}/${FINAL_NAME}" ]; do
            FINAL_NAME="${NEW_NAME}_${COUNTER}"
            COUNTER=$((COUNTER + 1))
        done

        echo "  ${dir_name} → ${FINAL_NAME}"
        cp -r "$csv_dir" "${PACKAGE_DIR}/${FINAL_NAME}"
        PACK_COUNT=$((PACK_COUNT + 1))
    done

    if [ $PACK_COUNT -eq 0 ]; then
        echo "[알림] 패키징할 CSV 폴더가 없습니다."
        rm -rf "$PACKAGE_DIR"
        exit 0
    fi

    # ZIP 압축
    ZIP_NAME="benchmark_results_${TIMESTAMP}.zip"
    cd "$PACKAGE_DIR" && zip -r "../${ZIP_NAME}" . -q && cd - > /dev/null

    # 정리
    rm -rf "$PACKAGE_DIR"

    echo ""
    echo "============================================================"
    echo " [완료] ${PACK_COUNT}개 세션이 ZIP으로 패키징되었습니다."
    echo " 파일: ${CSV_DIR}/${ZIP_NAME}"
    echo ""
    echo " ZIP 내부 구조:"
    zip -sf "${CSV_DIR}/${ZIP_NAME}" 2>/dev/null | head -30
    echo "============================================================"
    ;;

  logs)
    echo "[로그] 실시간 컨테이너 로그 출력 (종료: Ctrl+C)"
    docker compose logs -f
    ;;

  *)
    echo "사용법: ./manage.sh [명령어] [VUs]"
    echo "----------------------------------------------------------------------"
    echo " [초기 설정 (최초 1회)]"
    echo "  setup-alias           : './manage.sh'를 'bm'으로 줄여쓰도록 환경 설정"
    echo ""
    echo " [테스트 실행]"
    echo "  test [VUs]            : [TC1~7] 기본 아키텍처 비교 (예: ./manage.sh test 2000)"
    echo "  test-proxy [VUs]      : [TC9] 프록시 오버헤드 비교"
    echo "  test-spike            : [TC8] 스파이크 테스트 (실행 후 해당 데이터만 독립 자동 추출)"
    echo "  test-all [VUs]        : [권장] 스파이크 제외 연속 실행 후 해당 데이터만 독립 추출"
    echo ""
    echo " [데이터 추출]"
    echo "  export-csv            : 역대 저장된 '모든' 데이터를 CSV로 추출 (에러 포함)"
    echo "  export-csv - 1000     : VUs가 1000인 데이터만 필터링하여 CSV로 추출"
    echo "  export                : InfluxDB 바이너리 전체 백업"
    echo ""
    echo " [백업 복원 & 전체 추출]"
    echo "  restore-all           : influxdb_backups/ 폴더의 모든 백업본을 DB에 복원"
    echo "  export-full           : [권장] 모든 백업 복원 → 전체 CSV 추출 (에러율 포함, 원커맨드)"
    echo "  package               : CSV 폴더를 VUs별 이름으로 정리하여 ZIP 압축"
    echo ""
    echo " [환경 관리]"
    echo "  start / stop / restart / clean / logs"
    echo "----------------------------------------------------------------------"
    exit 1
    ;;
esac