#!/bin/bash

# 후속 실험 D/E 실행기 (experiments.sh 는 A/B/C 재현용으로 그대로 두고, 필요한 수집 함수는 복사해서 사용)
#   D. 커넥션 풀 크기 스윕: 풀(open:idle) × 개방 루프 rate × 아키텍처
#   E. GraphQL TC3 쿼리 수 보정: GQL_TC3_LIGHT=0/1 × rate (풀 500:100 블록 안에서 실행)
# 권한 부여: chmod +x experiments_de.sh

COMMAND=${1:-help}

# ----------------------------------------------------------------------------
# 설정 (모두 환경변수로 덮어쓸 수 있음)
REPS=${REPS:-3}
POOLS=${POOLS:-"20:20 50:50 100:100 500:100 500:500"}   # MaxOpen:MaxIdle
BASELINE_POOL=${BASELINE_POOL:-"500:100"}                # 직전 세션과 같은 설정. 실험 E 도 이 블록에서 실행
GATE_RATES=${GATE_RATES:-"640 700"}     # 기준 조건 rate. 앞에서 붕괴가 없으면 다음 rate 로 한 단계만 상향
SAT_RATE=${SAT_RATE:-800}               # 포화 구간 비교 (가설 1 대체 판정 경로)
CONTRAST_RATE=${CONTRAST_RATE:-480}     # 용량의 약 70% 지점 대조
CONTRAST_POOLS=${CONTRAST_POOLS:-"20:20"}  # 480 rps 대조로 추가 실행할 풀 (500:100 은 세션 de_20260916_0241 데이터 사용)
E_RATES=${E_RATES:-"480 640 800"}
INCLUDE_E=${INCLUDE_E:-1}
ARCHS=${ARCHS:-"rest graphql grpc"}
DURATION_MAP=${DURATION_MAP:-"480:180s 640:180s 700:180s 800:60s"}  # 붕괴 검출이 목적인 rate 는 180초, 포화 비교는 60초
DURATION_DEFAULT=${DURATION_DEFAULT:-60s}
PRE_VUS=${PRE_VUS:-1000}
COOLDOWN=${COOLDOWN:-20}
QUIET_CPU=${QUIET_CPU:-5}
QUIET_MAX=${QUIET_MAX:-180}
WARMUP_RATE=${WARMUP_RATE:-100}
WARMUP_DURATION=${WARMUP_DURATION:-20s}
MEM_GUARD_KB=${MEM_GUARD_KB:-4000000}  # 실행 전 MemAvailable 이 이보다 작으면 페이지 캐시 비우고 워밍업
SWAPPINESS=${SWAPPINESS:-10}
EXPORT_METRICS=${EXPORT_METRICS:-reduced}  # reduced | full
K6_PUSH_INTERVAL=${K6_PUSH_INTERVAL:-250ms}
K6_IMAGE=${K6_IMAGE:-grafana/k6}
SHUFFLE=${SHUFFLE:-1}
CLOCK_DRIFT_MAX_PCT=${CLOCK_DRIFT_MAX_PCT:-3}   # 풀 블록 사이 시계 드리프트가 이 값을 넘으면 중단
CLOCK_MIN_INTERVAL=${CLOCK_MIN_INTERVAL:-120}   # 판정에 쓰는 최소 구간(초). 실시간 시계가 약 30초마다 계단식으로 보정되므로 짧은 구간은 판정하지 않음
SESSION_ID=${SESSION_ID:-de_$(date +%Y%m%d_%H%M%S)}

INFLUX_DB_NAME="k6"
INFLUX_URL="http://benchmark_influxdb:8086"
DOCKER_NETWORK="api-benchmark_default"
COMPOSE=(docker compose -f docker-compose.yml -f docker-compose.exp.yml)
CSV_DIR="./csv_results"
RESOURCE_INTERVAL=2
K6_CONTAINER="benchmark_k6"
PSQL=(docker exec benchmark_db psql -U benchmark_user -d olist_db)
HELPER_IMAGE="postgres:15-alpine"   # 권한 컨테이너(sysctl, drop_caches)용. 이미 로컬에 있는 이미지 사용

OUT_DIR="${CSV_DIR}/exp_${SESSION_ID}"
MANIFEST="${OUT_DIR}/manifest.csv"
MANIFEST_HEADER="run_id,exp,arch,pool_open,pool_idle,rate,duration,light,rep,started,ended,k6_exit,influx_completeness,mem_available_kb,swap_used_kb,cache_dropped"

VALID_ID="e481f51cbdc54678b7cc49136f2d6af7"

REDUCED_METRICS=("http_req_duration" "grpc_req_duration" "iterations" "dropped_iterations" "vus" "checks")
FULL_METRICS=(
    "http_req_duration" "grpc_req_duration" "http_reqs"
    "http_req_waiting" "http_req_blocked" "http_req_connecting"
    "http_req_sending" "http_req_receiving"
    "checks" "http_req_failed"
    "vus" "iterations" "iteration_duration" "dropped_iterations"
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
service_for()   { case "$1" in rest) echo rest-api ;; graphql) echo graphql-api ;; grpc) echo grpc-api ;; esac; }
duration_for() {
    local r p
    for p in $DURATION_MAP; do [ "${p%%:*}" == "$1" ] && { echo "${p##*:}"; return; }; done
    echo "$DURATION_DEFAULT"
}
meminfo_kb()    { awk -v k="$1:" '$1 == k {print $2}' /proc/meminfo; }

run_influx_query() {
    docker exec benchmark_influxdb influx -database "$INFLUX_DB_NAME" -precision rfc3339 -execute "$1" -format csv
}

privileged() {
    docker run --rm --privileged --pull never --entrypoint sh "$HELPER_IMAGE" -c "$1"
}

