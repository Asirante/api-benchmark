#!/bin/bash

# 추가 실험 A/B/C 실행기 (manage.sh 는 수정하지 않고 동일한 k6 / InfluxDB / docker stats 파이프라인을 사용)
#   A. REST 응답 필드 축소 (tc5 vs tc5_slim, 같은 실행 안에서 짝 비교)
#   B. 반복 대기 지터 (sleep(1) vs sleep(rand*2))
#   C. 개방 루프 (constant-arrival-rate, dropped_iterations 수집)
# 권한 부여: chmod +x experiments.sh

COMMAND=${1:-help}

# ----------------------------------------------------------------------------
# 설정 (모두 환경변수로 덮어쓸 수 있음)
REPS=${REPS:-3}
VUS_LEVELS=${VUS_LEVELS:-"300 400 500"}
RATES=${RATES:-"140 290 385 480 640 800 1000 1200"}
ARCHS=${ARCHS:-"rest graphql grpc"}
OPEN_DURATION=${OPEN_DURATION:-60s}
PRE_VUS=${PRE_VUS:-1000}
COOLDOWN=${COOLDOWN:-20}
SHUFFLE=${SHUFFLE:-1}
QUIET_CPU=${QUIET_CPU:-5}     # 다음 실행 전 DB·API CPU(%)가 이 값 미만이 될 때까지 대기
QUIET_MAX=${QUIET_MAX:-180}   # 최대 대기 초
K6_IMAGE=${K6_IMAGE:-grafana/k6}
SESSION_ID=${SESSION_ID:-$(date +%Y%m%d_%H%M%S)}

INFLUX_DB_NAME="k6"
INFLUX_URL="http://benchmark_influxdb:8086"
DOCKER_NETWORK="api-benchmark_default"
CSV_DIR="./csv_results"
RESOURCE_DIR="./resource_logs"
RESOURCE_INTERVAL=2
RESOURCE_CONTAINERS=("benchmark_rest" "benchmark_graphql" "benchmark_grpc" "benchmark_db" "benchmark_envoy")
K6_CONTAINER="benchmark_k6"
PSQL=(docker exec benchmark_db psql -U benchmark_user -d olist_db)

OUT_DIR="${CSV_DIR}/exp_${SESSION_ID}"
MANIFEST="${OUT_DIR}/manifest.csv"

VALID_ID="e481f51cbdc54678b7cc49136f2d6af7"

# manage.sh 의 METRICS + 실험 C 용 반복 지표
METRICS=(
    "http_req_duration" "grpc_req_duration" "http_reqs"
    "http_req_waiting" "http_req_blocked" "http_req_connecting"
    "http_req_sending" "http_req_receiving"
    "checks" "http_req_failed"
    "vus"
    "iterations" "iteration_duration" "dropped_iterations"
)

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

# ----------------------------------------------------------------------------
print_header() {
    echo "============================================================"
    echo " $1"
    echo "============================================================"
}

script_for()    { case "$1" in rest) echo bench_rest.js ;; graphql) echo bench_gql.js ;; grpc) echo bench_grpc.js ;; esac; }
container_for() { case "$1" in rest) echo benchmark_rest ;; graphql) echo benchmark_graphql ;; grpc) echo benchmark_grpc ;; esac; }

run_influx_query() {
    local query=$1
    local output_file=$2
    docker exec benchmark_influxdb influx -database "$INFLUX_DB_NAME" -precision rfc3339 -execute "$query" -format csv > "$output_file"
}

