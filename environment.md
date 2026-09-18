# 실험 환경 (재현성 정보)

- 저장소: https://github.com/Asirante/api-benchmark (HEAD `90e43a1`, 2026-04-18) + 실험 A/B/C 추가분
- 표기 규칙: **확정**은 코드·잠금 파일·실측으로 확인한 값이고, **실행 시 기록**은 떠다니는(floating) 이미지 태그를 쓰고 있어 실제 값이 pull 시점에 따라 달라지는 항목입니다.
  `./experiments.sh env` 를 실행하면 `csv_results/exp_<session>/environment_runtime.txt` 에 실제 값이 기록되고, 실험 실행(`all|a|b|c`) 시작 시에도 자동으로 기록됩니다.

## 1. 호스트

| 항목 | 값 | 근거 |
|---|---|---|
| CPU | Intel Core i5-14600K (14코어: P 6 + E 8, 20스레드) | `lscpu` 모델명, 코어 구성은 Intel 사양 |
| WSL2 에 노출된 논리 CPU | 20 (lscpu 상 1소켓 × 10코어 × 2스레드) | `lscpu`. WSL2 가상화 토폴로지라 P/E 코어 구분이 보이지 않음 |
| WSL2 에 할당된 RAM | 15 GiB (+ swap 4 GiB) | `free -h` |
| 호스트 물리 RAM | **실행 시 기록** (Windows 에서 확인 필요) | `.wslconfig` 가 없으므로 WSL 기본값(물리 메모리의 50%)이 적용됨. 15 GiB 할당이면 물리 32 GB 로 추정 |
| OS / 커널 | Windows + WSL2, Ubuntu 24.04.4 LTS, `6.6.114.1-microsoft-standard-WSL2` | `/etc/os-release`, `uname -r` |
| 컨테이너 런타임 | Docker Desktop (WSL2 백엔드), Docker Engine 29.8.0, Docker VM 에 노출된 자원 NCPU=20 / 15.5 GiB | `docker version`, `docker info` (2026-09-15 파일럿) |

부하 생성기(k6)와 InfluxDB 는 SUT 와 **같은 호스트**에서 CPU 제한 없이 실행됩니다. 따라서 고부하에서는 k6·InfluxDB 의 CPU 사용이 SUT 와 경합할 수 있습니다.

### 컨테이너 자원 제한 (`docker-compose.yml`)

| 컨테이너 | 이미지 | CPU 제한 | 메모리 제한 |
|---|---|---|---|
| benchmark_db | postgres:15-alpine | 2.0 | 2048 MiB |
| benchmark_rest | 로컬 빌드 (Dockerfile.rest) | 2.0 | 2048 MiB |
| benchmark_graphql | 로컬 빌드 (Dockerfile.graphql) | 2.0 | 2048 MiB |
| benchmark_grpc | 로컬 빌드 (Dockerfile.grpc) | 2.0 | 2048 MiB |
| benchmark_envoy | envoyproxy/envoy:v1.27.0 | 2.0 | 1024 MiB |
| benchmark_influxdb | influxdb:1.8 | 없음 | 없음 |
| k6 (실행마다 생성) | grafana/k6 | 없음 | 없음 (`--ulimit nofile=65535`) |

세 API 컨테이너는 항상 함께 떠 있습니다. 한 번에 하나의 API 에만 부하를 주고, 나머지는 유휴 상태입니다.

## 2. 컴포넌트 버전

| 컴포넌트 | 버전 | 상태 | 근거 |
|---|---|---|---|
| Go (컨테이너 빌드) | **go1.24.13** | 확정 (2026-09-15 빌드) | 실행 중인 세 컨테이너의 `/root/main` 에 대한 `go version -m`. 태그 `golang:1.24-alpine` 은 패치 미고정이라 재빌드 시 달라질 수 있음 |
| Go (저장소에 커밋된 바이너리 `rest`/`graphql`/`grpc`) | go1.24.7 | 확정 | `go version -m`. 단 이 바이너리들은 커밋 `3a69b6a`(수정본, 2026-04-03)을 호스트에서 빌드한 것이며 컨테이너에서 쓰이지 않음 |
| 런타임 베이스 이미지 | alpine:3.19 | 확정(마이너) | Dockerfile.* |
| gin (REST) | v1.10.0 | 확정 | go.mod / go.sum / 바이너리 buildinfo |
| gqlgen (GraphQL) | v0.17.49 | 확정 | 〃 |
| gqlparser | v2.5.16 | 확정 | 〃 |
| grpc-go | v1.79.3 | 확정 | 〃 |
| protobuf-go | v1.36.11 | 확정 | 〃 |
| protoc / protoc-gen-go / protoc-gen-go-grpc | v3.21.12 / v1.36.11 / v1.6.1 | 확정 | `internal/adapter/grpc/pb/*.pb.go` 헤더 |
| GORM | v1.31.1 | 확정 | go.mod / buildinfo |
| DB 드라이버 | gorm.io/driver/postgres v1.6.0 → **jackc/pgx v5.6.0** (`pgx/v5/stdlib`, database/sql 경유) | 확정 | 〃 |
| k6 | **v1.7.1** (`grafana/k6@sha256:82e44a45a38e…`) | 확정 (2026-09-15 실행) | manage.sh / experiments.sh. `K6_IMAGE=grafana/k6:<버전>` 으로 고정 가능. 2026-09-15 기준 latest 는 **v2.2.0** 이라, 이미지를 새로 받으면 기존 결과를 낸 버전과 달라질 수 있음 (v2.2.0 에서도 InfluxDB v1 출력·`--summary-export`·constant-arrival-rate 동작 확인함) |
| PostgreSQL | **15.17** (`postgres@sha256:fceb6f86328c…`) | 확정 (2026-09-15 실행) | `postgres --version`. 태그 `postgres:15-alpine` 은 마이너 미고정 |
| Envoy | v1.27.0 (빌드 `7bba38b7…`, BoringSSL) | 확정 | `envoy --version` |
| InfluxDB | **1.8.10** (`influxdb@sha256:299ebda2c7e3…`) | 확정 (2026-09-15 실행) | `influxd version` |

