# 🚀 High-Traffic API Architecture Benchmark: REST vs GraphQL vs gRPC-Web

## 📌 Overview (프로젝트 개요)

이 프로젝트는 대규모 트래픽이 발생하는 마이크로서비스 환경에서 **REST, GraphQL, gRPC-Web** 세 가지 API 통신 프로토콜의 성능(지연 시간, 처리량, 서버 자원 소모량)을 교차 검증하고 벤치마킹하는 연구 목적의 저장소입니다.

극한의 동시 접속 상황에서 백엔드 아키텍처가 어떻게 동작하는지 객관적으로 비교하기 위해, 자원 효율성이 뛰어난 Go(Golang) 언어로 세 가지 API 서버를 각각 구현하고 Docker Compose를 통해 동일한 하드웨어 자원(CPU, Memory) 한계치 내에서 통제된 실험을 진행합니다.

## 🛠️ Tech Stack (기술 스택)

* **Backend Languages:** Go (Golang)
* **Database:** PostgreSQL
* **Proxy / API Gateway:** Envoy Proxy (gRPC-Web 통신용)
* **Load Testing Tool:** k6
* **Infrastructure:** Docker & Docker Compose (WSL2)

## 🗄️ Database Schema & Dataset (데이터셋)

이 벤치마킹은 단순한 더미 데이터가 아닌, 다수의 테이블이 복잡하게 얽혀 있는을 활용합니다. 약 10만 건의 실제 주문, 상품, 리뷰 데이터를 통해 데이터 페칭(Data Fetching) 시 발생하는 N+1 문제와 조인(Join) 성능을 정밀하게 테스트합니다.

![image](https://github.com/user-attachments/assets/c9733236-2566-421c-a1a5-801ca4dba53c)

## 🏗️ Project Structure (프로젝트 구조)

📦 api-benchmark

┣ 📂 data              # 원본 CSV 데이터 ([원본 데이터 링크](https://www.kaggle.com/datasets/olistbr/brazilian-ecommerce/data?select=product_category_name_translation.csv)) <br/>
┣ 📂 init-db           # PostgreSQL 초기화 및 COPY 쿼리 스크립트 (01-init.sql) <br/>
┣ 📂 rest-server       # Go 기반 REST API 서버 (예정) <br/>
┣ 📂 graphql-server    # Go 기반 GraphQL 서버 (예정) <br/>
┣ 📂 grpc-server       # Go 기반 gRPC 서버 및.proto 스키마 (예정) <br/>
┣ 📂 k6-tests          # k6 부하 테스트 자바스크립트 코드 (예정) <br/>
┣ 📜 docker-compose.yml <br/>
┗ 📜 README.md <br/>

```

## 🚀 How to Run (실행 방법)
**1. 링크에서 데이터 다운로드 후 olist_products_dataset.csv 속 두 헤더의 오타를 수정 name_length, product_description_length**
**2. 데이터베이스 초기화 및 데이터 적재**
WSL2(Ubuntu) 환경에서 아래 명령어를 실행하면 PostgreSQL이 실행되며 10만 건의 데이터가 자동으로 적재됩니다.
```bash
docker-compose up -d db

```

**2. 백엔드 서버 실행 (추후 업데이트)**

```bash
# 진행 예정

```

**3. 부하 테스트 실행 (추후 업데이트)**

```bash
# 진행 예정

```

---

## 📊 Benchmark Results (실험 결과)

*(이 섹션은 향후 k6 부하 테스트를 진행한 뒤 도출된 그래프와 데이터로 채워질 예정입니다.)*

### 1. Latency & Throughput (지연 시간 및 초당 처리량)

* **목적:** 접속자가 100명, 1,000명, 5,000명으로 증가할 때 응답 속도의 변화 측정
* **결과 그래프:**
*(여기에 꺾은선 그래프 이미지 삽입 예정)*

### 2. Server Resource Usage (서버 자원 소모량 비교)

* **목적:** 동일한 CPU 및 Memory 제한(Limit) 환경에서 각 통신 프로토콜이 서버를 얼마나 혹사시키는지 측정
* **결과 그래프:**
*(여기에 CPU/Memory 사용률 박스 플롯 또는 막대그래프 이미지 삽입 예정)*

### 3. Data Fetching Efficiency (데이터 페칭 및 네트워크 페이로드)

* **목적:** 주문 상세 대시보드(주문+상품+리뷰+판매자) 구성 시 발생하는 API 호출 횟수 및 응답 데이터 크기(Payload Size) 비교
* **결과 표:**

| Protocol | API Calls | Payload Size | Over-fetching 유무 |
| --- | --- | --- | --- |
| **REST** | - | - | - |
| **GraphQL** | - | - | - |
| **gRPC-Web** | - | - | - |

## 💡 Conclusion (연구 결론)

*(최종 테스트 완료 후, 아키텍처별 장단점 및 실무 도입 제언 작성 예정)*
