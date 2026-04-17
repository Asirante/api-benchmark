#!/bin/bash

# API 아키텍처 벤치마킹 통합 관리 스크립트 (v11.1 - 기본 기능 복구 및 스파이크/패키징 고도화)
# 권한 부여: chmod +x manage.sh

COMMAND=$1
VUS_ARG=${2:-1000}
GLOBAL_TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# 인플럭스 DB 연결 정보
INFLUX_DB_NAME="k6"
INFLUX_URL="http://benchmark_influxdb:8086"
BACKUP_DIR="./influxdb_backups"
CSV_DIR="./csv_results"
RESOURCE_DIR="./resource_logs"

# 리소스 모니터링 설정
RESOURCE_INTERVAL=2
RESOURCE_CONTAINERS=("benchmark_rest" "benchmark_graphql" "benchmark_grpc" "benchmark_db" "benchmark_envoy")

METRICS=(
    "http_req_duration" "grpc_req_duration" "http_reqs"
    "http_req_waiting" "http_req_blocked" "http_req_connecting"
    "http_req_sending" "http_req_receiving"
    "checks" "http_req_failed"
    "vus"
)

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

countdown() {
    local secs=$1
    local msg=$2
    echo -n ">>> [$msg] ${secs}초 대기 중: "
    while [ $secs -gt 0 ]; do
        echo -ne "$secs "
        sleep 1
        : $((secs--))
    done
    echo "<<<"
    echo ""
}

# ----------------------------------------------------------------------------
start_resource_collector() {
    local output_csv=$1
    mkdir -p "$RESOURCE_DIR"
    echo "time,container,cpu_perc,mem_usage" > "$output_csv"
    
    (
        trap "exit 0" SIGTERM SIGINT
        while true; do
            local ts=$(date '+%Y-%m-%dT%H:%M:%S')
            docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" "${RESOURCE_CONTAINERS[@]}" 2>/dev/null | while read line; do
                if [ -n "$line" ]; then
                    echo "${ts},${line}" >> "$output_csv"
                fi
            done
            sleep "$RESOURCE_INTERVAL"
        done
    ) </dev/null >/dev/null 2>&1 &
    
    local pid=$!
    echo "  [리소스] docker stats 수집 시작 (PID: $pid)" >&2
    echo $pid
}

stop_resource_collector() {
    local pid=$1
    local csv_file=$2
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
        local lines=$(wc -l < "$csv_file" 2>/dev/null || echo "0")
        echo "  [리소스] 수집 완료 (${lines}행) → $(basename $csv_file)"
    fi
}

# ----------------------------------------------------------------------------
init_influx_db() {
    echo "[진행] InfluxDB 상태 확인 중..."
    if ! docker ps | grep -q benchmark_influxdb; then
        echo "[에러] benchmark_influxdb가 실행 중이지 않습니다."; exit 1
    fi
    docker exec benchmark_influxdb influx -execute "CREATE DATABASE $INFLUX_DB_NAME" > /dev/null 2>&1
    [ $? -eq 0 ] && echo "[완료] InfluxDB 준비 완료" || { echo "[에러] DB 생성 실패"; exit 1; }
}

run_k6() {
    local script_file=$1
    local test_type=$2
    local vus=$3
    local session_id=${4:-$GLOBAL_TIMESTAMP}

    echo "------------------------------------------------------------"
    echo " 🚀 [실행] $test_type | $script_file | VUs: $vus"
    echo "------------------------------------------------------------"

    local proto_name=$(echo "$script_file" | sed -E 's/bench_(.*)\.js/\1/' | sed 's/benchmark_tc8.js/spike/')
    local resource_file="${RESOURCE_DIR}/resource_${test_type}_${proto_name}_${vus}_${session_id}.csv"
    
    local resource_pid=$(start_resource_collector "$resource_file")

    docker run --rm -it \
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

    stop_resource_collector "$resource_pid" "$resource_file"
}