## 3. Go DB 커넥션 풀 (`internal/adapter/database/db.go`)

| 설정 | 값 |
|---|---|
| MaxOpenConns | 500 |
| MaxIdleConns | 100 |
| ConnMaxLifetime | 1h |
| ConnMaxIdleTime | 10m |
| GORM SkipDefaultTransaction | true |
| GORM 로그 레벨 | Error |

- 풀은 **API 프로세스마다** 따로 존재합니다. 세 API 를 합치면 최대 1,500 연결, 유휴 연결은 최대 300 입니다.
- 세 API 가 같은 `database.ConnectDB()` 와 같은 `repository.OrderRepo` 를 공유합니다. 즉 DB 계층 코드가 동일합니다.
- 쓰기(TC6)는 `OrderRepo` 의 비동기 큐(버퍼 50,000, 워커 10개)에 넣은 뒤 **바로 응답**합니다. 따라서 TC6 지연은 DB 트랜잭션 시간을 포함하지 않습니다.

## 4. PostgreSQL 설정 (`docker-compose.yml`, `init-db/01-init.sql`)

- `max_connections=5000`, `shared_buffers=1GB`, `work_mem=32MB`, `synchronous_commit=off`
- 진단용 로그 설정 (`experiments.sh` 사전 점검 단계에서 `ALTER SYSTEM` 으로 적용, 재시작 불필요, pgdata 볼륨의 `postgresql.auto.conf` 에 저장):
  `log_checkpoints=on`(PG15 기본값과 같음), `log_autovacuum_min_duration=0`, `log_lock_waits=on`(대기 1초 = `deadlock_timeout` 초과 시), `log_min_duration_statement=1000`
- 세 API 의 풀이 유지하는 유휴 연결: 부하가 없을 때 client backend 201개 (`pg_stat_activity`)
- 인덱스: orders(customer_id), order_items(order_id, product_id, seller_id), payments(order_id), reviews(order_id), geolocation(zip)
- 데이터: Kaggle Olist Brazilian E-Commerce. 적재 행 수는 orders 99,441, order_items 112,650, customers 99,441, products 32,951, sellers 3,095, payments 103,886, reviews 99,224, geolocation 1,000,163 (CSV 파서로 센 행 수, 헤더 제외. 실제 적재 수는 `experiments.sh env` 에 orders 행 수로 기록)
- TC6 가 실행마다 주문을 계속 삽입하므로, 실행이 누적될수록 `olist_orders_dataset` 행 수가 늘어납니다 (파일럿·probe 16회 후 99,441 → 355,307행). 조회는 PK 로만 하지만, autovacuum·체크포인트가 노이즈 요인이 될 수 있어 실행마다 `pg_stats_before/after.txt` 로 기록합니다.

## 5. 서버 구성

| API | 구성 |
|---|---|
| REST | gin `ReleaseMode`, `gin.Recovery()` 만 사용 (요청 로그 없음), `encoding/json` 기반 `ctx.JSON` |
| GraphQL | gqlgen `handler.NewDefaultServer` (기본 트랜스포트·쿼리 캐시·APQ·introspection 포함), `net/http` |
| gRPC | `grpc.NewServer()` 기본 옵션 + reflection, 평문(h2c) |
| Envoy (TC9 전용) | gRPC-Web + CORS 필터, upstream http2, `connect_timeout` 0.25s |

## 6. 부하 생성 설정