# ----------------------------------------------------------------------------
# 실행 계획: "exp|arch|cond|level|rep" 한 줄이 k6 실행 1회
#   level = VUs (A, B) 또는 초당 도착률 (C)
build_plan() {
    local which=$1
    local rep
    for rep in $(seq 1 "$REPS"); do
        {
            local v a r
            if [[ "$which" == all || "$which" == a ]]; then
                for v in $VUS_LEVELS; do echo "A|rest|slim|$v|$rep"; done
            fi
            if [[ "$which" == all || "$which" == b ]]; then
                for v in $VUS_LEVELS; do for a in $ARCHS; do
                    echo "B|$a|jitter0|$v|$rep"
                    echo "B|$a|jitter1|$v|$rep"
                done; done
            fi
            if [[ "$which" == all || "$which" == c ]]; then
                for r in $RATES; do for a in $ARCHS; do echo "C|$a|open|$r|$rep"; done; done
            fi
        } | if [ "$SHUFFLE" == "1" ]; then
            # 반복(rep) 단위로 조건 순서를 섞어 시간에 따른 드리프트가 특정 조건에 몰리지 않게 함 (시드 고정 → 재현 가능)
            shuf --random-source=<(yes "${SESSION_ID}_${rep}")
        else
            cat
        fi
    done
}

run_id_for() {
    local exp=$1 arch=$2 cond=$3 level=$4 rep=$5
    local unit="vus"; [ "$exp" == "C" ] && unit="rps"
    echo "exp${exp}_${arch}_${cond}_${level}${unit}_rep${rep}_${SESSION_ID}"
}

# ----------------------------------------------------------------------------
# 리소스 수집: manage.sh 와 같은 docker stats 루프·같은 컬럼, 파일만 역할별로 분리
#   *_api.csv   : 이번 실행의 대상 API 컨테이너
#   *_db.csv    : benchmark_db
#   *_k6.csv    : 부하 생성기 (같은 호스트에서 SUT 와 CPU 를 나눠 쓰므로 병목 여부 확인용)
#   *_other.csv : 나머지 (유휴 API, envoy)
# k6 컨테이너는 수집 시작 시점에 아직 없으므로, 이름을 나열하는 대신 실행 중인 컨테이너 전체를 받아 분류
start_resource_collector() {
    local prefix=$1 api_container=$2
    mkdir -p "$(dirname "$prefix")"
    local role f
    for role in api db k6 other; do echo "time,container,cpu_perc,mem_usage" > "${prefix}_${role}.csv"; done

    (
        trap "exit 0" SIGTERM SIGINT
        while true; do
            local ts=$(date '+%Y-%m-%dT%H:%M:%S')
            docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" 2>/dev/null | while read line; do
                [ -z "$line" ] && continue
                case "${line%%,*}" in
                    "$api_container")  f="${prefix}_api.csv" ;;
                    benchmark_db)      f="${prefix}_db.csv" ;;
                    "$K6_CONTAINER")   f="${prefix}_k6.csv" ;;
                    benchmark_*)       f="${prefix}_other.csv" ;;
                    *)                 continue ;;
                esac
                echo "${ts},${line}" >> "$f"
            done
            sleep "$RESOURCE_INTERVAL"
        done
    ) </dev/null >/dev/null 2>&1 &

    echo $!
}

stop_resource_collector() {
    local pid=$1
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi
}

# ----------------------------------------------------------------------------
# 멈춤(stall) 원인 추적용 진단
#   - DB 로그: 체크포인트, autovacuum, 1초 이상 락 대기, 1초 이상 걸린 SQL
#   - pg_activity.csv : 2초 간격 클라이언트 세션 상태·대기 이벤트 분포 (Lock/LWLock/IO 대기 식별)
#   - host_vmstat.log : 1초 간격 WSL VM 전체 CPU (st=하이퍼바이저 steal, wa=I/O 대기) → 호스트 차원의 멈춤 식별
#   - pg_stats_before/after.txt : 체크포인트·autovacuum 누적 카운터 스냅샷
enable_db_logging() {
    "${PSQL[@]}" -q \
        -c "ALTER SYSTEM SET log_checkpoints = on" \
        -c "ALTER SYSTEM SET log_autovacuum_min_duration = 0" \
        -c "ALTER SYSTEM SET log_lock_waits = on" \
        -c "ALTER SYSTEM SET log_min_duration_statement = 1000" \
        -c "SELECT pg_reload_conf()" > /dev/null || { echo "[에러] DB 로그 설정 실패"; exit 1; }
    echo "[완료] DB 로그 설정: $("${PSQL[@]}" -Atc "SELECT string_agg(name || '=' || setting, ', ') FROM pg_settings WHERE name IN ('log_checkpoints','log_autovacuum_min_duration','log_lock_waits','log_min_duration_statement')")"
}