# ----------------------------------------------------------------------------
# 실행 계획: "exp|arch|open|idle|rate|light|rep" 한 줄이 k6 실행 1회
#   반복(rep) 마다 풀 블록 순서를 섞고, 블록 안에서 조건 순서를 섞음 (시드 = 세션 ID)
shuffle_with() {
    if [ "$SHUFFLE" == "1" ]; then shuf --random-source=<(yes "$1"); else cat; fi
}

block_entries() {
    local pool=$1 rep=$2 open=${1%%:*} idle=${1##*:} a r
    local collapse_rate=$(cat "${OUT_DIR}/gate_rate.txt" 2>/dev/null)
    local eligible=$(cat "${OUT_DIR}/gate_eligible.txt" 2>/dev/null)
    {
        # 포화 구간 비교: 전 풀 × 전 아키텍처 (가설 1 대체 판정 경로)
        for a in $ARCHS; do echo "D|$a|$open|$idle|$SAT_RATE|0|$rep"; done
        # 붕괴가 재현된 rate 가 있으면 그 rate 를 전 풀 × 해당 아키텍처로 실행 (가설 1 본 판정 경로)
        if [ -n "$eligible" ] && [ -n "$collapse_rate" ]; then
            for a in $eligible; do echo "D|$a|$open|$idle|$collapse_rate|0|$rep"; done
        fi
        # 480 rps 대조 (지정한 풀에서만)
        if echo " $CONTRAST_POOLS " | grep -q " $pool "; then
            for a in $ARCHS; do echo "D|$a|$open|$idle|$CONTRAST_RATE|0|$rep"; done
        fi
        # 실험 E: GraphQL light 는 기준 풀 블록에서만
        if [ "$INCLUDE_E" == "1" ] && [ "$pool" == "$BASELINE_POOL" ]; then
            for r in $E_RATES; do echo "E|graphql|$open|$idle|$r|1|$rep"; done
        fi
    } | shuffle_with "${SESSION_ID}_${rep}_${pool}"
}

build_plan() {
    local rep pool
    for rep in $(seq 1 "$REPS"); do
        for pool in $(printf "%s\n" $POOLS | shuffle_with "${SESSION_ID}_${rep}_pools"); do
            block_entries "$pool" "$rep"
        done
    done
}

# 기준 조건(풀 500:100, 지정 rate) 만 — 붕괴 재현 여부 확인용
build_gate_plan() {
    local rate=$1 rep a open=${BASELINE_POOL%%:*} idle=${BASELINE_POOL##*:}
    for rep in $(seq 1 "$REPS"); do
        for a in $(printf "%s\n" $ARCHS | shuffle_with "${SESSION_ID}_${rep}_gate${rate}"); do
            echo "D|$a|$open|$idle|$rate|0|$rep"
        done
    done
}

run_id_for() {
    local exp=$1 arch=$2 open=$3 idle=$4 rate=$5 light=$6 rep=$7
    echo "exp${exp}_${arch}_p${open}i${idle}_${rate}rps_light${light}_rep${rep}_${SESSION_ID}"
}

# ----------------------------------------------------------------------------
# 풀 블록 시작: 세 API 를 해당 풀 설정으로 재생성 → 헬스체크 → 설정 반영 확인 → 워밍업
apply_pool() {
    local open=$1 idle=$2 dir="${OUT_DIR}/pool_checks"
    mkdir -p "$dir"
    echo ">>> [풀 블록] MaxOpen=${open} MaxIdle=${idle} 로 API 재생성"
    DB_MAX_OPEN_CONNS=$open DB_MAX_IDLE_CONNS=$idle DB_POOL_STATS_INTERVAL=1s \
        "${COMPOSE[@]}" up -d --no-deps --force-recreate rest-api graphql-api grpc-api >/dev/null 2>&1 \
        || { echo "[에러] API 재생성 실패"; exit 1; }

    local i ok=0
    for i in $(seq 1 60); do
        if curl -s "http://localhost:8080/api/v1/orders/simple/${VALID_ID}" | grep -q order_id \
           && curl -s -H 'Content-Type: application/json' -d "{\"query\":\"query { getSimpleOrder(id: \\\"${VALID_ID}\\\") { order_id } }\"}" http://localhost:8081/query | grep -q order_id \
           && (exec 3<>/dev/tcp/127.0.0.1/50051) 2>/dev/null; then
            ok=1; break
        fi
        sleep 1
    done
    [ "$ok" == "1" ] || { echo "[에러] API 헬스체크 실패"; exit 1; }

    local c expected="MaxOpen: ${open}, MaxIdle: $(( idle < open ? idle : open ))"
    for c in benchmark_rest benchmark_graphql benchmark_grpc; do
        docker logs "$c" 2>&1 | grep -q "$expected" || { echo "[에러] $c 기동 로그에 '$expected' 없음"; docker logs "$c" 2>&1 | tail -3; exit 1; }
    done

    warmup
    record_pool_check "$open" "$idle" "${dir}/p${open}i${idle}_$(date +%H%M%S).txt"
}

# 세 API 에 동시에 짧은 개방 루프 부하. InfluxDB 로 보내지 않음 (집계 대상 아님)
warmup() {
    local a pids=()
    for a in $ARCHS; do
        docker run --rm --user "$(id -u):$(id -g)" -v "$(pwd)":/app -w /app --network "$DOCKER_NETWORK" \
            -e TEST_MODE=open_loop -e RATE="$WARMUP_RATE" -e DURATION="$WARMUP_DURATION" -e PRE_VUS=200 \
            "$K6_IMAGE" run --quiet --no-summary "$(script_for "$a")" >/dev/null 2>&1 &
        pids+=($!)
    done
    wait "${pids[@]}"
}

# pg_stat_activity 로 API 별 실제 연결 수 확인 (워밍업 직후 = 유휴 연결이 풀 설정대로 남아 있는지)
record_pool_check() {
    local open=$1 idle=$2 f=$3
    {
        echo "# MaxOpen=${open} MaxIdle=${idle}  $(date '+%Y-%m-%dT%H:%M:%S%z')"
        local c
        for c in benchmark_rest benchmark_graphql benchmark_grpc; do
            echo "$c $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")"
        done
        "${PSQL[@]}" -AtF, -c "SELECT coalesce(host(client_addr), 'local'), count(*) FILTER (WHERE state = 'idle'), count(*) FILTER (WHERE state = 'active'), count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' GROUP BY 1 ORDER BY 1"
        for c in benchmark_rest benchmark_graphql benchmark_grpc; do
            echo "$c pool: $(docker logs "$c" 2>&1 | grep '\[pool\]' | tail -1)"
        done
    } > "$f" 2>&1
}

# ----------------------------------------------------------------------------
# 리소스 수집 (experiments.sh 와 같은 docker stats 루프, 역할별 파일)
start_resource_collector() {
    local prefix=$1 api_container=$2
    local role f
    for role in api db k6 other; do echo "time,container,cpu_perc,mem_usage" > "${prefix}_${role}.csv"; done
    (
        trap "exit 0" SIGTERM SIGINT
        while true; do
            local ts=$(date '+%Y-%m-%dT%H:%M:%S')
            docker stats --no-stream --format "{{.Name}},{{.CPUPerc}},{{.MemUsage}}" 2>/dev/null | while read line; do
                [ -z "$line" ] && continue
                case "${line%%,*}" in
                    "$api_container") f="${prefix}_api.csv" ;;
                    benchmark_db)     f="${prefix}_db.csv" ;;
                    "$K6_CONTAINER")  f="${prefix}_k6.csv" ;;
                    benchmark_*)      f="${prefix}_other.csv" ;;
                    *)                continue ;;
                esac
                echo "${ts},${line}" >> "$f"
            done
            sleep "$RESOURCE_INTERVAL"
        done
    ) </dev/null >/dev/null 2>&1 &
    echo $!
}