| 항목 | 값 |
|---|---|
| 표준 단계 (폐쇄 루프) | 10s → VUs/2, 10s → VUs, 30s 유지, 10s → 0 |
| 반복 끝 대기 | `sleep(1)` (기본), 실험 B: `JITTER=1` 이면 `sleep(Math.random()*2)` |
| 개방 루프 (실험 C) | `constant-arrival-rate`, `timeUnit=1s`, `duration=60s`, `preAllocatedVUs=maxVUs=1000`, 반복 끝 대기 없음 |
| 요청 대상 | 모든 조회가 고정 주문 1건 (`e481f51cbdc54678b7cc49136f2d6af7`, 아이템 1개) |
| 연결 | REST/GraphQL 은 VU 별 HTTP keep-alive, gRPC 는 VU 별 연결 1개 (첫 반복에서 connect) |
| 결과 저장 | k6 `--out influxdb` (v1) → `influx -format csv` 로 추출 |
| 자원 로그 | `docker stats --no-stream`, 2초 간격 (명령 자체 소요 시간 때문에 실제 간격은 약 4초). 실행마다 `_api` / `_db` / `_k6` / `_other` 파일로 분리. k6 컨테이너는 `benchmark_k6` 이름으로 실행 |
| 실행 간 격리 | 고정 쿨다운 20초 후, DB·API 컨테이너 CPU 가 모두 5% 미만이 될 때까지 최대 180초 추가 대기 (`quiet_waits.csv` 에 기록) |
| 멈춤 진단 | 실행마다 `pg_activity.csv`(2초 간격 세션 상태·대기 이벤트), `host_vmstat.log`(1초 간격 WSL VM CPU·steal·iowait·swap), `db_log.txt`, `pg_stats_before/after.txt` 저장 |

## 7. 재현 시 알아야 할 코드 동작

측정값 해석에 직접 영향을 주는 사실들입니다. 모두 실험 A 작업 중 GORM 이 생성한 SQL 을 로깅해 확인했습니다.

1. **GraphQL·gRPC 의 TC4/TC5 는 필드 선택과 무관하게 REST 와 같은 DB 작업을 합니다.**
   세 API 모두 `GetOrderWithFullDetails` 를 호출하며, 이 함수는 7개 테이블(orders, customers, order_items, products, sellers, payments, reviews)을 7회의 `SELECT *` 로 조회합니다.
   GraphQL 은 조회 결과 전체를 메모리에 올린 뒤, 리졸버에서 필요한 필드만 옮겨 담아 직렬화합니다.
2. **Customer 연관이 잘못 매핑돼 있어 `customer_city`/`customer_state` 가 항상 빈 문자열입니다.**
   `Order.Customer` 에는 `foreignKey:CustomerID` 만 지정돼 있습니다. 그래서 GORM 이 이를 has-one 관계로 해석하고, `WHERE customer_id = <주문 ID>` 로 조회합니다(항상 0행). 기준 주문의 실제 고객은 `9ef432eb…`(sao paulo, SP)입니다.
   이 쿼리 자체는 매 요청 실행되므로 DB 왕복 횟수에는 포함됩니다. 세 API 에 동일하게 적용됩니다.
3. REST 의 TC4 와 TC5 는 같은 엔드포인트(`/orders/details/:id`)를 호출하고, gRPC 의 TC4 와 TC5 도 같은 RPC 를 호출합니다.
4. `product_name` 필드의 실제 값은 `product_category_name` 입니다(REST slim, GraphQL, gRPC 모두 동일).
5. gRPC `GetItemsByOrderID`(TC3 part2)는 Product 를 Preload 하지 않아 `product_name` 이 빈 값입니다.

## 8. 실험 A/B/C 조건 정의

| 실험 | 조건 | 구현 |
|---|---|---|
| A | `tc5` vs `tc5_slim` (REST) | `GET /api/v1/orders/slim/:id`. 조회: orders(3컬럼) + customers(3) + order_items(4) + products(2), 총 4회. 응답 JSON 은 GraphQL TC5 응답과 필드·순서·값이 동일함을 확인. `TC5_SLIM=1` 일 때만 반복에 포함되며, 이때 REST 반복당 요청 수는 8 → 9 |
| B | `jitter0` vs `jitter1` | `JITTER=1` → `sleep(Math.random()*2)` (평균 1초 동일) |
| C | 도착률 140/290/385/480/640/800/1000/1200 반복/s | `TEST_MODE=open_loop RATE=<n>`. rate 는 **반복(iteration) 시작 수**이며, 반복 1회에 TC1~7 요청이 순차 실행됨. 290/385/480 은 300/400/500 VUs 폐쇄 루프에서 실측된 유지 구간 처리량과 같은 값이고, 640 이상은 포화 지점 탐색용 |

- 공통: 조건마다 3회 반복(`REPS`), VUs 300/400/500(`VUS_LEVELS`). 반복(rep) 단위로 조건 순서를 무작위화하며, 시드는 세션 ID 로 고정됩니다.
- run_id 형식: `exp<A|B|C>_<arch>_<cond>_<level><vus|rps>_rep<n>_<session>`

## 9. 본 실행(`exp_20260915_030551`, 135회)에서 확인된 측정 환경 제약