pg_stats_snapshot() {
    "${PSQL[@]}" -c "SELECT now() AS at, checkpoints_timed, checkpoints_req, checkpoint_write_time, checkpoint_sync_time, buffers_checkpoint, buffers_backend FROM pg_stat_bgwriter" \
        -c "SELECT relname, n_tup_ins, n_live_tup, n_dead_tup, autovacuum_count, autoanalyze_count, last_autovacuum, last_autoanalyze FROM pg_stat_user_tables WHERE relname LIKE 'olist_order%' ORDER BY relname" \
        > "$1" 2>&1
}

start_diagnostics() {
    local dir=$1
    vmstat -t 1 > "${dir}/host_vmstat.log" 2>&1 &
    local vmstat_pid=$!
    echo "time,state,wait_event_type,wait_event,count" > "${dir}/pg_activity.csv"
    (
        trap "exit 0" SIGTERM SIGINT
        while true; do
            "${PSQL[@]}" -AtF, -c "SELECT to_char(clock_timestamp() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD\"T\"HH24:MI:SS'), coalesce(state, ''), coalesce(wait_event_type, ''), coalesce(wait_event, ''), count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() GROUP BY 2, 3, 4" >> "${dir}/pg_activity.csv" 2>/dev/null
            sleep 2
        done
    ) </dev/null >/dev/null 2>&1 &
    echo "$vmstat_pid $!"
}

stop_diagnostics() {
    local pid
    for pid in $1; do
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    done
}

# 과부하 실행 뒤 비동기 쓰기 큐 소진·autovacuum 이 다음 실행에 겹치지 않도록 DB·API 가 조용해질 때까지 대기
wait_until_quiet() {
    local waited=0 busy
    while [ "$waited" -lt "$QUIET_MAX" ]; do
        busy=$(docker stats --no-stream --format "{{.Name}} {{.CPUPerc}}" benchmark_db benchmark_rest benchmark_graphql benchmark_grpc 2>/dev/null \
            | awk -v t="$QUIET_CPU" '{gsub("%","",$2); if ($2+0 >= t) printf "%s(%s%%) ", $1, $2}')
        [ -z "$busy" ] && break
        echo "  [대기] 아직 바쁨: ${busy}"
        sleep 5; waited=$((waited + 5))
    done
    echo "$waited"
}

