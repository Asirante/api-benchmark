#!/bin/bash

# API 아키텍처 벤치마킹 통합 관리 스크립트 (v8.1 - 리팩토링 및 자동화 파이프라인 강화)
# 권한 부여: chmod +x manage.sh

COMMAND=$1
VUS_ARG=${2:-1000} # 두 번째 인자가 없으면 기본 1000 VUs
GLOBAL_TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 인플럭스 DB 연결 정보
INFLUX_DB_NAME="k6"
INFLUX_URL="http://benchmark_influxdb:8086"
BACKUP_DIR="./influxdb_backups"
CSV_DIR="./csv_results"

# 모든 추출 대상 Metric 목록 (재사용성을 위한 전역 배열)
METRICS=(
    "http_req_duration" "grpc_req_duration" "http_reqs"
    "http_req_waiting" "http_req_blocked" "http_req_connecting"
    "http_req_sending" "http_req_receiving"
    "checks" "http_req_failed"
    "vus"
)

# ----------------------------------------------------------------------------
# [공통 유틸리티 함수]
# ----------------------------------------------------------------------------

print_header() {
    echo "============================================================"
    echo " $1"
    echo "============================================================"
}

run_influx_query() {
    local query=$1
    local output_file=$2
    docker exec benchmark_influxdb influx -database "$INFLUX_DB_NAME" -precision rfc3339 -execute "$query" -format csv > "$output_file"
}

# ----------------------------------------------------------------------------
# [핵심 로직 함수]
# ----------------------------------------------------------------------------

# DB 상태 체크 및 자동 생성
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

# k6 실행기
run_k6() {
    local script_file=$1
    local test_type=$2
    local vus=$3
    local session_id=${4:-$GLOBAL_TIMESTAMP}

    echo "------------------------------------------------------------"
    echo "[실행] 테스트 유형: $test_type | 대상: $script_file | VUs: $vus | Session: $session_id"
    echo "------------------------------------------------------------"

    docker run --rm -i \
      --ulimit nofile=65535:65535 \
      -v $(pwd):/app -w /app \
      --network api-benchmark_default \
      -e VUS=$vus \
      grafana/k6 run \
      --out influxdb=$INFLUX_URL/$INFLUX_DB_NAME \
      --tag run_id="${test_type}_${vus}_${session_id}" \
      --tag test_type="$test_type" \
      --tag vus_group="$vus" \
      --tag session_id="${session_id}" \
      "$script_file"
}

# 공통 테스트 파이프라인 (REST -> GQL -> gRPC -> Envoy)
run_benchmark_suite() {
    local vus=$1
    local session_id=${2:-$GLOBAL_TIMESTAMP}

    echo -e "\n>>> [1/4] REST 격리 테스트 <<<"
    run_k6 "bench_rest.js" "standard" "$vus" "$session_id"
    echo ">>> [쿨다운] 30초 대기 <<<"; sleep 30

    echo -e "\n>>> [2/4] GraphQL 격리 테스트 <<<"
    run_k6 "bench_gql.js" "standard" "$vus" "$session_id"
    echo ">>> [쿨다운] 30초 대기 <<<"; sleep 30

    echo -e "\n>>> [3/4] gRPC Direct 격리 테스트 <<<"
    run_k6 "bench_grpc.js" "standard" "$vus" "$session_id"
    echo ">>> [쿨다운] 30초 대기 <<<"; sleep 30

    echo -e "\n>>> [4/4] gRPC Envoy 프록시 오버헤드 테스트 (TC9) <<<"
    run_k6 "bench_grpc_envoy.js" "proxy_overhead" "$vus" "$session_id"
    sleep 5
}

# 바이너리 데이터 추출 (백업)
do_export_data() {
    local prefix=${1:-"k6_backup"}
    local session_id=${2:-$GLOBAL_TIMESTAMP}
    
    echo "[진행] InfluxDB 바이너리 데이터 백업을 시작합니다..."
    mkdir -p $BACKUP_DIR
    local backup_name="${prefix}_${session_id}"
    local container_backup_path="/var/lib/influxdb/${backup_name}"
    
    docker exec benchmark_influxdb influxd backup -portable -database $INFLUX_DB_NAME $container_backup_path > /dev/null
    docker cp benchmark_influxdb:$container_backup_path "${BACKUP_DIR}/${backup_name}"
    docker exec benchmark_influxdb rm -rf $container_backup_path
    
    echo "[완료] 바이너리 데이터 백업 완료. 경로: ${BACKUP_DIR}/${backup_name}"
}