1. **InfluxDB 요청 크기 제한으로 일부 원시 데이터 누락**
   - k6 → InfluxDB 1.8 쓰기 배치가 기본 `max-body-size`(25 MB)를 넘으면 `Request Entity Too Large` 로 거부됩니다.
   - 개방 루프 640 rps 이상에서 REST 12회(저장률 0.2~77%), GraphQL 4회(94~97%)가 해당합니다. REST 는 요청당 HTTP 지표 8종을 보내 배치가 가장 큽니다.
   - k6 요약(JSON)은 영향을 받지 않으므로, 실험 C 의 처리량·dropped·전체 TC 백분위수는 k6 요약을 사용했습니다. 해당 실행의 TC 별 지연은 신뢰할 수 없습니다.
   - 재실행 시 대책: `K6_INFLUXDB_PUSH_INTERVAL` 을 줄이거나 InfluxDB `INFLUXDB_HTTP_MAX_BODY_SIZE=0` 설정.
2. **세션 후반 호스트 메모리 압박**
   - WSL VM(15.5 GiB)의 free 메모리가 세션 시작 10 GB → 후반 약 110 MB 로 줄었고(대부분 페이지 캐시), 고부하 개방 루프 실행 중 swap-out 이 초당 수만 KB 까지 발생했습니다(swap 사용 최대 681 MB).
   - 반복(rep) 순서상 rep3 이 세션 후반에 몰려 있으므로, rep3 에만 나타난 현상은 이 요인과 분리해서 해석해야 합니다.
3. **워크로드의 DB 쿼리 수가 아키텍처마다 다름**
   - 반복 1회의 동기 DB 쿼리 수: REST 19, gRPC 19, **GraphQL 24**. GraphQL TC3 는 `getOrderDetails`(7회)를 호출하는 반면 REST/gRPC TC3 는 가벼운 조회 2회입니다.
   - 같은 도착률에서 GraphQL 의 DB 부하가 더 큰 것은 프로토콜이 아니라 이 시나리오 설계에서 비롯된 부분이 있습니다.

## 10. 후속 실험 D/E (브랜치 `exp/de-pool-tc3`, A/B/C 코드는 태그 `exp-abc-20260915_030551`)

- 위 7절의 (a) Order.Customer 연관 매핑 오류와 3.절의 (b) TC6 비동기 쓰기 큐는 직전 135회 결과와의 비교 가능성을 위해 **수정하지 않음**
- 풀 설정: `DB_MAX_OPEN_CONNS`(기본 500), `DB_MAX_IDLE_CONNS`(기본 100). database/sql 이 idle 을 open 이하로 자동 조정하므로 실제 조건은 20:20, 50:50, 100:100, 500:100(기존), 500:500
- 풀 통계: `DB_POOL_STATS_INTERVAL=1s` 로 `sql.DBStats`(open, in_use, wait_count, wait_duration, max_idle_closed) 기록
- 설정 전달: `docker-compose.exp.yml` override (기존 compose 파일 미수정). InfluxDB 는 `INFLUXDB_HTTP_MAX_BODY_SIZE=0`, k6 는 `K6_INFLUXDB_PUSH_INTERVAL=250ms`
- 실험 E: GraphQL 스키마에 `getOrderItems` 루트 필드 추가(gqlgen v0.17.49 재생성, generated.go 는 추가분만). `GQL_TC3_LIGHT=1` 이면 TC3 를 요청 1회·루트 필드 2개(`getSimpleOrder` + `getOrderItems`)로 보냄
- 반복 1회당 동기 SELECT 수 검증 (2026-09-15):

  | 조건 | 코드 수준 (SQLite + GORM 로거) | 실제 DB (`log_statement=all`, 반복당) |
  |---|---|---|
  | REST | 19 | 19 |
  | gRPC | 19 | 19 |
  | GraphQL 기존 | 24 | 24 |
  | GraphQL light | 19 | 19 |

  네 조건 모두 TC6 비동기 INSERT 1회(+BEGIN/COMMIT)는 별도. pgx 의 `-- ping` 은 유휴 연결 재사용 시 연결 확인이며 쿼리가 아님
- 1초 간격 수집: `pg_activity.csv`(client_addr × 상태 × 대기 이벤트), `pg_db_stats.csv`(누적 연결 생성 수), `cgroup_db.csv`/`cgroup_api.csv`(cpu.stat: 사용량·CFS 스로틀링), `pool_stats.log`
- 메모리 대책: 세션 중 `vm.swappiness=10`(종료 시 원래 값 60 복원), 실행 전 MemAvailable < 4 GB 이면 페이지 캐시 비우고 워밍업, 원시 지표는 분석용 6종만 gzip 저장
- **VM 시계 이상 (2026-09-15 13:40 확인)**: 외부 기준 133초 동안 VM 단조 시계는 120.2초만 경과(약 10% 느림). 실시간 시계는 약 30초마다 3.3초씩 앞으로 보정됨. 직전 세션(03:30 기준) vmstat 은 62초에 62샘플로 정상이었으므로 그 이후 발생. k6 지연·도착률·실행 시간, cgroup CPU 주기가 모두 단조 시계를 따르므로 이 상태의 측정은 직전 세션과 비교할 수 없음

### 10-1. 시간 동기화 구성과 본 실험 중 시계 검사 (2026-09-15 18시 확인)