# ----------------------------------------------------------------------------
preflight() {
    print_header " [사전 점검]"
    command -v docker >/dev/null || { echo "[에러] docker 명령을 찾을 수 없습니다 (Docker Desktop WSL 통합 확인)"; exit 1; }
    local c
    for c in benchmark_db benchmark_rest benchmark_graphql benchmark_grpc benchmark_influxdb; do
        docker ps --format '{{.Names}}' | grep -qx "$c" || { echo "[에러] $c 컨테이너가 실행 중이지 않습니다 (./manage.sh start)"; exit 1; }
    done
    docker exec benchmark_influxdb influx -execute "CREATE DATABASE $INFLUX_DB_NAME" > /dev/null 2>&1 || { echo "[에러] InfluxDB DB 생성 실패"; exit 1; }

    local body
    body=$(curl -s "http://localhost:8080/api/v1/orders/details/${VALID_ID}")
    echo "$body" | grep -q '"order_id"' || { echo "[에러] REST /details 응답 이상 (DB 데이터 적재 확인): $body"; exit 1; }

    body=$(curl -s "http://localhost:8080/api/v1/orders/slim/${VALID_ID}")
    if ! echo "$body" | grep -q '"items"'; then
        echo "[에러] REST /slim 응답 이상: $body"
        echo "       '404 page not found' 이면 REST 이미지가 새 코드로 재빌드되지 않은 것입니다 (./manage.sh restart)"
        exit 1
    fi

    body=$(curl -s -H 'Content-Type: application/json' -d "{\"query\":\"query { getSimpleOrder(id: \\\"${VALID_ID}\\\") { order_id } }\"}" http://localhost:8081/query)
    echo "$body" | grep -q '"order_id"' || { echo "[에러] GraphQL 응답 이상: $body"; exit 1; }

    echo "[완료] 컨테이너·데이터·/slim 엔드포인트 확인"
    enable_db_logging
}

# ----------------------------------------------------------------------------
export_run_csv() {
    local run_id=$1 dir=$2
    local cols="\"time\", \"api\", \"tc\", \"status\", \"exp\", \"arch\", \"cond\", \"rep\", \"vus_group\", \"rate\", \"test_type\", \"run_id\", \"value\""
    local metric q
    for metric in "${METRICS[@]}"; do
        case "$metric" in
            vus|dropped_iterations|iterations|iteration_duration)
                q="SELECT \"time\", \"scenario\", \"exp\", \"arch\", \"cond\", \"rep\", \"vus_group\", \"rate\", \"test_type\", \"run_id\", \"value\"" ;;
            checks)
                q="SELECT \"time\", \"group\", \"check\", \"exp\", \"arch\", \"cond\", \"rep\", \"vus_group\", \"rate\", \"test_type\", \"run_id\", \"value\"" ;;
            *)
                q="SELECT ${cols}" ;;
        esac
        run_influx_query "${q} FROM \"${metric}\" WHERE \"run_id\"='${run_id}' tz('Asia/Seoul')" "${dir}/${metric}.csv"
        # 해당 프로토콜에 없는 지표(예: REST 의 grpc_req_duration)는 빈 파일로 남기지 않음
        [ ! -s "${dir}/${metric}.csv" ] && rm -f "${dir}/${metric}.csv"
    done
}

