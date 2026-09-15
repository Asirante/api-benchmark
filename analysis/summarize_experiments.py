#!/usr/bin/env python3
"""실험 A/B/C 결과 집계 (표준 라이브러리만 사용).

입력: experiments.sh 가 만든 csv_results/exp_<session>/<run_id>/*.csv
출력 (같은 세션 폴더에 생성):
  summary_runs.csv        실행 1회 × (tc, api) 별 mean/p50/p95/p99/max, 실패율, 처리량
  summary_conditions.csv  조건별 (exp, arch, cond, level, window, tc, api) 반복 간 평균·최소·최대·범위
  summary_open_loop.csv   실험 C: 목표/완료/dropped 반복 수, 달성 처리량, 최대 활성 VU
  summary_resources.csv   실행 1회 × 역할(api/db) 별 CPU·메모리 평균/최대
  summary_checks.csv      실행 1회 × check 이름 별 통과율
  summary_diagnostics.csv 실행 1회 별 멈춤(stall) 진단: 초당 완료 요청 수의 최저/중앙값 비율,
                          DB 활성·락/IO 대기 세션 최대치, DB 로그 이벤트 수, 호스트 vmstat 최대치

window
  all    : 요청이 발생한 전 구간
  steady : 폐쇄 루프(A, B)는 VU 가 목표치에 도달해 유지된 구간 (standard 단계의 30초 유지 구간)
           개방 루프(C)는 all 과 동일

백분위수는 선형 보간(numpy 기본값과 동일)으로 계산합니다.
"""

import csv
import json
import math
import re
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

DURATION_METRICS = ("http_req_duration", "grpc_req_duration")
_TIME_RE = re.compile(r"^(.*T\d\d:\d\d:\d\d)(?:\.(\d+))?(Z|[+-]\d\d:\d\d)?$")


def parse_time(s):
    m = _TIME_RE.match(s)
    if not m:
        raise ValueError(f"시간 형식 인식 불가: {s}")
    base, frac, tz = m.groups()
    frac = (frac or "0")[:6].ljust(6, "0")
    tz = "+00:00" if tz in (None, "Z") else tz
    return datetime.fromisoformat(f"{base}.{frac}{tz}")


def read_influx_csv(path):
    if not path.exists():
        return []
    with path.open(newline="") as f:
        rows = list(csv.DictReader(f))
    for r in rows:
        r["_t"] = parse_time(r["time"])
        r["_v"] = float(r["value"]) if r.get("value") not in (None, "") else math.nan
    return rows


def percentile(sorted_vals, p):
    if not sorted_vals:
        return math.nan
    k = (len(sorted_vals) - 1) * p / 100.0
    lo, hi = math.floor(k), math.ceil(k)
    if lo == hi:
        return sorted_vals[lo]
    return sorted_vals[lo] + (sorted_vals[hi] - sorted_vals[lo]) * (k - lo)


def fmt(x, nd=3):
    if x is None or (isinstance(x, float) and math.isnan(x)):
        return ""
    return f"{x:.{nd}f}" if isinstance(x, float) else str(x)


def load_manifest(session_dir):
    path = session_dir / "manifest.csv"
    if not path.exists():
        sys.exit(f"[에러] manifest.csv 가 없습니다: {path}")
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


def steady_window(run, run_dir):
    """폐쇄 루프: vus 가 목표치 이상인 첫·마지막 시점. 개방 루프는 None (전 구간)."""
    if run["exp"] == "C":
        return None
    target = int(run["level"])
    vus = [r for r in read_influx_csv(run_dir / "vus.csv") if r["_v"] >= target]
    if not vus:
        return None
    return min(r["_t"] for r in vus), max(r["_t"] for r in vus)


def is_failure(row, metric):
    status = row.get("status", "")
    if metric == "grpc_req_duration":
        return status != "0"
    return not status.startswith("2")