- `wsl --shutdown` 과 Docker Desktop 재시작 이후 chrony(4.5)가 설치되어 동작 중임
  - 서비스 시작 스크립트(`chronyd-starter.sh`)가 WSL 을 컨테이너 환경으로 판단해 `-x`(시스템 시계 제어 안 함)를 붙임 → chrony 는 **측정만 하고 시계를 맞추지 않음**
  - VM 시계는 기존대로 Hyper-V 시간 동기화(hv_utils)가 호스트 시각에 맞춤
  - chrony 의 선택 기준이 PHC0(`/dev/ptp_hyperv`, Hyper-V 호스트 시계)와 인터넷 NTP 사이를 몇 초마다 오감
- 측정값: 인터넷 NTP 대비 VM 시계 속도 오차 **−46 ppm(0.005%)**, 절대 오프셋 약 1.43초(호스트 Windows 시계 자체의 오차로, 경과 시간 측정에는 영향 없음). 13:40 에 확인된 약 10% 지연은 해소된 상태
- 본 실험 중 시계 검사(`experiments_de.sh`): 세션 시작, **풀 블록 전환 시점**(API 재기동 직전), 세션 종료에 대기 없이 기록
  - 드리프트 = 직전 검사 이후 (실시간 시계 경과 − 단조 시계 경과) / 단조 시계 경과
  - 검사 구간이 120초 이상이고 |드리프트| > 3% 이면 즉시 중단(exit 3). 직전 블록의 데이터는 사용하지 않음
  - chrony 값(NTP 대비 속도 오차 ppm·오프셋, PHC0 대비 오프셋)을 함께 기록 (해석용, 중단 판정에는 쓰지 않음)
  - 결과: `clock_checks.csv`, 실행 로그. 집계 시 실행마다 속한 검사 구간의 `clock_drift_pct` / `clock_ok` 를 붙이고, `clock_ok=0` 실행은 조건 집계에서 제외

### 10-2. 기준 조건 판정 (아키텍처별)

- `./experiments_de.sh all` 은 기준 조건(풀 500:100, 480 rps, 180초) × 아키텍처 × 3회를 먼저 실행한 뒤 아키텍처별로 판정
- 기준 조건에서 붕괴가 한 번도 관측되지 않은 아키텍처는 실험 D 인과 판정 대상에서 제외(`gate.txt`, `gate_eligible.txt`, 집계 열 `d_causal_target`). 실행 조건은 동일하게 유지하며 보고서에는 참고용으로 표시
- 판정 대상 아키텍처가 하나도 없으면 본 실험을 진행하지 않고 중단(exit 4)

### 10-3. 수집기 기록 방식

- `pg_activity.csv`, `pg_db_stats.csv` 는 `grep --line-buffered` 로 한 줄씩 즉시 기록 (실행기가 중간에 종료돼도 그때까지의 데이터 보존). 측정 조건 변경 없음

### 10-4. 직전 세션(`exp_20260915_030551`) 붕괴와 호스트 메모리 압박의 연관

세션 후반으로 갈수록 WSL VM 의 free 메모리가 줄고(10 GB → 약 110 MB, 대부분 페이지 캐시) swap-out 이 발생했습니다.
개방 루프 실행 중 **InfluxDB 저장률이 온전한 실행만** 집계하면 다음과 같습니다.

| 조건 | 붕괴(초당 완료 수가 중앙값의 절반 미만인 구간 5초 이상) |
|---|---|
| 포화 전(≤480 rps), swap-out < 1000 KB/s | **0회 / 31회** |
| 포화 전(≤480 rps), swap-out ≥ 1000 KB/s | **3회 / 5회** |
| ≤640 rps, swap-out < 1000 KB/s | 1회 / 33회 |
| ≤640 rps, swap-out ≥ 1000 KB/s | 5회 / 7회 |

- 포화 전 붕괴 3건은 모두 세션 후반(06시대)이며 swap-out 이 각각 38,780 / 41,928 / 90,036 KB/s 였습니다.
- swap 없이 붕괴한 유일한 실행은 `expC_grpc_open_640rps_rep1`(03:47, swap-out 28 KB/s)로, **포화 지점(640 rps) 근처**였습니다. 이때는 ProcArray 대기 374, 활성 세션 395 로 DB 동시성 경합이 함께 관측됩니다.
- 2026-09-16 02:41 세션에서 480 rps · 풀 500:100 · 180초 · 아키텍처별 3회(총 9회)를 메모리 여유 13 GB 상태로 재실행한 결과 **붕괴 0회**, DB CPU 60~72%, 스로틀링 0%, 최대 활성 VU 3~13, 새 DB 연결 0~24개였습니다.
- 따라서 포화 전 구간의 간헐적 붕괴는 "큰 커넥션 풀" 단독이 아니라 **호스트 메모리 압박이 동반될 때** 관측되었다고 보는 것이 데이터에 부합합니다. 이 세션들의 swap 은 실험 산출물(CSV 21 GB) 기록으로 쌓인 페이지 캐시와 관련이 있어, 이후 세션에서는 내보내기 축소·swappiness 조정·캐시 비우기 가드를 적용했습니다.

### 10-5. 실험 D 재설계 (2026-09-16)