run_one() {
    local exp=$1 arch=$2 cond=$3 level=$4 rep=$5
    local run_id=$(run_id_for "$exp" "$arch" "$cond" "$level" "$rep")
    local script=$(script_for "$arch")
    local dir="${OUT_DIR}/${run_id}"

    if [ -f "$MANIFEST" ] && grep -q "^${run_id}," "$MANIFEST"; then
        echo "  [건너뜀] 이미 완료: $run_id"
        return 2
    fi

    local test_mode="standard" jitter=0 slim=0 vus=$level rate=""
    case "$cond" in
        slim)    slim=1 ;;
        jitter1) jitter=1 ;;
        open)    test_mode="open_loop"; rate=$level; vus="" ;;
    esac

    echo "------------------------------------------------------------"
    echo " 🚀 [실행] $run_id | $script | mode=$test_mode JITTER=$jitter TC5_SLIM=$slim VUS=${vus:--} RATE=${rate:--}"
    echo "------------------------------------------------------------"

    mkdir -p "$dir"
    local resource_prefix="${RESOURCE_DIR}/resource_${run_id}"
    local resource_pid=$(start_resource_collector "$resource_prefix" "$(container_for "$arch")")
    pg_stats_snapshot "${dir}/pg_stats_before.txt"
    local diag_pids=$(start_diagnostics "$dir")
    local started=$(date '+%Y-%m-%dT%H:%M:%S%z') started_epoch=$(date +%s)

    docker rm -f "$K6_CONTAINER" >/dev/null 2>&1
    docker run --rm --name "$K6_CONTAINER" \
      --user "$(id -u):$(id -g)" \
      --ulimit nofile=65535:65535 \
      -v "$(pwd)":/app -w /app \
      --network "$DOCKER_NETWORK" \
      -e VUS="$vus" \
      -e TEST_MODE="$test_mode" \
      -e JITTER="$jitter" \
      -e TC5_SLIM="$slim" \
      -e RATE="$rate" \
      -e DURATION="$OPEN_DURATION" \
      -e PRE_VUS="$PRE_VUS" \
      "$K6_IMAGE" run \
      --out influxdb=$INFLUX_URL/$INFLUX_DB_NAME \
      --summary-trend-stats "avg,min,med,max,p(95),p(99),count" \
      --summary-export "${dir}/k6_summary.json" \
      --tag run_id="$run_id" \
      --tag test_type="exp_$(echo "$exp" | tr 'A-Z' 'a-z')" \
      --tag exp="$exp" \
      --tag arch="$arch" \
      --tag cond="$cond" \
      --tag rep="$rep" \
      --tag vus_group="${vus:-open}" \
      --tag rate="${rate:-closed}" \
      --tag session_id="$SESSION_ID" \
      "$script" 2>&1 | tee "${dir}/k6_stdout.log"
    local k6_exit=${PIPESTATUS[0]}
    local ended=$(date '+%Y-%m-%dT%H:%M:%S%z') ended_epoch=$(date +%s)

    stop_resource_collector "$resource_pid"
    stop_diagnostics "$diag_pids"
    cp "${resource_prefix}"_*.csv "$dir/"
    pg_stats_snapshot "${dir}/pg_stats_after.txt"
    docker logs --since "$started_epoch" --until "$((ended_epoch + 1))" benchmark_db > "${dir}/db_log.txt" 2>&1

    echo "  [추출] InfluxDB → ${dir}"
    export_run_csv "$run_id" "$dir"

    echo "${run_id},${exp},${arch},${cond},${level},${rep},${started},${ended},${k6_exit}" >> "$MANIFEST"
    [ "$k6_exit" -ne 0 ] && echo "  [경고] k6 종료 코드 ${k6_exit} (manifest 에 기록됨)"
    return 0
}

run_plan() {
    local which=$1
    mkdir -p "$OUT_DIR" "$RESOURCE_DIR"
    [ -f "$MANIFEST" ] || echo "run_id,exp,arch,cond,level,rep,started,ended,k6_exit" > "$MANIFEST"

    local plan=$(build_plan "$which")
    local total=$(echo "$plan" | wc -l) cur=0 start=$(date +%s)
    echo "$plan" > "${OUT_DIR}/plan_${which}.txt"
    print_header " [실험 ${which}] 총 ${total}회 실행 | 세션 ${SESSION_ID} | 결과 → ${OUT_DIR}"

    while IFS='|' read -r exp arch cond level rep; do
        cur=$((cur + 1))
        echo -e "\n========== [${cur}/${total}] ${exp} ${arch} ${cond} ${level} rep${rep} =========="
        run_one "$exp" "$arch" "$cond" "$level" "$rep" || continue
        if [ "$cur" -lt "$total" ]; then
            echo ">>> 쿨다운 ${COOLDOWN}초"; sleep "$COOLDOWN"
            local waited=$(wait_until_quiet | tee /dev/stderr | tail -1)
            echo "$(run_id_for "$exp" "$arch" "$cond" "$level" "$rep"),${waited}" >> "${OUT_DIR}/quiet_waits.csv"
        fi
    done <<< "$plan"

    print_header " 🏁 완료: ${total}회, $(( ($(date +%s) - start) / 60 ))분 소요"
    summarize
}

summarize() {
    python3 analysis/summarize_experiments.py "$OUT_DIR"
}