# 1초 간격 수집기. 매 초 docker exec 를 띄우지 않도록 컨테이너 안에서 장기 실행 프로세스 1개씩 사용
#   pg_activity.csv : client_addr × state × 대기 이벤트별 세션 수
#   pg_db_stats.csv : 백엔드 수, 누적 연결 생성 수(sessions), 커밋 수
#   cgroup_db.csv / cgroup_api.csv : cpu.stat (CPU 사용량, CFS 스로틀링)
PG_ACTIVITY_SQL="SELECT to_char(now() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS'), coalesce(host(client_addr), ''), coalesce(state, ''), coalesce(wait_event_type, ''), coalesce(wait_event, ''), count(*) FROM pg_stat_activity WHERE backend_type = 'client backend' AND pid <> pg_backend_pid() GROUP BY 2, 3, 4, 5"
PG_DB_STATS_SQL="SELECT to_char(now() AT TIME ZONE 'Asia/Seoul', 'YYYY-MM-DD\"T\"HH24:MI:SS.MS'), numbackends, sessions, sessions_abandoned, xact_commit FROM pg_stat_database WHERE datname = current_database()"
CGROUP_LOOP='echo $$ > /tmp/exp_cgroup.pid; while :; do echo "$(date +%s),$(awk '"'"'{printf "%s,", $2}'"'"' /sys/fs/cgroup/cpu.stat)"; sleep 1; done'

# 명령 치환 안에서 호출하면 백그라운드 프로세스를 기다리며 멈출 수 있으므로 PID 는 전역 변수로 돌려줌
WATCH_PIDS=()
start_watchers() {
    local dir=$1 api_container=$2
    WATCH_PIDS=()
    echo "time,client_addr,state,wait_event_type,wait_event,count" > "${dir}/pg_activity.csv"
    printf '%s\n\\watch 1\n' "$PG_ACTIVITY_SQL" | docker exec -i benchmark_db sh -c 'echo $$ > /tmp/exp_watch_activity.pid; exec psql -U benchmark_user -d olist_db -AtF,' \
        | grep --line-buffered -v '^$' >> "${dir}/pg_activity.csv" &
    WATCH_PIDS+=($!)
    echo "time,numbackends,sessions,sessions_abandoned,xact_commit" > "${dir}/pg_db_stats.csv"
    printf '%s\n\\watch 1\n' "$PG_DB_STATS_SQL" | docker exec -i benchmark_db sh -c 'echo $$ > /tmp/exp_watch_dbstats.pid; exec psql -U benchmark_user -d olist_db -AtF,' \
        | grep --line-buffered -v '^$' >> "${dir}/pg_db_stats.csv" &
    WATCH_PIDS+=($!)
    local header="epoch,$(docker exec benchmark_db awk '{printf "%s,", $1}' /sys/fs/cgroup/cpu.stat)"
    echo "$header" > "${dir}/cgroup_db.csv"
    echo "$header" > "${dir}/cgroup_api.csv"
    docker exec benchmark_db sh -c "$CGROUP_LOOP" >> "${dir}/cgroup_db.csv" 2>/dev/null &
    WATCH_PIDS+=($!)
    docker exec "$api_container" sh -c "$CGROUP_LOOP" >> "${dir}/cgroup_api.csv" 2>/dev/null &
    WATCH_PIDS+=($!)
    vmstat -t 1 > "${dir}/host_vmstat.log" 2>&1 &
    WATCH_PIDS+=($!)
}