- **기준 조건(붕괴 재현 확인)**: 풀 500:100, 180초, 아키텍처별 3회. rate 를 640 → (미관측 시) 700 순으로 한 단계만 상향. 700 에서도 미관측이면 가설 1(붕괴 원인)은 **검증 불가**로 확정하고 더 올리지 않음
- **붕괴와 포화 구분**: 달성 처리량 비율(달성/목표)과 DB CPU 상한 도달 시간을 함께 기록.
  - `saturated`: DB CPU 가 제한의 95% 이상인 시간이 실행의 50% 이상이거나, 달성률 95% 미만이면서 초당 처리량 변동계수 < 0.25
  - `collapse`: 붕괴 구간(초당 완료 < 목표의 50% 가 5초 이상, 활성 VU ≥ 600) 1개 이상, 또는 dropped ≥ 1% 이면서 포화 상태가 아닐 때
- **가설 1 대체 판정(포화 구간 비교, 800 rps)**: 풀 크기별 달성 처리량·p99·DB 스로틀링 비율·새 DB 연결 생성 수·ProcArray 대기 세션 수를 연속값으로 비교. 판정 규칙은 실행 전에 고정:
  - **확인**: 작은 풀(20/50/100) 중 최선값이 500:100 대비 처리량 +10% 이상 & 3회 [최소,최대] 범위 비중첩 & p99 중앙값이 더 낮음
  - **차이 없음**: |차이| < 5% 이거나 범위 중첩
  - **불확실**: 그 외
  - **연결 반복 생성 vs 동시 세션 상한**: 500:500(유휴=최대라 재생성 없음)을 500:100 과 같은 규칙으로 비교. 500:500 이 개선되면 반복 생성이, 개선되지 않으면 상한이 주 원인
- **480 rps 대조**: 풀 20:20 을 아키텍처별 3회 추가. 풀 500:100 은 세션 `de_20260916_0241` 의 9회를 사용(같은 날, 같은 코드·시계 상태. 세션이 다르다는 점은 해석 시 명시)

### 10-6. 세션 `de_20260916_1154` 결과 요약과 후속 실험 설계 (2026-09-17)

**결과 요약** (108회, InfluxDB 저장률 1.000, 시계 검사 18회 드리프트 ≤ 0.01%)
- 640 rps: 풀 20·50·100 은 27회 모두 안정. 500:100 은 9회 중 5회, 500:500 도 아키텍처별로 붕괴·저하 → 붕괴는 큰 풀(동시 세션 상한)에서 발생
- 800 rps: 풀 ≤ 100 에서 세 아키텍처 모두 800 iter/s 달성, 500:100 은 546~592 → 직전 세션의 "약 650회/s 한계" 는 풀 설정의 산물
- 800 rps · 작은 풀에서는 **API 컨테이너 CPU 가 제한(2코어)에 도달** (API CPU 196~200%, API 스로틀링 97~99.7%). GraphQL 은 풀 20·100 에서 DB 스로틀링은 낮은데(1~15%) 풀 대기가 900~1,100 ms/반복으로 커지는 **API 측 대기**형이었음
- 풀 크기별 표: `csv_results/exp_de_20260916_1154/pool_size_table.md` (`analysis/followup_tables.py pool-size`)
- **480 rps 대조의 풀 500:100 데이터는 세션 `de_20260916_0241`(2026-09-16 02:41 시작) 것**이고, 풀 20:20 은 세션 `de_20260916_1154` 것입니다. 같은 코드·이미지·시계 상태이지만 세션이 다르므로 표에 출처를 함께 표기합니다

**병목 유형 판정 규칙** (조건별 3회 중앙값, 실행 전 고정)
- DB 스로틀링 ≥ 50% → DB 경합 / 중앙값은 미만이지만 최대값 ≥ 50% → 간헐적 DB 경합
- API 스로틀링 ≥ 90% & DB 스로틀링 < 30% & 풀 대기 ≥ 10 ms/반복 & p99 ≥ 100 ms → API 측 대기
- 달성률 ≥ 99% & p99 < 100 ms → 정상, 그 외 혼합

**후속 1: 실험 E 재실행** (`experiments_de.sh sweep`, 풀 50:50, rate 640/800, 3회)
- GraphQL light(19쿼리) vs 기존(24쿼리), 같은 세션에 REST·gRPC 800 rps 참조 포함(권장)
- 가설 2 판정(고정): light 의 p99 중앙값이 기존 대비 30% 이상 감소 & 3회 범위 비중첩 → 쿼리 수가 p99 차이의 원인으로 지지 / |변화| < 10% 또는 범위 중첩 → 차이 없음 / 그 외 불확실
- 격차 해소율 = (기존 p99 − light p99) / (기존 p99 − REST·gRPC 중 높은 p99). light 에서도 API 스로틀링 ≥ 90% 이고 p99 가 REST·gRPC 의 1.5배를 넘으면 남은 차이는 GraphQL 서버 처리 비용으로 해석
- 처리량·p99·DB 스로틀링·API 스로틀링·API CPU 를 함께 보고 (`followup_tables.py e2`)