# ----------------------------------------------------------------------------
# 실행 시점의 실제 버전·설정 기록 (environment.md 의 '실행 시 확인' 항목을 채움)
collect_env() {
    mkdir -p "$OUT_DIR"
    local f="${OUT_DIR}/environment_runtime.txt"
    local tmp=$(mktemp -d)
    {
        echo "# collected: $(date '+%Y-%m-%dT%H:%M:%S%z')  session: ${SESSION_ID}"
        echo "## git";           git rev-parse HEAD 2>/dev/null; git status --short 2>/dev/null
        echo "## host CPU";      lscpu | grep -E 'Model name|^CPU\(s\)|Thread|Core|Socket|Hypervisor'
        echo "## host memory";   free -h
        echo "## kernel";        uname -r; grep PRETTY /etc/os-release
        echo "## docker";        docker version --format 'server {{.Server.Version}} / client {{.Client.Version}}'
        docker info --format 'docker VM: NCPU={{.NCPU}} MemTotal={{.MemTotal}} OS={{.OperatingSystem}} Kernel={{.KernelVersion}}'
        docker compose version
        echo "## images (digest)"
        local img
        for img in postgres:15-alpine envoyproxy/envoy:v1.27.0 influxdb:1.8 "$K6_IMAGE" golang:1.24-alpine alpine:3.19; do
            echo "$img -> $(docker image inspect --format '{{index .RepoDigests 0}}' "$img" 2>/dev/null || echo '(로컬에 없음)')"
        done
        echo "## k6";            docker run --rm "$K6_IMAGE" version
        echo "## PostgreSQL";    docker exec benchmark_db postgres --version
        docker exec benchmark_db psql -U benchmark_user -d olist_db -Atc "SELECT name || '=' || setting FROM pg_settings WHERE name IN ('max_connections','shared_buffers','work_mem','synchronous_commit','effective_cache_size')"
        docker exec benchmark_db psql -U benchmark_user -d olist_db -Atc "SELECT 'orders rows=' || count(*) FROM olist_orders_dataset"
        echo "## Envoy";         docker exec benchmark_envoy envoy --version
        echo "## InfluxDB";      docker exec benchmark_influxdb influxd version
        echo "## Go binaries (컨테이너 안의 실제 빌드 정보)"
        local c
        for c in benchmark_rest benchmark_graphql benchmark_grpc; do
            docker cp "$c:/root/main" "$tmp/$c" >/dev/null 2>&1 && \
            docker run --rm -v "$tmp":/b golang:1.24-alpine go version -m "/b/$c" | grep -E "^/b|gqlgen|google.golang.org/grpc\s|gorm|pgx|gin-gonic/gin\s|protobuf\s"
        done
    } > "$f" 2>&1
    rm -rf "$tmp"
    echo "[완료] 실행 환경 기록 → $f"
}

# ----------------------------------------------------------------------------
case "$COMMAND" in
  plan)      build_plan "${2:-all}" | nl ;;
  env)       collect_env ;;
  all|a|b|c) preflight; collect_env; run_plan "$COMMAND" ;;
  summarize) summarize ;;
  *)
    echo "사용법: ./experiments.sh [명령어]"
    echo "----------------------------------------------------------------------"
    echo "  plan [all|a|b|c]  : 실행 순서만 출력 (실행 안 함)"
    echo "  all               : 실험 A+B+C 전체 (기본 3회 반복, VUs 300/400/500, rate 140~1200 8단계)"
    echo "  a | b | c         : 개별 실험만 실행"
    echo "  env               : 실행 환경(버전·설정) 기록"
    echo "  summarize         : SESSION_ID 의 결과를 요약 CSV 로 집계"
    echo ""
    echo " 환경변수: REPS VUS_LEVELS RATES ARCHS OPEN_DURATION PRE_VUS COOLDOWN QUIET_CPU QUIET_MAX SHUFFLE K6_IMAGE SESSION_ID"
    echo "   중단 후 재개: SESSION_ID=<기존 세션> ./experiments.sh all  (manifest 에 있는 실행은 건너뜀)"
    echo "----------------------------------------------------------------------"
    exit 1
    ;;
esac