def summarize_run(run, run_dir):
    rows = []
    for metric in DURATION_METRICS:
        rows.extend((metric, r) for r in read_influx_csv(run_dir / f"{metric}.csv"))
    if not rows:
        return []

    window = steady_window(run, run_dir)
    windows = {"all": None}
    if run["exp"] != "C":
        windows["steady"] = window

    out = []
    for wname, bounds in windows.items():
        if wname == "steady" and bounds is None:
            continue
        groups = defaultdict(list)
        for metric, r in rows:
            if bounds and not (bounds[0] <= r["_t"] <= bounds[1]):
                continue
            groups[(r.get("tc", ""), r.get("api", ""))].append((metric, r))

        for (tc, api), items in sorted(groups.items()):
            vals = sorted(r["_v"] for _, r in items)
            times = [r["_t"] for _, r in items]
            if bounds:
                span = (bounds[1] - bounds[0]).total_seconds()
            else:
                span = (max(times) - min(times)).total_seconds()
            fails = sum(1 for m, r in items if is_failure(r, m))
            out.append({
                "run_id": run["run_id"], "exp": run["exp"], "arch": run["arch"], "cond": run["cond"],
                "level": run["level"], "rep": run["rep"], "window": wname, "window_sec": fmt(span, 1),
                "tc": tc, "api": api, "n": len(vals),
                "mean_ms": sum(vals) / len(vals), "p50_ms": percentile(vals, 50),
                "p95_ms": percentile(vals, 95), "p99_ms": percentile(vals, 99), "max_ms": vals[-1],
                "fail_rate": fails / len(vals),
                "throughput_rps": len(vals) / span if span > 0 else math.nan,
            })
    return out


def summarize_open_loop(run, run_dir):
    duration = None
    summary_path = run_dir / "k6_summary.json"
    summary = json.loads(summary_path.read_text()) if summary_path.exists() else {}
    metrics = summary.get("metrics", {})

    iters = read_influx_csv(run_dir / "iterations.csv")
    dropped = read_influx_csv(run_dir / "dropped_iterations.csv")
    vus = read_influx_csv(run_dir / "vus.csv")
    completed = sum(r["_v"] for r in iters)
    dropped_n = sum(r["_v"] for r in dropped)
    if iters:
        duration = (max(r["_t"] for r in iters) - min(r["_t"] for r in iters)).total_seconds()

    rate = int(run["level"])
    dur = metrics.get("http_req_duration") or metrics.get("grpc_req_duration") or {}
    return {
        "run_id": run["run_id"], "arch": run["arch"], "rate_target": rate, "rep": run["rep"],
        "iterations_completed": int(completed), "dropped_iterations": int(dropped_n),
        "dropped_ratio": dropped_n / (completed + dropped_n) if completed + dropped_n else math.nan,
        "achieved_iter_rps": completed / duration if duration else math.nan,
        "iteration_window_sec": fmt(duration, 1),
        "max_active_vus": int(max((r["_v"] for r in vus), default=0)),
        # 아래는 k6 요약(JSON) 기준. InfluxDB 쓰기가 실패해도 영향을 받지 않으므로 논문 수치는 이쪽을 사용
        "k6_summary_iterations": metrics.get("iterations", {}).get("count", ""),
        "k6_summary_dropped": metrics.get("dropped_iterations", {}).get("count", 0 if metrics else ""),
        "k6_dropped_ratio_of_target": (metrics.get("dropped_iterations", {}).get("count", 0) / (rate * duration_sec(run_dir))) if metrics else math.nan,
        "k6_achieved_iter_rps": metrics.get("iterations", {}).get("rate", math.nan),  # 전체 테스트 시간(graceful stop 포함) 기준
        "k6_completed_per_scheduled_sec": metrics.get("iterations", {}).get("count", 0) / duration_sec(run_dir) if metrics else math.nan,
        "k6_max_vus": metrics.get("vus_max", {}).get("value", ""),
        "k6_all_tc_p50_ms": dur.get("med", math.nan),
        "k6_all_tc_p95_ms": dur.get("p(95)", math.nan),
        "k6_all_tc_p99_ms": dur.get("p(99)", math.nan),
        "influx_completeness": influx_completeness(run_dir),
    }


def duration_sec(run_dir):
    """open_loop 시나리오 지속 시간(초). k6_stdout.log 의 실행 옵션에서 읽고, 없으면 60."""
    log = run_dir / "k6_stdout.log"
    if log.exists():
        # 예: "* open_loop: 480.00 iterations/s for 1m0s (maxVUs: 1000, gracefulStop: 30s)"
        m = re.search(r"iterations/s for (?:(\d+)m)?(\d+)s", log.read_text(errors="replace"))
        if m:
            return int(m.group(1) or 0) * 60 + int(m.group(2))
    return 60