stop_watchers() {
    local api_container=$1 pid i
    # psql 의 \watch 는 SIGINT 로 끝내야 출력 버퍼가 정상적으로 비워짐
    docker exec benchmark_db sh -c 'kill -INT $(cat /tmp/exp_watch_activity.pid) $(cat /tmp/exp_watch_dbstats.pid) 2>/dev/null; kill $(cat /tmp/exp_cgroup.pid) 2>/dev/null'
    docker exec "$api_container" sh -c 'kill $(cat /tmp/exp_cgroup.pid) 2>/dev/null'
    # 로컬 쪽 프로세스가 스스로 끝나기를 최대 5초 기다린 뒤 남은 것은 종료 (wait 로 무한 대기하지 않음)
    for i in 1 2 3 4 5; do
        local alive=0
        for pid in "${WATCH_PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
        [ "$alive" == "0" ] && break
        sleep 1
    done
    for pid in "${WATCH_PIDS[@]}"; do kill "$pid" 2>/dev/null; done
}

stop_pid() {
    [ -n "$1" ] && kill "$1" 2>/dev/null && wait "$1" 2>/dev/null
}

enable_db_logging() {
    "${PSQL[@]}" -q \
        -c "ALTER SYSTEM SET log_checkpoints = on" \
        -c "ALTER SYSTEM SET log_autovacuum_min_duration = 0" \
        -c "ALTER SYSTEM SET log_lock_waits = on" \
        -c "ALTER SYSTEM SET log_min_duration_statement = 1000" \
        -c "SELECT pg_reload_conf()" > /dev/null || { echo "[에러] DB 로그 설정 실패"; exit 1; }
}

pg_stats_snapshot() {
    "${PSQL[@]}" -c "SELECT now() AS at, checkpoints_timed, checkpoints_req, checkpoint_write_time, checkpoint_sync_time, buffers_checkpoint, buffers_backend FROM pg_stat_bgwriter" \
        -c "SELECT numbackends, sessions, sessions_abandoned, xact_commit FROM pg_stat_database WHERE datname = current_database()" \
        -c "SELECT relname, n_tup_ins, n_live_tup, n_dead_tup, autovacuum_count, autoanalyze_count, last_autovacuum FROM pg_stat_user_tables WHERE relname LIKE 'olist_order%' ORDER BY relname" \
        > "$1" 2>&1
}

wait_until_quiet() {
    local waited=0 busy
    while [ "$waited" -lt "$QUIET_MAX" ]; do
        busy=$(docker stats --no-stream --format "{{.Name}} {{.CPUPerc}}" benchmark_db benchmark_rest benchmark_graphql benchmark_grpc 2>/dev/null \
            | awk -v t="$QUIET_CPU" '{gsub("%","",$2); if ($2+0 >= t) printf "%s(%s%%) ", $1, $2}')
        [ -z "$busy" ] && break
        echo "  [대기] 아직 바쁨: ${busy}" >&2
        sleep 5; waited=$((waited + 5))
    done
    echo "$waited"
}

# ----------------------------------------------------------------------------
# 메모리: 세션 시작 시 swappiness 낮춤(종료 시 복원), 실행 전 가드
SWAPPINESS_ORIG=""
set_swappiness() {
    [ -n "$SWAPPINESS_ORIG" ] && return 0
    SWAPPINESS_ORIG=$(cat /proc/sys/vm/swappiness)
    privileged "sysctl -w vm.swappiness=${SWAPPINESS}" >/dev/null 2>&1
    echo "[메모리] vm.swappiness ${SWAPPINESS_ORIG} → $(cat /proc/sys/vm/swappiness)"
    echo "swappiness_orig=${SWAPPINESS_ORIG} swappiness_set=$(cat /proc/sys/vm/swappiness)" >> "${OUT_DIR}/session_settings.txt"
    trap restore_swappiness EXIT
}

restore_swappiness() {
    [ -n "$SWAPPINESS_ORIG" ] && privileged "sysctl -w vm.swappiness=${SWAPPINESS_ORIG}" >/dev/null 2>&1 \
        && echo "[메모리] vm.swappiness 복원 → $(cat /proc/sys/vm/swappiness)"
}

# 출력: "mem_available_kb swap_used_kb cache_dropped"
memory_guard() {
    local avail=$(meminfo_kb MemAvailable) swap_used=$(( $(meminfo_kb SwapTotal) - $(meminfo_kb SwapFree) )) dropped=0
    if [ "$avail" -lt "$MEM_GUARD_KB" ]; then
        echo "  [메모리] MemAvailable ${avail} kB < ${MEM_GUARD_KB} → 페이지 캐시 비우고 워밍업" >&2
        privileged "sync; echo 1 > /proc/sys/vm/drop_caches" >/dev/null 2>&1
        warmup
        dropped=1
    fi
    echo "$avail $swap_used $dropped"
}

# ----------------------------------------------------------------------------
# VM 시계 검사 (풀 블록 전환 시점에 대기 없이 기록)
#   drift = 직전 검사 이후 (실시간 시계 경과 - 단조 시계 경과) / 단조 시계 경과
#   실시간 시계는 Hyper-V 시간 동기화(hv_utils)로 호스트 시각에 맞춰지므로, k6·Go·cgroup 이 쓰는 단조 시계가
#   실제보다 느리거나 빠르면 이 값이 커짐 (2026-09-15 확인된 이상 상태에서 약 +11%)
#   chrony 는 WSL 에서 -x(시계 제어 안 함)로 실행되어 측정만 함. 선택 기준이 PHC0(Hyper-V 호스트 시계)와
#   인터넷 NTP 사이를 오가므로, 여러 번 조회해 두 기준의 값을 따로 기록 (해석용, 중단 판정에는 쓰지 않음)
CLOCK_PREV_R="" CLOCK_PREV_U="" CLOCK_START_R="" CLOCK_START_U="" CLOCK_CHECK_N=0
CLOCK_HEADER="check_id,time,label,realtime,monotonic,interval_mono_s,drift_pct_interval,drift_pct_session,ntp_ref,ntp_offset_s,ntp_freq_ppm,phc_offset_s,phc_freq_ppm,chrony_leap"