**후속 2: 적정 풀 처리 한계** (`experiments_de.sh sweep`, 풀 20:20·50:50, rate 900/1000/1100/1200, 아키텍처별 3회, 60초)
- 목표 미달: 달성률 중앙값 < 95%. CPU 상한 도달: CPU 가 제한의 95% 이상인 시간이 실행의 50% 이상 (DB·API 각각 기록)
- 세 아키텍처가 모두 목표 미달인 최저 rate 와, 그때 DB/API CPU 상한 도달 여부를 보고. 1200 rps 까지 미달이 없으면 더 올리지 않고 그 사실을 보고 (`followup_tables.py capacity`)
- 시계 검사(풀 블록 전환마다, 드리프트 3% 초과 시 중단)와 InfluxDB 저장률 자동 재실행은 동일

### 10-7. 실험 E 재실행 결과 (세션 `de_e2_20260917_1243`, 풀 50:50, 18회)

- 데이터 품질: k6 비정상 종료 0, InfluxDB 저장률 1.000, 시계 검사 2회 모두 드리프트 0.01% 이하
- GraphQL 반복당 쿼리를 24회 → 19회(REST·gRPC 와 동일)로 맞춘 결과, 사전 고정 규칙(p99 30% 이상 감소 & 3회 범위 비중첩)을 두 부하에서 충족

  | 부하 | 조건 | 달성 iter/s | p99 (ms, 3회 평균 [최소–최대]) | DB CPU | DB 스로틀링 |
  |---|---|---|---|---|---|
  | 640 rps | GraphQL 24쿼리 | 640 | 4.6 [3.9–6.0] | 104% | 0.2% |
  | 640 rps | GraphQL 19쿼리 | 640 | **2.6 [2.4–2.6]** (−45%) | 88% | 0.0% |
  | 800 rps | GraphQL 24쿼리 | 800 | 79.8 [68.1–96.9] | 147% | 0.8% |
  | 800 rps | GraphQL 19쿼리 | 800 | **44.3 [42.5–47.5]** (−45%) | 123% | 0.1% |
  | 800 rps | REST (참조, 같은 세션) | 800 | 36.6 | 130% | 0.7% |
  | 800 rps | gRPC (참조, 같은 세션) | 800 | 79.1 | 133% | 0.8% |

- 처리량은 네 조건 모두 목표를 100% 달성해 차이가 없었습니다. 쿼리 수 차이는 **처리량이 아니라 지연으로** 나타났습니다
- 800 rps 의 p99 는 세션 간 변동이 큽니다(같은 GraphQL 24쿼리 조건이 `de_20260916_1154` 에서 170 ms, 이 세션에서 79.8 ms). 가설 2 판정은 같은 세션 안의 비교로만 수행했습니다

### 10-8. 적정 풀에서의 처리 한계 (세션 `de_cap_20260918_0345`, 72회)

- 데이터 품질: k6 비정상 종료 0, InfluxDB 저장률 1.000, 시계 검사 7회 모두 드리프트 0.01% 이하
- 최대 달성 처리량(풀 50:50): **REST 1,015 iter/s, gRPC 983 iter/s, GraphQL 821 iter/s**. 세 아키텍처 모두 **1100 rps 에서 처음 목표 미달**(달성률 95% 미만)이며, 그 위로 rate 를 올려도 달성 처리량은 평평합니다
- **병목 자원은 API 컨테이너 CPU 입니다.** 900~1200 rps 의 모든 조건에서 API CPU 가 197~201%(제한 200%)이고, **CPU 상한 도달 시간이 실행의 92~98%** 였습니다. 같은 구간에서 **DB CPU 는 131~153% 로 상한 도달 시간이 0%** 이고 DB 스로틀링도 0.5% 이하였습니다. 즉 이 환경의 처리 한계는 DB 가 아니라 API 컨테이너에 할당된 2코어에서 결정됩니다
- 풀 50:50 이 20:20 보다 낫습니다. REST 는 1000 rps 까지 100% 달성(p99 311 ms)하지만 풀 20:20 에서는 같은 rate 에서 96.7%·p99 609 ms 입니다. 풀이 너무 작으면 API 가 CPU 에 묶인 동안 커넥션을 오래 점유해 풀 대기가 커집니다
- **정정 기록: 직전 세션에서 "처리 한계 약 650회/s" 로 해석한 값은 풀 설정(500:100)의 산물이었습니다.** 같은 코드·같은 호스트에서 풀을 20~100 으로 줄이면 800 rps 를 100% 달성하고, 실제 한계는 약 1,000회/s(GraphQL 약 820회/s)입니다. 따라서 세션 `exp_20260915_030551` 에서 관측된 아키텍처별 처리량 순위도 풀 설정에 의해 왜곡된 값으로 보아야 합니다

### 10-9. 쿼리 수 보정 조건의 처리 한계 재측정 설계 (실행 전 고정, 2026-09-18)