# CSV 다중 추출
do_export_csv() {
    local mode=$1
    local session_id=${2:-$GLOBAL_TIMESTAMP}
    local current_csv_dir="${CSV_DIR}/export_${session_id}"
    
    mkdir -p "$current_csv_dir"
    print_header " [진행] CSV 데이터 추출 (경로: $current_csv_dir)"

    local condition=""
    if [ "$mode" == "current" ]; then
        echo "  - 추출 범위: [Session: $session_id] 단독 추출"
        condition="WHERE \"session_id\"='${session_id}'"
    elif [ -z "$mode" ] || [ "$mode" == "all" ]; then
        echo "  - 추출 범위: 역대 저장된 [전체 데이터]"
    else
        echo "  - 추출 범위: [VUs = ${mode}] 조건에 맞는 데이터만"
        condition="WHERE \"vus_group\"='${mode}'"
    fi

    for metric in "${METRICS[@]}"; do
        echo "  - [${metric}] 추출 중..."
        local query="SELECT \"time\", \"api\", \"tc\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" ${condition} tz('Asia/Seoul')"
        
        # VUS 메트릭은 구조가 약간 다름
        if [ "$metric" == "vus" ]; then
             query="SELECT \"time\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" ${condition} tz('Asia/Seoul')"
        fi

        run_influx_query "$query" "${current_csv_dir}/${metric}.csv"
        
        if [ ! -s "${current_csv_dir}/${metric}.csv" ] || [ $(wc -l < "${current_csv_dir}/${metric}.csv") -le 1 ]; then
            echo "    -> (데이터 없음)"
        fi
    done
    echo " [완료] CSV 추출 완료"
}

# 백업본 전체 복원
do_restore_all() {
    print_header " [복원] 모든 백업본을 InfluxDB에 순차 복원합니다."
    if [ ! -d "$BACKUP_DIR" ]; then
        echo "[에러] 백업 폴더($BACKUP_DIR)가 존재하지 않습니다."; return 1
    fi

    local backup_count=0
    local fail_count=0

    for backup_dir in "$BACKUP_DIR"/*/; do
        [ ! -d "$backup_dir" ] && continue
        
        local backup_name=$(basename "$backup_dir")
        echo "  - 복원 중: ${backup_name}"
        docker cp "$backup_dir" "benchmark_influxdb:/var/lib/influxdb/restore_temp"
        
        if docker exec benchmark_influxdb influxd restore -portable -db "$INFLUX_DB_NAME" "/var/lib/influxdb/restore_temp" >/dev/null 2>&1; then
            echo "  -> ✅ 복원 성공"
            backup_count=$((backup_count + 1))
        else
            echo "  -> ⚠️ 복원 실패 또는 중복 데이터"
            fail_count=$((fail_count + 1))
        fi
        docker exec benchmark_influxdb rm -rf "/var/lib/influxdb/restore_temp"
    done
    echo " [완료] 복원 결과: 성공 ${backup_count}개, 실패/중복 ${fail_count}개"
}

# 기존 CSV 폴더에 누락된 metric 보충 추출
patch_missing_csv() {
    local target_dir=$1
    local dir_name=$(basename "$target_dir")
    local session_ts=$(echo "$dir_name" | sed 's/^export_//')
    local condition="WHERE \"session_id\"='${session_ts}'"

    local patch_metrics=("checks" "http_req_failed" "http_req_waiting" "http_req_blocked" "http_req_connecting" "http_req_sending" "http_req_receiving")

    for metric in "${patch_metrics[@]}"; do
        local target_file="${target_dir}/${metric}.csv"
        if [ -f "$target_file" ] && [ $(wc -l < "$target_file") -gt 1 ]; then
            continue # 이미 존재함
        fi

        echo "    -> [${metric}] 보충 중..."
        local query="SELECT \"time\", \"api\", \"tc\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" ${condition} tz('Asia/Seoul')"
        run_influx_query "$query" "$target_file"

        if [ ! -s "$target_file" ] || [ $(wc -l < "$target_file") -le 1 ]; then
            # 전체 범위로 재시도
            query="SELECT \"time\", \"api\", \"tc\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" tz('Asia/Seoul')"
            run_influx_query "$query" "$target_file"
        fi
    done
}

# Export Full (복원 후 패치)
do_export_full() {
    print_header " [전체 추출] 백업 복원 → 기존 CSV 폴더 에러 데이터 보충"
    echo -e "\n>>> 1단계: 모든 백업본 InfluxDB 복원 <<<"
    do_restore_all

    echo -e "\n>>> 2단계: 기존 CSV 누락 데이터 보충 <<<"
    local patched=0
    local skipped=0

    if [ -d "$CSV_DIR" ]; then
        for csv_dir in "$CSV_DIR"/export_*/; do
            [ ! -d "$csv_dir" ] && continue
            local dir_name=$(basename "$csv_dir")
            
            if [ ! -f "${csv_dir}/http_req_duration.csv" ] && [ ! -f "${csv_dir}/grpc_req_duration.csv" ]; then
                continue
            fi

            local has_missing=false
            for pf in "${METRICS[@]}"; do
                if [ ! -f "${csv_dir}/${pf}.csv" ] || [ $(wc -l < "${csv_dir}/${pf}.csv") -le 1 ]; then
                    has_missing=true
                    break
                fi
            done

            if $has_missing; then
                echo "  [${dir_name}] 누락 CSV 보충..."
                patch_missing_csv "$csv_dir"
                patched=$((patched + 1))
            else
                skipped=$((skipped + 1))
            fi
        done
    fi
    echo " [완료] 보충된 폴더: ${patched}개 / 완료된 폴더: ${skipped}개"
}