chrony_fields() {
    # 출력: ntp_ref,ntp_offset_s,ntp_freq_ppm,phc_offset_s,phc_freq_ppm,leap
    #   ntp_* : 인터넷 NTP 가 선택 기준일 때의 값 (freq_ppm 은 실제 시간 대비 VM 시계 속도 오차의 독립 추정치)
    #   phc_* : Hyper-V 호스트 시계(PHC0)가 선택 기준일 때의 값
    command -v chronyc >/dev/null || { echo ",,,,,unavailable"; return; }
    local i t ntp="" phc="" leap=""
    for i in 1 2 3 4 5 6 7 8; do
        t=$(chronyc -c tracking 2>/dev/null) || continue
        leap=$(cut -d, -f14 <<< "$t")
        if [ "$(cut -d, -f2 <<< "$t")" == "PHC0" ]; then
            [ -z "$phc" ] && phc=$(awk -F, '{printf "%s,%s", $5, $8}' <<< "$t")
        else
            [ -z "$ntp" ] && ntp=$(awk -F, '{printf "%s,%s,%s", $2, $5, $8}' <<< "$t")
        fi
        [ -n "$ntp" ] && [ -n "$phc" ] && break
        sleep 0.2
    done
    echo "${ntp:-,,},${phc:-,},${leap:-unavailable}"
}

clock_check() {
    local label=$1
    local r=$(date +%s.%N) u=$(cut -d' ' -f1 /proc/uptime)
    local chrony=$(chrony_fields)
    local f="${OUT_DIR}/clock_checks.csv"
    [ -f "$f" ] || echo "$CLOCK_HEADER" > "$f"
    CLOCK_CHECK_N=$((CLOCK_CHECK_N + 1))
    local interval="" drift="" drift_session=""
    if [ -n "$CLOCK_PREV_R" ]; then
        read -r interval drift drift_session < <(awk -v r="$r" -v u="$u" -v pr="$CLOCK_PREV_R" -v pu="$CLOCK_PREV_U" -v sr="$CLOCK_START_R" -v su="$CLOCK_START_U" \
            'BEGIN { du = u - pu; dsu = u - su; printf "%.1f %.2f %.2f\n", du, (du > 0 ? ((r - pr) - du) / du * 100 : 0), (dsu > 0 ? ((r - sr) - dsu) / dsu * 100 : 0) }')
    else
        CLOCK_START_R=$r; CLOCK_START_U=$u
    fi
    echo "${CLOCK_CHECK_N},$(date '+%Y-%m-%dT%H:%M:%S%z'),${label},${r},${u},${interval},${drift},${drift_session},${chrony}" >> "$f"
    IFS=, read -r n_ref n_offset n_freq p_offset p_freq c_leap <<< "$chrony"
    echo "  [시계] #${CLOCK_CHECK_N} ${label}: 구간 ${interval:--}초 드리프트 ${drift:--}% (세션 누적 ${drift_session:--}%) | chrony NTP(${n_ref:-?}) 속도오차 ${n_freq:-?}ppm 오프셋 ${n_offset:-?}s, PHC0 오프셋 ${p_offset:-?}s ${c_leap}"
    [ "$c_leap" != "Normal" ] && echo "  [시계 경고] chrony 동기화 상태: ${c_leap} (드리프트 판정은 계속 수행)"
    CLOCK_PREV_R=$r; CLOCK_PREV_U=$u
    if [ -n "$drift" ] && awk -v i="$interval" -v d="$drift" -v m="$CLOCK_DRIFT_MAX_PCT" -v mi="$CLOCK_MIN_INTERVAL" \
        'BEGIN { exit !(i >= mi && (d > m || d < -m)) }'; then
        print_header " [중단] 시계 드리프트 ${drift}% > ${CLOCK_DRIFT_MAX_PCT}% (${label} 직전 구간). 남은 실행을 진행하지 않음"
        echo "  직전 풀 블록의 데이터는 clock_checks.csv #$((CLOCK_CHECK_N - 1))~#${CLOCK_CHECK_N} 구간이므로 사용하지 말 것"
        python3 analysis/summarize_de.py "$OUT_DIR"
        exit 3
    fi
}

# 세션 시작 시 시간 동기화 구성 기록
record_session_meta() {
    cat > "${OUT_DIR}/session_meta.txt" <<META
gate_rates=${GATE_RATES}
sat_rate=${SAT_RATE}
contrast_rate=${CONTRAST_RATE}
contrast_pools=${CONTRAST_POOLS}
baseline_pool=${BASELINE_POOL}
pools=${POOLS}
archs=${ARCHS}
reps=${REPS}
duration_map=${DURATION_MAP}
e_rates=${E_RATES}
META
}

record_time_sync() {
    {
        echo "# 시간 동기화 구성 $(date '+%Y-%m-%dT%H:%M:%S%z')"
        chronyd -v 2>&1 | head -1
        chronyc tracking 2>&1
        chronyc sources 2>&1
        echo "hv_utils(Hyper-V 시간 동기화 드라이버): $(ls /sys/bus/vmbus/drivers/ 2>/dev/null | grep -q hv_utils && echo loaded || echo not-loaded)"
        echo "PTP: $(cat /sys/class/ptp/ptp0/clock_name 2>/dev/null)"
    } > "${OUT_DIR}/time_sync.txt"
}

