#!/usr/bin/env python3
"""S8 spike: run vkd3d-proton's d3d12 test binary one test per process.

Replaces upstream tests/test-runner.sh (needs Linux /proc and bash 4).
Usage: run-tests.py <d3d12-binary> <out-dir> [--jobs N] [--timeout S]
       [--env K=V ...] [--match substring]

Writes <out-dir>/logs/<test>.log, <out-dir>/results.tsv and prints a summary.
A test "passes" when it exits 0 with 0 failures and is not fully skipped.
"""
import argparse
import concurrent.futures as cf
import os
import re
import subprocess
import sys
import time

SUMMARY = re.compile(r"(\d+) tests executed \((\d+) failures, (\d+) successful todo, (\d+) skipped, (\d+) todo, (\d+) bugs\)")


def run_one(binary, name, env, timeout, logdir):
    e = dict(os.environ)
    e.update(env)
    e["VKD3D_TEST_MATCH"] = name
    t0 = time.time()
    try:
        p = subprocess.run([binary], env=e, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
        out = p.stdout.decode("utf-8", "replace")
        rc = p.returncode
    except subprocess.TimeoutExpired as ex:
        out = (ex.stdout or b"").decode("utf-8", "replace") + "\n[S8] TIMEOUT\n"
        rc = "timeout"
    dt = time.time() - t0
    with open(os.path.join(logdir, name + ".log"), "w") as f:
        f.write(out)
    m = None
    for m in SUMMARY.finditer(out):
        pass
    if rc == "timeout":
        status = "timeout"
    elif m is None:
        status = "crash" if rc != 0 else "nosummary"
    else:
        executed, failures, _, skipped, todo, bugs = map(int, m.groups())
        if rc != 0 and failures == 0:
            status = "crash"
        elif failures:
            status = "fail"
        elif executed == 0 and skipped:
            status = "skip"
        else:
            status = "pass"
    checks = m.groups() if m else ("", "", "", "", "", "")
    return name, status, rc, dt, checks


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("binary")
    ap.add_argument("outdir")
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--timeout", type=int, default=90)
    ap.add_argument("--env", action="append", default=[])
    ap.add_argument("--match", default=None)
    a = ap.parse_args()

    env = dict(kv.split("=", 1) for kv in a.env)
    names = subprocess.run([a.binary, "--list-tests"], stdout=subprocess.PIPE, env={**os.environ, **env},
                           check=True).stdout.decode().split()
    names = [n for n in names if "stress" not in n]
    if a.match:
        names = [n for n in names if a.match in n]
    logdir = os.path.join(a.outdir, "logs")
    os.makedirs(logdir, exist_ok=True)

    results = []
    with cf.ThreadPoolExecutor(a.jobs) as ex:
        futs = [ex.submit(run_one, a.binary, n, env, a.timeout, logdir) for n in names]
        for i, f in enumerate(cf.as_completed(futs), 1):
            r = f.result()
            results.append(r)
            if r[1] not in ("pass",):
                print(f"[{i}/{len(names)}] {r[1].upper():8} {r[0]}", flush=True)
    results.sort()
    with open(os.path.join(a.outdir, "results.tsv"), "w") as f:
        f.write("test\tstatus\texit\tseconds\texecuted\tfailures\tsuccessful_todo\tskipped\ttodo\tbugs\n")
        for name, status, rc, dt, checks in results:
            f.write("\t".join([name, status, str(rc), f"{dt:.1f}", *checks]) + "\n")
    counts = {}
    for r in results:
        counts[r[1]] = counts.get(r[1], 0) + 1
    tot = lambda i: sum(int(r[4][i]) for r in results if r[4][0] != "")
    print(f"tests: {len(results)}  " + "  ".join(f"{k}: {v}" for k, v in sorted(counts.items())))
    print(f"checks: executed {tot(0)}  failures {tot(1)}  skipped {tot(3)}  todo {tot(4)}  (crashed/timed-out tests not counted)")


if __name__ == "__main__":
    sys.exit(main())