run_benchmark_suite() {
    local vus=$1
    local session_id=${2:-$GLOBAL_TIMESTAMP}

    echo -e "\n>>> [1/4] REST API 테스트 시작 <<<"
    run_k6 "bench_rest.js" "standard" "$vus" "$session_id"
    countdown 30 "REST 종료 후 쿨다운"

    echo -e "\n>>> [2/4] GraphQL API 테스트 시작 <<<"
    run_k6 "bench_gql.js" "standard" "$vus" "$session_id"
    countdown 30 "GraphQL 종료 후 쿨다운"

    echo -e "\n>>> [3/4] gRPC Direct 테스트 시작 <<<"
    run_k6 "bench_grpc.js" "standard" "$vus" "$session_id"
    countdown 30 "gRPC 종료 후 쿨다운"

    echo -e "\n>>> [4/4] gRPC Envoy (TC9) 테스트 시작 <<<"
    run_k6 "bench_grpc_envoy.js" "proxy_overhead" "$vus" "$session_id"
    countdown 5 "세트 종료 마무리"
}

do_export_data() {
    local prefix=${1:-"k6_backup"}
    local session_id=${2:-$GLOBAL_TIMESTAMP}
    echo "[진행] InfluxDB 데이터 백업 중..."
    mkdir -p $BACKUP_DIR
    local name="${prefix}_${session_id}"
    local path="/var/lib/influxdb/${name}"
    docker exec benchmark_influxdb influxd backup -portable -database $INFLUX_DB_NAME $path > /dev/null
    docker cp benchmark_influxdb:$path "${BACKUP_DIR}/${name}"
    docker exec benchmark_influxdb rm -rf $path
    echo "[완료] 백업 저장됨 → ${BACKUP_DIR}/${name}"
}

do_export_csv() {
    local mode=$1
    local session_id=${2:-$GLOBAL_TIMESTAMP}
    local dir="${CSV_DIR}/export_${session_id}"
    mkdir -p "$dir"
    print_header " [CSV 데이터 추출] → $dir"

    local condition=""
    case "$mode" in
        current) condition="WHERE \"session_id\"='${session_id}'" ;;
        all|"") ;;
        *) condition="WHERE \"vus_group\"='${mode}'" ;;
    esac

    for metric in "${METRICS[@]}"; do
        echo "  - 추출 중: [${metric}]"
        local q="SELECT \"time\", \"api\", \"tc\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" ${condition} tz('Asia/Seoul')"
        [ "$metric" == "vus" ] && q="SELECT \"time\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" ${condition} tz('Asia/Seoul')"
        run_influx_query "$q" "${dir}/${metric}.csv"
    done

    if [ -d "$RESOURCE_DIR" ]; then
        local rc=0
        for rf in "$RESOURCE_DIR"/resource_*_${session_id}.csv; do
            [ ! -f "$rf" ] && continue
            cp "$rf" "${dir}/"; rc=$((rc + 1))
        done
        [ $rc -gt 0 ] && echo "  - [리소스] ${rc}개의 리소스 로그 파일 복사 완료"
    fi
    echo " [완료] 파일 추출 성공"
}

do_restore_all() {
    print_header " [복원] 백업 파일 → InfluxDB"
    [ ! -d "$BACKUP_DIR" ] && { echo "[에러] 백업 디렉토리가 없습니다."; return 1; }
    local ok=0 fail=0
    for d in "$BACKUP_DIR"/*/; do
        [ ! -d "$d" ] && continue
        docker cp "$d" "benchmark_influxdb:/var/lib/influxdb/restore_temp"
        docker exec benchmark_influxdb influxd restore -portable -db "$INFLUX_DB_NAME" "/var/lib/influxdb/restore_temp" >/dev/null 2>&1 && ok=$((ok+1)) || fail=$((fail+1))
        docker exec benchmark_influxdb rm -rf "/var/lib/influxdb/restore_temp"
    done
    echo " 복원 결과: 성공 ${ok} / 실패 ${fail}"
}

patch_missing_csv() {
    local target_dir=$1
    local session_ts=$(basename "$target_dir" | sed 's/^export_//')
    local condition="WHERE \"session_id\"='${session_ts}'"
    local patch_metrics=("checks" "http_req_failed" "http_req_waiting" "http_req_blocked" "http_req_connecting" "http_req_sending" "http_req_receiving")
    for metric in "${patch_metrics[@]}"; do
        local f="${target_dir}/${metric}.csv"
        [ -f "$f" ] && [ $(wc -l < "$f") -gt 1 ] && continue
        local q="SELECT \"time\", \"api\", \"tc\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" ${condition} tz('Asia/Seoul')"
        run_influx_query "$q" "$f"
        if [ ! -s "$f" ] || [ $(wc -l < "$f") -le 1 ]; then
            q="SELECT \"time\", \"api\", \"tc\", \"test_type\", \"vus_group\", \"run_id\", \"value\" FROM \"${metric}\" tz('Asia/Seoul')"
            run_influx_query "$q" "$f"
        fi
    done
}

do_export_full() {
    print_header " [전체 추출] 데이터 복원 및 보충 작업"
    do_restore_all
    local patched=0 skipped=0
    if [ -d "$CSV_DIR" ]; then
        for csv_dir in "$CSV_DIR"/export_*/; do
            [ ! -d "$csv_dir" ] && continue
            [ ! -f "${csv_dir}/http_req_duration.csv" ] && [ ! -f "${csv_dir}/grpc_req_duration.csv" ] && continue
            local missing=false
            for m in "${METRICS[@]}"; do
                [ ! -f "${csv_dir}/${m}.csv" ] || [ $(wc -l < "${csv_dir}/${m}.csv") -le 1 ] && { missing=true; break; }
            done
            if $missing; then patch_missing_csv "$csv_dir"; patched=$((patched+1)); else skipped=$((skipped+1)); fi
        done
    fi
    echo " 누락분 보충 ${patched}건 / 정상 스킵 ${skipped}건"
}