def summarize_resources(run, run_dir):
    out = []
    for role in ("api", "db", "k6"):
        path = run_dir / f"resource_{run['run_id']}_{role}.csv"
        if not path.exists():
            continue
        with path.open(newline="") as f:
            rows = list(csv.DictReader(f))
        cpus, mems = [], []
        for r in rows:
            try:
                cpus.append(float(r["cpu_perc"].rstrip("%")))
                mems.append(parse_mem_mib(r["mem_usage"].split("/")[0].strip()))
            except (ValueError, KeyError):
                continue
        if not cpus:
            continue
        out.append({
            "run_id": run["run_id"], "exp": run["exp"], "arch": run["arch"], "cond": run["cond"],
            "level": run["level"], "rep": run["rep"], "role": role, "container": rows[0]["container"],
            "samples": len(cpus), "cpu_mean_pct": sum(cpus) / len(cpus), "cpu_max_pct": max(cpus),
            "mem_mean_mib": sum(mems) / len(mems), "mem_max_mib": max(mems),
        })
    return out


def parse_mem_mib(s):
    units = {"B": 1 / 2**20, "KiB": 1 / 1024, "MiB": 1, "GiB": 1024, "kB": 1e3 / 2**20, "MB": 1e6 / 2**20, "GB": 1e9 / 2**20}
    m = re.match(r"^([\d.]+)\s*([A-Za-z]+)$", s)
    return float(m.group(1)) * units[m.group(2)]


def summarize_checks(run, run_dir):
    groups = defaultdict(list)
    for r in read_influx_csv(run_dir / "checks.csv"):
        groups[r.get("check", "")].append(r["_v"])
    return [{
        "run_id": run["run_id"], "arch": run["arch"], "cond": run["cond"], "level": run["level"],
        "rep": run["rep"], "check": name, "n": len(v), "pass_rate": sum(v) / len(v),
    } for name, v in sorted(groups.items())]


def influx_completeness(run_dir):
    """InfluxDB 에 저장된 요청 수 / k6 요약의 요청 수. 1 미만이면 InfluxDB 쓰기 실패로 일부 구간이 빠진 것."""
    path = run_dir / "k6_summary.json"
    if not path.exists():
        return math.nan
    metrics = json.loads(path.read_text()).get("metrics", {})
    total = (metrics.get("http_reqs") or metrics.get("grpc_req_duration") or {}).get("count")
    if not total:
        return math.nan
    stored = 0
    for metric in DURATION_METRICS:
        p = run_dir / f"{metric}.csv"
        if p.exists():
            with p.open() as fh:
                stored += max(sum(1 for _ in fh) - 1, 0)
    return stored / total