# ----------------------------------------------------------------------------
preflight() {
    print_header " [사전 점검] 세션 ${SESSION_ID}"
    command -v docker >/dev/null || { echo "[에러] docker 명령 없음"; exit 1; }
    docker image inspect "$HELPER_IMAGE" >/dev/null 2>&1 || { echo "[에러] $HELPER_IMAGE 이미지가 로컬에 없음"; exit 1; }
    local c
    for c in benchmark_db benchmark_rest benchmark_graphql benchmark_grpc benchmark_influxdb; do
        docker ps --format '{{.Names}}' | grep -qx "$c" || { echo "[에러] $c 가 실행 중이 아님"; exit 1; }
    done
    docker exec benchmark_influxdb sh -c 'test "$INFLUXDB_HTTP_MAX_BODY_SIZE" = "0"' \
        || { echo "[에러] InfluxDB 에 INFLUXDB_HTTP_MAX_BODY_SIZE=0 이 적용되지 않음 (./experiments_de.sh prepare)"; exit 1; }
    curl -s -H 'Content-Type: application/json' -d "{\"query\":\"query { getOrderItems(id: \\\"${VALID_ID}\\\") { product_id } }\"}" http://localhost:8081/query | grep -q product_id \
        || { echo "[에러] GraphQL getOrderItems 없음 (새 코드로 이미지 재빌드 필요: ./experiments_de.sh prepare)"; exit 1; }
    enable_db_logging
    echo "[완료] 사전 점검"
}

# 이미지 재빌드 + InfluxDB 설정 적용 (세션마다 1회)
prepare() {
    print_header " [준비] 새 코드로 API 이미지 재빌드, InfluxDB 요청 크기 제한 해제"
    "${COMPOSE[@]}" up -d --build rest-api graphql-api grpc-api influxdb || exit 1
    sleep 5
    docker exec benchmark_influxdb influx -execute "CREATE DATABASE $INFLUX_DB_NAME" >/dev/null 2>&1
    echo "[완료] InfluxDB max-body-size=$(docker exec benchmark_influxdb sh -c 'echo $INFLUXDB_HTTP_MAX_BODY_SIZE')"
}

# ----------------------------------------------------------------------------
export_run() {
    local run_id=$1 dir=$2 metric q metrics
    if [ "$EXPORT_METRICS" == "full" ]; then metrics=("${FULL_METRICS[@]}"); else metrics=("${REDUCED_METRICS[@]}"); fi
    for metric in "${metrics[@]}"; do
        case "$metric" in
            vus|dropped_iterations|iterations|iteration_duration)
                q="SELECT \"time\", \"scenario\", \"exp\", \"arch\", \"pool\", \"rate\", \"light\", \"rep\", \"run_id\", \"value\"" ;;
            checks)
                q="SELECT \"time\", \"group\", \"check\", \"exp\", \"arch\", \"pool\", \"rate\", \"light\", \"rep\", \"run_id\", \"value\"" ;;
            *)
                q="SELECT \"time\", \"api\", \"tc\", \"status\", \"exp\", \"arch\", \"pool\", \"rate\", \"light\", \"rep\", \"run_id\", \"value\"" ;;
        esac
        run_influx_query "${q} FROM \"${metric}\" WHERE \"run_id\"='${run_id}' tz('Asia/Seoul')" | gzip -1 > "${dir}/${metric}.csv.gz"
        [ "$(zcat "${dir}/${metric}.csv.gz" | head -c1 | wc -c)" -eq 0 ] && rm -f "${dir}/${metric}.csv.gz"
    done
}

# InfluxDB 에 저장된 요청 수 / k6 요약의 요청 수
influx_completeness() {
    local dir=$1
    python3 - "$dir" <<'EOF'
import gzip, json, sys
from pathlib import Path
d = Path(sys.argv[1])
m = json.loads((d / "k6_summary.json").read_text())["metrics"]
total = (m.get("http_reqs") or m.get("grpc_req_duration") or {}).get("count", 0)
stored = 0
for name in ("http_req_duration", "grpc_req_duration"):
    p = d / f"{name}.csv.gz"
    if p.exists():
        with gzip.open(p, "rt") as f:
            stored += max(sum(1 for _ in f) - 1, 0)
print(f"{stored / total:.4f}" if total else "nan")
EOF
}

run_k6() {
    local run_id=$1 exp=$2 arch=$3 open=$4 idle=$5 rate=$6 light=$7 rep=$8 duration=$9 dir=${10}
    docker rm -f "$K6_CONTAINER" >/dev/null 2>&1
    docker run --rm --name "$K6_CONTAINER" \
      --user "$(id -u):$(id -g)" \
      --ulimit nofile=65535:65535 \
      -v "$(pwd)":/app -w /app \
      --network "$DOCKER_NETWORK" \
      -e TEST_MODE=open_loop \
      -e RATE="$rate" \
      -e DURATION="$duration" \
      -e PRE_VUS="$PRE_VUS" \
      -e GQL_TC3_LIGHT="$light" \
      -e K6_INFLUXDB_PUSH_INTERVAL="$K6_PUSH_INTERVAL" \
      "$K6_IMAGE" run \
      --out influxdb=$INFLUX_URL/$INFLUX_DB_NAME \
      --summary-trend-stats "avg,min,med,max,p(95),p(99),p(99.9),count" \
      --summary-export "${dir}/k6_summary.json" \
      --tag run_id="$run_id" \
      --tag test_type="exp_$(echo "$exp" | tr 'A-Z' 'a-z')" \
      --tag exp="$exp" \
      --tag arch="$arch" \
      --tag pool="p${open}i${idle}" \
      --tag rate="$rate" \
      --tag light="$light" \
      --tag rep="$rep" \
      --tag session_id="$SESSION_ID" \
      "$(script_for "$arch")" > "${dir}/k6_stdout.log" 2>&1
}