do_package() {
    print_header " [정리] 결과물 VUs별 폴더 분류 (기존 폴더 덮어쓰기)"
    [ ! -d "$CSV_DIR" ] && { echo "[에러] csv_results 디렉토리가 없습니다."; return 1; }

    local count=0

    # export_ 로 시작하는 임시 폴더들을 VUs_ 형태의 직관적인 폴더명으로 변환
    for csv_dir in "$CSV_DIR"/export_*/; do
        [ ! -d "$csv_dir" ] && continue
        local vus_file="${csv_dir}/vus.csv" vus_label="unknown" test_type=""
        
        if [ -f "$vus_file" ] && [ $(wc -l < "$vus_file") -gt 1 ]; then
            local hdr=$(head -1 "$vus_file")
            if echo "$hdr" | grep -q "vus_group"; then
                local c=$(echo "$hdr" | tr ',' '\n' | grep -n "vus_group" | head -1 | cut -d: -f1)
                vus_label=$(tail -n +2 "$vus_file" | awk -F',' -v c="$c" '{v=$c; gsub(/^[ \t]+|[ \t]+$/,"",v); if(v!=""&&v!="null"){print v;exit}}')
            fi
            if echo "$hdr" | grep -q "test_type"; then
                local tc=$(echo "$hdr" | tr ',' '\n' | grep -n "test_type" | head -1 | cut -d: -f1)
                local tv=$(tail -n +2 "$vus_file" | awk -F',' -v c="$tc" '{v=$c; gsub(/^[ \t]+|[ \t]+$/,"",v); if(v!=""&&v!="null"){print v;exit}}')
                [ -n "$tv" ] && test_type="_${tv}"
            fi
        fi
        
        # 최종 대상 폴더 (예: csv_results/VUs_50_standard)
        local final_dir="${CSV_DIR}/VUs_${vus_label}${test_type}"
        echo "  - 정리 중: $(basename "$csv_dir") → $(basename "$final_dir")"
        
        # 기존에 같은 VUs 폴더가 있다면 과감히 삭제 후 덮어쓰기
        if [ -d "$final_dir" ]; then
            rm -rf "$final_dir"
        fi
        
        mv "$csv_dir" "$final_dir"
        count=$((count + 1))
    done

    [ $count -eq 0 ] && { echo "정리할 데이터가 없습니다."; return 0; }
    echo " [완료] ${count}개 세트 정리 완료 (압축 제외됨)"
}