def summarize_diagnostics(run, run_dir):
    row = {"run_id": run["run_id"], "exp": run["exp"], "arch": run["arch"], "cond": run["cond"],
           "level": run["level"], "rep": run["rep"], "influx_completeness": influx_completeness(run_dir)}

    # 초당 완료 요청 수: 전 구간 중앙값 대비 최저 초의 비율. 멈춤이 있으면 0 에 가까워짐
    per_sec = defaultdict(int)
    window = steady_window(run, run_dir)
    for metric in DURATION_METRICS:
        for r in read_influx_csv(run_dir / f"{metric}.csv"):
            if window and not (window[0] <= r["_t"] <= window[1]):
                continue
            per_sec[int(r["_t"].timestamp())] += 1
    if len(per_sec) > 2:
        # 첫·마지막 초는 구간 경계에 걸려 일부만 포함되므로 제외
        secs = range(min(per_sec) + 1, max(per_sec))
        counts = sorted(per_sec.get(t, 0) for t in secs)
        median = counts[len(counts) // 2]
        worst = min(secs, key=lambda t: per_sec.get(t, 0))
        row["reqs_per_sec_median"] = median
        row["reqs_per_sec_min"] = counts[0]
        row["min_to_median_ratio"] = counts[0] / median if median else math.nan
        # 1~2초짜리 순간 저하는 멈춤 없는 실행에서도 보이므로, 지속 시간(초)을 따로 셈
        row["secs_below_half_median"] = sum(1 for c in counts if c < median / 2)
        row["worst_second"] = datetime.fromtimestamp(worst).astimezone().isoformat(timespec="seconds")

    # pg_stat_activity 샘플
    samples = defaultdict(lambda: defaultdict(int))
    path = run_dir / "pg_activity.csv"
    if path.exists():
        with path.open(newline="") as f:
            for r in csv.DictReader(f):
                try:
                    n = int(r["count"])
                except (ValueError, KeyError):
                    continue
                cur = samples[r["time"]]
                if r["state"] == "active":
                    cur["active"] += n
                if r["wait_event_type"] in ("Lock", "LWLock", "IO"):
                    cur[r["wait_event_type"]] += n
    for key, col in (("active", "pg_active_max"), ("Lock", "pg_lock_wait_max"), ("LWLock", "pg_lwlock_wait_max"), ("IO", "pg_io_wait_max")):
        row[col] = max((c[key] for c in samples.values()), default="")

    # DB 로그 이벤트
    path = run_dir / "db_log.txt"
    text = path.read_text(errors="replace") if path.exists() else ""
    row["db_checkpoints"] = text.count("checkpoint starting")
    row["db_autovacuum"] = text.count("automatic vacuum")
    row["db_autoanalyze"] = text.count("automatic analyze")
    row["db_slow_statements"] = text.count("duration:")
    row["db_lock_waits"] = text.count("still waiting for")

    # 호스트(WSL VM) vmstat
    path = run_dir / "host_vmstat.log"
    if path.exists():
        header, vals, first = None, defaultdict(list), True
        for line in path.read_text(errors="replace").splitlines():
            tok = line.split()
            if tok and tok[0] == "r":
                header = tok
            elif header and tok and tok[0].isdigit():
                if first:  # 첫 데이터 줄은 부팅 이후 평균값
                    first = False
                    continue
                for name, v in zip(header, tok):
                    if v.isdigit():
                        vals[name].append(int(v))
        row["host_run_queue_max"] = max(vals["r"], default="")
        row["host_cpu_idle_min"] = min(vals["id"], default="")
        row["host_iowait_max"] = max(vals["wa"], default="")
        row["host_steal_max"] = max(vals["st"], default="")
        row["host_swap_io_max"] = max((a + b for a, b in zip(vals["si"], vals["so"])), default="")
    return row


def aggregate_conditions(run_rows):
    groups = defaultdict(list)
    for r in run_rows:
        groups[(r["exp"], r["arch"], r["cond"], r["level"], r["window"], r["tc"], r["api"])].append(r)
    out = []
    for key, rs in sorted(groups.items(), key=lambda kv: (kv[0][0], kv[0][1], kv[0][2], int(kv[0][3]), kv[0][4], kv[0][5], kv[0][6])):
        row = dict(zip(("exp", "arch", "cond", "level", "window", "tc", "api"), key))
        row["reps"] = len(rs)
        row["run_ids"] = " ".join(sorted(r["run_id"] for r in rs))
        for stat in ("mean_ms", "p50_ms", "p95_ms", "p99_ms", "fail_rate", "throughput_rps"):
            vals = [r[stat] for r in rs if not math.isnan(r[stat])]
            base = stat.replace("_ms", "").replace("_rps", "")
            row[f"{base}_avg"] = sum(vals) / len(vals) if vals else math.nan
            row[f"{base}_min"] = min(vals) if vals else math.nan
            row[f"{base}_max"] = max(vals) if vals else math.nan
            row[f"{base}_range"] = (max(vals) - min(vals)) if vals else math.nan
        out.append(row)
    return out


def write_csv(path, rows):
    if not rows:
        print(f"  - {path.name}: 데이터 없음")
        return
    with path.open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        for r in rows:
            w.writerow({k: fmt(v) if isinstance(v, float) else v for k, v in r.items()})
    print(f"  - {path.name}: {len(rows)}행")


def main():
    if len(sys.argv) != 2:
        sys.exit("사용법: summarize_experiments.py csv_results/exp_<session>")
    session_dir = Path(sys.argv[1])
    manifest = load_manifest(session_dir)

    run_rows, open_rows, res_rows, check_rows, diag_rows = [], [], [], [], []
    for run in manifest:
        run_dir = session_dir / run["run_id"]
        if not run_dir.is_dir():
            print(f"  [경고] 폴더 없음: {run_dir}")
            continue
        if run.get("k6_exit") not in ("0", ""):
            print(f"  [경고] k6 비정상 종료({run['k6_exit']}): {run['run_id']}")
        run_rows.extend(summarize_run(run, run_dir))
        if run["exp"] == "C":
            open_rows.append(summarize_open_loop(run, run_dir))
        res_rows.extend(summarize_resources(run, run_dir))
        check_rows.extend(summarize_checks(run, run_dir))
        diag_rows.append(summarize_diagnostics(run, run_dir))

    print(f"[집계] {session_dir}")
    write_csv(session_dir / "summary_runs.csv", run_rows)
    write_csv(session_dir / "summary_conditions.csv", aggregate_conditions(run_rows))
    write_csv(session_dir / "summary_open_loop.csv", open_rows)
    write_csv(session_dir / "summary_resources.csv", res_rows)
    write_csv(session_dir / "summary_checks.csv", check_rows)
    write_csv(session_dir / "summary_diagnostics.csv", diag_rows)


if __name__ == "__main__":
    main()