run_one() {
    local exp=$1 arch=$2 open=$3 idle=$4 rate=$5 light=$6 rep=$7
    local base_id=$(run_id_for "$exp" "$arch" "$open" "$idle" "$rate" "$light" "$rep")
    local duration=$(duration_for "$rate") api_container=$(container_for "$arch")

    if [ -f "$MANIFEST" ] && grep -q "^${base_id}\(_retry1\)\?," "$MANIFEST"; then
        echo "  [건너뜀] 이미 완료: $base_id"
        return 2
    fi

    local attempt run_id
    for attempt in 0 1; do
        run_id=$base_id; [ "$attempt" == "1" ] && run_id="${base_id}_retry1"
        local dir="${OUT_DIR}/${run_id}"
        mkdir -p "$dir"
        echo "------------------------------------------------------------"
        echo " 🚀 [실행] $run_id | rate=$rate duration=$duration light=$light pool=${open}:${idle}"
        echo "------------------------------------------------------------"

        read -r mem_avail swap_used cache_dropped < <(memory_guard)
        for c in benchmark_rest benchmark_graphql benchmark_grpc; do
            echo "$c $(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$c")"
        done > "${dir}/container_ips.txt"

        pg_stats_snapshot "${dir}/pg_stats_before.txt"
        local resource_pid=$(start_resource_collector "${dir}/resource" "$api_container")
        start_watchers "$dir" "$api_container"
        local started=$(date '+%Y-%m-%dT%H:%M:%S%z') started_epoch=$(date +%s)

        run_k6 "$run_id" "$exp" "$arch" "$open" "$idle" "$rate" "$light" "$rep" "$duration" "$dir"
        local k6_exit=$?
        local ended=$(date '+%Y-%m-%dT%H:%M:%S%z') ended_epoch=$(date +%s)

        stop_pid "$resource_pid"
        stop_watchers "$api_container"
        pg_stats_snapshot "${dir}/pg_stats_after.txt"
        docker logs --since "$started_epoch" --until "$((ended_epoch + 1))" benchmark_db > "${dir}/db_log.txt" 2>&1
        docker logs --timestamps --since "$started_epoch" --until "$((ended_epoch + 1))" "$api_container" 2>&1 | grep '\[pool\]' > "${dir}/pool_stats.log"

        export_run "$run_id" "$dir"
        local completeness=$(influx_completeness "$dir")
        echo "  [완료] k6 exit=${k6_exit} InfluxDB 저장률=${completeness} MemAvailable=${mem_avail}kB swap_used=${swap_used}kB"
        echo "${run_id},${exp},${arch},${open},${idle},${rate},${duration},${light},${rep},${started},${ended},${k6_exit},${completeness},${mem_avail},${swap_used},${cache_dropped}" >> "$MANIFEST"

        if awk -v c="$completeness" 'BEGIN { exit !(c >= 0.999) }'; then
            return 0
        fi
        echo "  [경고] InfluxDB 저장률 ${completeness} < 0.999"
        mv "$dir" "${dir}_incomplete"
        sed -i "s#^${run_id},#${run_id}_incomplete,#" "$MANIFEST"
        [ "$attempt" == "0" ] && { echo "  [재실행] 1회 자동 재실행"; sleep "$COOLDOWN"; }
    done
    return 0
}

run_plan() {
    local plan=$1 name=$2
    mkdir -p "$OUT_DIR"
    [ -f "$MANIFEST" ] || echo "$MANIFEST_HEADER" > "$MANIFEST"
    echo "$plan" > "${OUT_DIR}/plan_${name}.txt"
    local total=$(echo "$plan" | wc -l) cur=0 start=$(date +%s) current_pool=""
    print_header " [실험 ${name}] 총 ${total}회 | 세션 ${SESSION_ID} | 결과 → ${OUT_DIR}"
    set_swappiness
    [ -f "${OUT_DIR}/time_sync.txt" ] || record_time_sync
    record_session_meta
    clock_check "${name}_start"

    while IFS='|' read -r exp arch open idle rate light rep; do
        cur=$((cur + 1))
        local run_id=$(run_id_for "$exp" "$arch" "$open" "$idle" "$rate" "$light" "$rep")
        if [ -f "$MANIFEST" ] && grep -q "^${run_id}\(_retry1\)\?," "$MANIFEST"; then
            echo "  [건너뜀] 이미 완료: $run_id"; continue
        fi
        if [ "${open}:${idle}" != "$current_pool" ]; then
            [ -n "$current_pool" ] && clock_check "${name}_after_p${current_pool/:/i}"
            apply_pool "$open" "$idle"
            current_pool="${open}:${idle}"
        fi
        echo -e "\n========== [${cur}/${total}] ${exp} ${arch} pool=${open}:${idle} ${rate}rps light=${light} rep${rep} =========="
        run_one "$exp" "$arch" "$open" "$idle" "$rate" "$light" "$rep"
        if [ "$cur" -lt "$total" ]; then
            sleep "$COOLDOWN"
            echo "$run_id,$(wait_until_quiet)" >> "${OUT_DIR}/quiet_waits.csv"
        fi
    done <<< "$plan"

    clock_check "${name}_end"
    print_header " 🏁 완료: ${total}회, $(( ($(date +%s) - start) / 60 ))분 소요"
    python3 analysis/summarize_de.py "$OUT_DIR"
}