# ----------------------------------------------------------------------------
case "$COMMAND" in
  setup-alias)
    SHELL_RC="$HOME/.bashrc"
    [[ "$SHELL" == *"zsh"* ]] || [ -f "$HOME/.zshrc" ] && SHELL_RC="$HOME/.zshrc"
    SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manage.sh"
    if grep -q "alias bm=" "$SHELL_RC"; then echo "[알림] 이미 등록됨"
    else echo -e "\n# API Benchmark Alias\nalias bm='$SCRIPT_PATH'" >> "$SHELL_RC"; echo "[완료] 'source $SHELL_RC' 실행 필요"; fi
    ;;

  start) docker compose up -d --build; sleep 5; init_influx_db ;;
  stop) docker compose down ;;
  restart) docker compose down; docker compose up -d --build; sleep 5; init_influx_db ;;
  clean) docker compose down -v --rmi all ;;

  test)
    init_influx_db
    run_k6 "bench_rest.js" "standard" "$VUS_ARG"
    countdown 30 "REST 종료 후 쿨다운"
    run_k6 "bench_gql.js" "standard" "$VUS_ARG"
    countdown 30 "GraphQL 종료 후 쿨다운"
    run_k6 "bench_grpc.js" "standard" "$VUS_ARG"
    ;;

  test-proxy)
    init_influx_db
    run_k6 "bench_grpc_envoy.js" "proxy_overhead" "$VUS_ARG"
    ;;

  test-spike)
    init_influx_db
    print_header " [스파이크 테스트] TC8 - 최대 5K 극한 부하"
    run_k6 "benchmark_tc8.js" "spike" "max_5k" "$GLOBAL_TIMESTAMP"
    
    # 다른 명령어와 동일하게 추출 및 폴더 덮어쓰기 정리 진행
    do_export_data "spike_backup" "$GLOBAL_TIMESTAMP"
    do_export_csv "current" "$GLOBAL_TIMESTAMP"
    do_package
    ;;

  test-all-cycle)
    shift; VUS_LIST="$@"
    [ -z "$VUS_LIST" ] && { echo "[에러] 사용법: ./manage.sh test-all-cycle 100 300 500"; exit 1; }

    init_influx_db
    TOTAL=$(echo "$VUS_LIST" | wc -w)
    CUR=0
    START_TIME=$(date +%s)

    print_header " [풀 사이클] VUs: $VUS_LIST (${TOTAL}세트 x 4프로토콜)"

    for VUS_TARGET in $VUS_LIST; do
        CUR=$((CUR + 1))
        CYCLE_TS=$(date +%Y%m%d_%H%M%S)
        
        echo -e "\n========== [${CUR}/${TOTAL}] VUs = ${VUS_TARGET} =========="
        run_benchmark_suite "$VUS_TARGET" "$CYCLE_TS"
        do_export_data "cycle_vus${VUS_TARGET}" "$CYCLE_TS"
        do_export_csv "current" "$CYCLE_TS"

        [ "$CUR" -lt "$TOTAL" ] && countdown 60 "다음 VUs 세트 진행 전 쿨다운"
    done

    echo ""
    print_header " 🏁 사이클 완료! 데이터 정리 중..."
    do_package

    END_TIME=$(date +%s)
    ELAPSED=$(( (END_TIME - START_TIME) / 60 ))
    print_header " 🎉 전체 소요: ${ELAPSED}분 | ${TOTAL}세트 완료"
    ;;

  export) do_export_data "k6_manual" "$GLOBAL_TIMESTAMP" ;;
  export-csv) do_export_csv "${3:-all}" "$GLOBAL_TIMESTAMP" ;;
  restore-all) init_influx_db; do_restore_all ;;
  export-full) init_influx_db; do_export_full ;;
  package) do_package ;;
  logs) docker compose logs -f ;;

  *)
    echo "사용법: ./manage.sh [명령어] [VUs]"
    echo "----------------------------------------------------------------------"
    echo " [초기 설정]"
    echo "  setup-alias                  : 'bm' 단축키 등록"
    echo ""
    echo " [테스트]"
    echo "  test [VUs]                   : TC1~7 격리 (REST→GQL→gRPC)"
    echo "  test-all-cycle 50 100 ..     : 다중 VUs 자동화 테스트 (폴더 덮어쓰기)"
    echo "  test-spike                   : TC8 스파이크 5K 극한 테스트"
    echo "  test-proxy [VUs]             : TC9 Envoy 단독"
    echo ""
    echo " [데이터]"
    echo "  export / export-csv / restore-all / export-full / package"
    echo ""
    echo " [관리]"
    echo "  start / stop / restart / clean / logs"
    echo "----------------------------------------------------------------------"
    exit 1
    ;;
esac