# CSV 패키징 및 ZIP 압축
do_package() {
    print_header " [패키징] CSV 폴더 VUs별 정리 및 ZIP 압축"
    if [ ! -d "$CSV_DIR" ] || ! command -v zip &> /dev/null; then
        echo "[에러] csv_results 폴더가 없거나 zip 명령어가 없습니다."
        return 1
    fi

    local package_dir="${CSV_DIR}/packaged_${GLOBAL_TIMESTAMP}"
    mkdir -p "$package_dir"
    local pack_count=0

    for csv_dir in "$CSV_DIR"/export_*/; do
        [ ! -d "$csv_dir" ] && continue
        local dir_name=$(basename "$csv_dir")
        local vus_file="${csv_dir}/vus.csv"
        local vus_label="unknown"
        local test_type=""

        if [ -f "$vus_file" ] && [ $(wc -l < "$vus_file") -gt 1 ]; then
            local header=$(head -1 "$vus_file")
            # VUs 파싱
            if echo "$header" | grep -q "vus_group"; then
                local col_idx=$(echo "$header" | tr ',' '\n' | grep -n "vus_group" | head -1 | cut -d: -f1)
                vus_label=$(tail -n +2 "$vus_file" | awk -F',' -v col="$col_idx" '{ val=$col; gsub(/^[ \t]+|[ \t]+$/, "", val); if (val != "" && val != "null") { print val; exit; } }')
            fi
            # Test Type 파싱
            if echo "$header" | grep -q "test_type"; then
                local type_col=$(echo "$header" | tr ',' '\n' | grep -n "test_type" | head -1 | cut -d: -f1)
                local t_val=$(tail -n +2 "$vus_file" | awk -F',' -v col="$type_col" '{ val=$col; gsub(/^[ \t]+|[ \t]+$/, "", val); if (val != "" && val != "null") { print val; exit; } }')
                [ -n "$t_val" ] && test_type="_${t_val}"
            fi
        fi

        local base_name="VUs_${vus_label}${test_type}"
        local final_name="$base_name"
        local counter=1
        while [ -d "${package_dir}/${final_name}" ]; do
            final_name="${base_name}_${counter}"
            counter=$((counter + 1))
        done

        echo "  ${dir_name} → ${final_name}"
        cp -r "$csv_dir" "${package_dir}/${final_name}"
        pack_count=$((pack_count + 1))
    done

    if [ $pack_count -eq 0 ]; then
        echo "[알림] 패키징 대상 없음."; rm -rf "$package_dir"; return 0
    fi

    local zip_name="benchmark_results_${GLOBAL_TIMESTAMP}.zip"
    cd "$package_dir" && zip -r "../${zip_name}" . -q && cd - > /dev/null
    rm -rf "$package_dir"

    echo " [완료] ${pack_count}개 세션 ZIP 패키징 완료: ${CSV_DIR}/${zip_name}"
}


# ----------------------------------------------------------------------------
# [커맨드 라우팅]
# ----------------------------------------------------------------------------