# ----------------------------------------------------------------------------
# 실험 E 쿼리 수 검증 (실제 DB): log_statement=all 상태에서 아키텍처별 반복 1회 실행 후 SQL 로그 줄 수를 셈
verify_queries() {
    local dir="${OUT_DIR}/verify_queries"
    mkdir -p "$dir"
    print_header " [검증] log_statement=all 로 반복 1회당 DB 쿼리 수 확인"
    "${PSQL[@]}" -q -c "ALTER SYSTEM SET log_statement = 'all'" -c "SELECT pg_reload_conf()" >/dev/null
    sleep 2
    local variant arch light since
    for variant in rest:0 grpc:0 graphql:0 graphql:1; do
        arch=${variant%%:*}; light=${variant##*:}
        sleep 2
        since=$(date +%s)
        docker run --rm --user "$(id -u):$(id -g)" -v "$(pwd)":/app -w /app --network "$DOCKER_NETWORK" \
            -e TEST_MODE=open_loop -e RATE=1 -e DURATION=1s -e PRE_VUS=1 -e GQL_TC3_LIGHT="$light" \
            "$K6_IMAGE" run --quiet --summary-export "${dir}/${arch}_light${light}_k6.json" "$(script_for "$arch")" >/dev/null 2>&1
        sleep 2   # TC6 비동기 INSERT 가 기록될 시간
        docker logs --since "$since" benchmark_db > "${dir}/${arch}_light${light}.log" 2>&1
    done
    "${PSQL[@]}" -q -c "ALTER SYSTEM RESET log_statement" -c "SELECT pg_reload_conf()" >/dev/null
    echo "log_statement=$("${PSQL[@]}" -Atc "SHOW log_statement") (복원)"
    python3 - "$dir" <<'EOF'
import re, sys
from pathlib import Path
d = Path(sys.argv[1])
import json
print(f"{'조건':16} {'반복':>4} | 반복당 {'SELECT':>6} {'INSERT':>6} {'BEGIN/COMMIT':>12} {'ping':>4} {'기타':>4}")
for f in sorted(d.glob("*.log")):
    iters = json.loads((d / f"{f.stem}_k6.json").read_text())["metrics"]["iterations"]["count"]
    sel = ins = tx = ping = other = 0
    for line in f.read_text(errors="replace").splitlines():
        m = re.search(r"LOG:  (?:statement|execute [^:]*): (.*)", line)
        if not m:
            continue
        sql = m.group(1).strip().upper()
        if sql == "-- PING":  # pgx 가 유휴 연결을 재사용할 때 보내는 연결 확인 (쿼리 아님)
            ping += 1
        elif sql.startswith("SELECT"):
            sel += 1
        elif sql.startswith("INSERT"):
            ins += 1
        elif sql in ("BEGIN", "COMMIT") or sql.startswith(("BEGIN", "COMMIT")):
            tx += 1
        else:
            other += 1
    print(f"{f.stem:16} {iters:>4} | {sel / iters:>13g} {ins / iters:>6g} {tx / iters:>12g} {ping / iters:>4g} {other / iters:>4g}")
EOF
}

# ----------------------------------------------------------------------------
case "$COMMAND" in
  plan)       build_plan | nl ;;
  gate-plan)  build_gate_plan | nl ;;
  prepare)    prepare ;;
  verify-queries) preflight; verify_queries ;;
  gate)
    preflight
    for rate in $GATE_RATES; do
        echo "$rate" > "${OUT_DIR}/gate_rate.txt"
        run_plan "$(build_gate_plan "$rate")" "gate${rate}"
        [ -n "$(cat "${OUT_DIR}/gate_eligible.txt" 2>/dev/null)" ] && break
    done
    ;;
  all)
    preflight
    mkdir -p "$OUT_DIR"
    eligible=""
    for rate in $GATE_RATES; do
        echo "$rate" > "${OUT_DIR}/gate_rate.txt"
        print_header " [기준 조건] ${rate} rps × ${REPS}회 × 아키텍처 ${ARCHS} — 붕괴 재현 여부 확인"
        run_plan "$(build_gate_plan "$rate")" "gate${rate}"
        eligible=$(cat "${OUT_DIR}/gate_eligible.txt" 2>/dev/null)
        if [ -n "$eligible" ]; then
            print_header " [기준 조건 판정] ${rate} rps 에서 붕괴 재현 → 가설 1 본 판정 대상: ${eligible} | 제외: $(for a in $ARCHS; do echo " $eligible " | grep -q " $a " || printf '%s ' "$a"; done)"
            break
        fi
        echo " [기준 조건] ${rate} rps 에서 붕괴 미관측"
    done
    if [ -z "$eligible" ]; then
        rm -f "${OUT_DIR}/gate_rate.txt"
        print_header " [판정] ${GATE_RATES} rps 모두 붕괴 미관측 → 가설 1(붕괴 원인) 검증 불가. ${SAT_RATE} rps 포화 비교만 진행"
        echo "unverifiable: ${GATE_RATES} rps 기준 조건에서 붕괴 미관측" > "${OUT_DIR}/h1_status.txt"
    else
        echo "collapse_reproduced_at=${eligible// /,}@$(cat "${OUT_DIR}/gate_rate.txt") rps" > "${OUT_DIR}/h1_status.txt"
    fi
    run_plan "$(build_plan)" all
    ;;
  summarize)  python3 analysis/summarize_de.py "$OUT_DIR" ;;
  *)
    echo "사용법: ./experiments_de.sh [명령어]"
    echo "----------------------------------------------------------------------"
    echo "  prepare         : 새 코드로 API 이미지 재빌드 + InfluxDB 요청 크기 제한 해제 (세션 전 1회)"
    echo "  verify-queries  : log_statement=all 로 반복 1회당 DB 쿼리 수 확인 (실험 E)"
    echo "  plan | gate-plan: 실행 순서만 출력"
    echo "  gate            : 기준 조건(풀 ${BASELINE_POOL}, 480 rps) 만 실행 → 붕괴 재현 여부 확인"
    echo "  all             : 실험 D+E 전체 (gate 에서 끝난 실행은 건너뜀)"
    echo "  summarize       : SESSION_ID 결과 집계"
    echo ""
    echo " 환경변수: REPS POOLS D_RATES E_RATES INCLUDE_E ARCHS DURATION_480 DURATION_DEFAULT PRE_VUS"
    echo "           COOLDOWN WARMUP_RATE WARMUP_DURATION MEM_GUARD_KB SWAPPINESS EXPORT_METRICS K6_PUSH_INTERVAL SESSION_ID"
    echo "----------------------------------------------------------------------"
    exit 1
    ;;
esac