- 목적: 10-8 의 처리 한계(REST 1,015 / gRPC 983 / GraphQL 821 iter/s)는 GraphQL 이 반복당 24쿼리인 조건의 값이다. 세 아키텍처를 모두 19쿼리로 맞춘 뒤에도 아키텍처 간 차이가 남는지 확인한다
- 조건: 풀 50:50 고정, rate 800 / 900 / 1000 / 1100, 각 3회, 60초. 한 세션 안에서 네 조건을 모두 측정
  - GraphQL light (`GQL_TC3_LIGHT=1`, 19쿼리) / GraphQL 기존 (24쿼리) / REST (19쿼리) / gRPC (19쿼리)
  - 직전 세션 값을 비교에 쓰지 않는다. 800 rps p99 는 세션 간 변동이 크기 때문이다(10-7 참조)
- 수집: 달성 처리량·목표 달성률·p50/p95/p99, API CPU 와 상한 도달 시간, DB CPU 와 스로틀링, 조건별 병목 유형
- 판정 규칙 (`analysis/followup_tables.py` 의 `H2_CAP_DIFF`, 커밋으로 고정):
  - **유의한 차이**: 최대 달성 처리량(조건별로 rate 를 올려도 평평해지는 값) 차이가 **5% 이상**이고 3회 [최소–최대] 범위가 **겹치지 않음**
  - **차이 없음**: 차이 5% 미만 이거나 범위 중첩 / **불확실**: 그 외
  - 비교 기준은 REST·gRPC 중 **낮은 쪽**. 보정 전후(24 → 19쿼리)도 같은 규칙으로 판정
  - 병목 유형·목표 미달(달성률 95% 미만) 기준은 10-5·10-6 과 동일
- 중단: 1100 rps 에서 네 조건 모두 목표 미달이면 더 올리지 않는다. 문제가 생기면 조건을 바꾸지 않고 보고한다
- 시계 검사(풀 블록 전환·세션 시작/종료, 드리프트 3% 초과 시 중단)와 InfluxDB 저장률 자동 재실행은 동일

## 11. 논문 한계 절에 인용할 코드 동작 (측정 해석에 영향을 주는 사실)

모두 GORM 이 생성한 SQL 로깅(코드 수준)과 실제 DB `log_statement=all`(반복 1회 실행) 두 방법으로 확인했습니다. 직전 결과와의 비교 가능성을 위해 **수정하지 않은 채로 측정**했습니다.

1. **반복 1회당 동기 DB 쿼리 수: REST 19회, gRPC 19회, GraphQL 24회.** 차이는 TC3 에서 나옵니다. REST·gRPC 는 단순 조회 1회 + 아이템 조회 1회(2회)를 호출하지만, GraphQL 은 `getOrderDetails`(7회)를 호출합니다. 실험 E 의 `GQL_TC3_LIGHT=1` 조건은 이 차이만 제거해 19회로 맞춘 것입니다(요청 횟수는 1회로 유지).
2. **TC4/TC5 의 DB 작업은 세 아키텍처가 동일합니다.** 모두 `GetOrderWithFullDetails` 를 호출하며, 이 함수는 7개 테이블(orders, customers, order_items, products, sellers, payments, reviews)을 **7회의 `SELECT *`** 로 조회합니다. GraphQL 의 필드 선택은 조회 이후 직렬화 단계에서만 작동하므로, "GraphQL 이 필요한 필드만 조회한다" 는 해석은 이 구현에 적용되지 않습니다.
3. **`Order.Customer` 연관 매핑 오류.** `foreignKey:CustomerID` 만 지정돼 있어 GORM 이 has-one 으로 해석하고 `WHERE customer_id = <주문 ID>` 로 조회합니다(항상 0행). 그 결과 TC4/TC5 응답의 `customer_city`·`customer_state` 는 **세 아키텍처 모두 항상 빈 문자열**입니다(기준 주문의 실제 고객은 `9ef432eb…`, sao paulo/SP). 쿼리 자체는 매 요청 실행되므로 DB 왕복 횟수에는 포함되며, 응답 크기는 의도보다 작습니다.
4. **TC6 은 DB 쓰기 지연을 측정하지 않습니다.** `OrderRepo.CreateOrderTransaction` 은 버퍼 50,000·워커 10개의 비동기 큐에 넣고 즉시 응답합니다. 실제 INSERT 는 백그라운드에서 수행되므로 TC6 의 응답 지연에는 트랜잭션 시간이 포함되지 않고, 큐가 가득 찰 때만 오류를 반환합니다.
5. REST 의 TC4 와 TC5 는 같은 엔드포인트(`/orders/details/:id`)를, gRPC 의 TC4 와 TC5 는 같은 RPC 를 호출합니다. 즉 두 TC 는 서버 입장에서 동일한 작업입니다.
6. `product_name` 의 실제 값은 `product_category_name` 컬럼이며, gRPC `GetItemsByOrderID`(TC3 part2)는 Product 를 Preload 하지 않아 이 값이 빈 문자열입니다.
7. 모든 조회가 **고정된 주문 1건**(`e481f51cbdc54678b7cc49136f2d6af7`, 아이템 1개)을 대상으로 하므로, DB 캐시 적중률이 실제 워크로드보다 높고 데이터 분포 효과는 측정되지 않습니다.