case "$COMMAND" in
  setup-alias)
    echo "[진행] 터미널에 'bm' 단축 명령어(Alias)를 영구 등록합니다..."
    SHELL_RC="$HOME/.bashrc"
    [[ "$SHELL" == *"zsh"* ]] || [ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manage.sh"
    
    if grep -q "alias bm=" "$SHELL_RC"; then
        echo "[알림] 이미 $SHELL_RC 파일에 'bm' alias가 등록되어 있습니다."
    else
        echo -e "\n# API Benchmark Alias\nalias bm='$SCRIPT_PATH'" >> "$SHELL_RC"
        echo "[완료] 적용을 위해 'source $SHELL_RC' 를 입력하세요."
    fi
    ;;

  start)
    docker compose up -d --build
    echo "[진행] InfluxDB 대기 중..."; sleep 5; init_influx_db
    ;;
  
  stop) docker compose down ;;
  restart) docker compose down; docker compose up -d --build; sleep 5; init_influx_db ;;
  clean) docker compose down -v --rmi all ;;

  test)
    init_influx_db
    print_header " [격리 테스트] 순차 벤치마크 (VUs: ${VUS_ARG})"
    run_k6 "bench_rest.js" "standard" "$VUS_ARG"
    sleep 30; run_k6 "bench_gql.js" "standard" "$VUS_ARG"
    sleep 30; run_k6 "bench_grpc.js" "standard" "$VUS_ARG"
    ;;

  test-proxy)
    init_influx_db
    run_k6 "benchmark_envoy.js" "proxy_overhead" "$VUS_ARG"
    ;;

  test-spike)
    init_influx_db
    run_k6 "benchmark_tc8.js" "spike" "max_10k" "$GLOBAL_TIMESTAMP"
    do_export_data "spike_backup" "$GLOBAL_TIMESTAMP"
    do_export_csv "current" "$GLOBAL_TIMESTAMP"
    ;;

  test-all)
    init_influx_db
    print_header " [자동화] 벤치마크 전체 실행 (VUs: $VUS_ARG)"
    run_benchmark_suite "$VUS_ARG" "$GLOBAL_TIMESTAMP"
    do_export_data "k6_backup" "$GLOBAL_TIMESTAMP"
    do_export_csv "current" "$GLOBAL_TIMESTAMP"
    ;;

  test-all-cycle)
    shift
    VUS_LIST="$@"
    if [ -z "$VUS_LIST" ]; then
        echo "[에러] 사용법: ./manage.sh test-all-cycle 100 300 500"; exit 1
    fi

    init_influx_db
    TOTAL_SETS=$(echo "$VUS_LIST" | wc -w)
    CURRENT_SET=0

    print_header " [전체 사이클] 다중 VUs 자동 실행 (VUs: $VUS_LIST)"

    for VUS_TARGET in $VUS_LIST; do
        CURRENT_SET=$((CURRENT_SET + 1))
        # 사이클마다 고유한 타임스탬프(Session ID) 발급
        CYCLE_TS=$(date +%Y%m%d_%H%M%S) 
        
        echo -e "\n┌──────────────────────────────────────────────────────────┐"
        echo "│  [${CURRENT_SET}/${TOTAL_SETS}] VUs = ${VUS_TARGET} 세트 시작 (Session: $CYCLE_TS)"
        echo "└──────────────────────────────────────────────────────────┘"

        # 1. 벤치마크 실행
        run_benchmark_suite "$VUS_TARGET" "$CYCLE_TS"

        # 2. 해당 사이클 전용 백업 & CSV 추출
        do_export_data "cycle_vus${VUS_TARGET}" "$CYCLE_TS"
        do_export_csv "current" "$CYCLE_TS"

        if [ "$CURRENT_SET" -lt "$TOTAL_SETS" ]; then
            echo ">>> [세트 간 쿨다운] DB 안정화를 위해 60초 대기 <<<"; sleep 60
        fi
    done

    # 3. 전체 사이클 종료 후 자동 파이프라인 (export-full -> package)
    print_header " 모든 사이클 테스트 완료. 자동 정리(Export Full & Package) 시작..."
    do_export_full
    do_package
    ;;

  export) do_export_data "k6_manual_backup" "$GLOBAL_TIMESTAMP" ;;
  export-csv) do_export_csv "${3:-all}" "$GLOBAL_TIMESTAMP" ;;
  restore-all) init_influx_db; do_restore_all ;;
  export-full) init_influx_db; do_export_full ;;
  package) do_package ;;
  logs) docker compose logs -f ;;

  *)
    echo "사용법: ./manage.sh [명령어] [VUs]"
    echo "----------------------------------------------------------------------"
    echo " [초기 설정] setup-alias"
    echo " [테스트] test, test-all, test-all-cycle [V1 V2..], test-spike"
    echo " [데이터] export, export-csv, restore-all, export-full, package"
    echo " [관  리] start, stop, restart, clean, logs"
    exit 1
    ;;
esac