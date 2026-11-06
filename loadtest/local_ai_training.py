"""Overloads ai-training on this computer, never the server, with its CPU limited
to the server's. Photos go straight to /search_similar at a fixed rate, the way
positioning sends them, against a local Qdrant with nothing in it.

    uv run python local_ai_training.py --rate 3.3 --seconds 120
    uv run python local_ai_training.py --env TORCH_THREADS=1 --memory 1800m

Qdrant answers faster here than Qdrant Cloud does, and this computer's CPU isn't
the server's, so compare runs with each other rather than with production.
"""

import argparse
import statistics
import subprocess
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from itertools import cycle

import requests

from loadtool import config
from loadtool.report import percentile
from loadtool.sampling import memory_mb

NETWORK = "loadtest-local"
QDRANT = "loadtest-qdrant"
SERVICE = "loadtest-ai-training"
IMAGE = "loadtest-ai-training:local"
PORT = 18080
URL = f"http://127.0.0.1:{PORT}"


def docker(*args: str, check: bool = True) -> str:
    return subprocess.run(
        ["docker", *args], check=check, capture_output=True, text=True
    ).stdout.strip()


def remove_containers() -> None:
    docker("rm", "-f", SERVICE, QDRANT, check=False)


def start(args) -> None:
    remove_containers()
    docker("network", "create", NETWORK, check=False)
    docker(
        "run",
        "-d",
        "--name",
        QDRANT,
        "--network",
        NETWORK,
        "qdrant/qdrant:v1.13.6",
    )
    limits = (
        ["--memory", args.memory, "--memory-swap", args.memory] if args.memory else []
    )
    env = [flag for pair in args.env for flag in ("-e", pair)]
    docker(
        "run",
        "-d",
        "--name",
        SERVICE,
        "--network",
        NETWORK,
        # Two real CPUs, not --cpus 2: that caps the time, but torch still sees
        # them all, starts a thread per CPU, and is throttled.
        "--cpuset-cpus",
        args.cpuset,
        "--restart",
        "unless-stopped",
        "-p",
        f"127.0.0.1:{PORT}:80",
        "-e",
        f"QDRANT_URL=http://{QDRANT}:6333",
        "-e",
        "QDRANT_KEY=local",
        "-e",
        "SUPABASE_URL=http://127.0.0.1:9",
        "-e",
        "SUPABASE_SERVICE_ROLE_KEY=local",
        *env,
        *limits,
        IMAGE,
    )
    for _ in range(120):
        try:
            if requests.get(URL, timeout=1).ok:
                return
        except requests.RequestException:
            pass
        time.sleep(1)
    raise SystemExit("ai-training didn't start:\n" + docker("logs", SERVICE))


def send(photo: bytes, timeout: float, retries: int, results: list) -> None:
    """One photo, as positioning sends it: its attempts and their gaps."""
    started = time.monotonic()
    outcome = "failed"
    for attempt in range(retries + 1):
        try:
            response = requests.post(
                f"{URL}/search_similar",
                files={"file": ("frame.jpg", photo, "image/jpeg")},
                data={"limit": "5", "latitude": "6.2", "longitude": "-75.5"},
                timeout=timeout,
            )
            if response.ok:
                outcome = "answered"
                break
            outcome = f"http {response.status_code}"
            if response.status_code == 503:
                break
        except requests.Timeout:
            outcome = "timed out"
        except requests.RequestException:
            outcome = "no connection"
        if attempt < retries:
            time.sleep(0.2 * (attempt + 1))
    results.append((outcome, time.monotonic() - started))


def sample_memory(stop: threading.Event, samples: list[float]) -> None:
    while not stop.is_set():
        line = docker(
            "stats", "--no-stream", "--format", "{{.MemUsage}}", SERVICE, check=False
        )
        if line and not line.startswith("0B"):
            samples.append(memory_mb(line))
        stop.wait(1)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rate", type=float, default=3.3, help="photos per second")
    parser.add_argument("--seconds", type=int, default=120)
    parser.add_argument(
        "--cpuset",
        default="6,7",
        help="the server has 2 CPUs; pick ones the desktop isn't busy on",
    )
    parser.add_argument("--memory", help="the container's limit, like 1800m")
    parser.add_argument("--env", action="append", default=[], help="NAME=value")
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--settle", type=int, default=30)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--label", default="")
    args = parser.parse_args()

    if args.build:
        subprocess.run(
            [
                "docker",
                "build",
                "-q",
                "-f",
                "backend-ai-training/Dockerfile",
                "-t",
                IMAGE,
                ".",
            ],
            cwd=config.REPO,
            check=True,
            stdout=subprocess.DEVNULL,
        )
    frames = [
        p.read_bytes() for p in sorted((config.DATA_DIR / "frames").glob("*.jpg"))
    ]
    start(args)
    try:
        # One unhurried photo first, so all runs start with the model loaded.
        send(frames[0], 60, 0, [])
        idle = memory_mb(
            docker("stats", "--no-stream", "--format", "{{.MemUsage}}", SERVICE)
        )

        results: list = []
        samples: list[float] = []
        stop = threading.Event()
        sampler = threading.Thread(target=sample_memory, args=(stop, samples))
        sampler.start()
        with ThreadPoolExecutor(max_workers=300) as pool:
            photos = cycle(frames)
            started = time.monotonic()
            for index in range(int(args.rate * args.seconds)):
                time.sleep(max(0, started + index / args.rate - time.monotonic()))
                pool.submit(send, next(photos), args.timeout, args.retries, results)
        stop.set()
        sampler.join()

        # Does it come back, and stay up, once the load is gone?
        time.sleep(5)
        ended = docker("inspect", "--format", "{{.RestartCount}}", SERVICE)
        time.sleep(args.settle)
        recovered: list = []
        send(frames[0], 30, 2, recovered)
        print(f"  after the load, {args.settle} s later: {recovered[0][0]}")
        restarts = docker("inspect", "--format", "{{.RestartCount}}", SERVICE)
        killed = docker("inspect", "--format", "{{.State.OOMKilled}}", SERVICE)
        times = [seconds for _, seconds in results]
        counts = {
            outcome: sum(1 for o, _ in results if o == outcome)
            for outcome in sorted({o for o, _ in results})
        }
        print(
            f"{args.label or 'run'}: rate {args.rate}/s, cpus {args.cpuset}, "
            f"retries {args.retries}, env {args.env}, limit {args.memory}"
        )
        print(f"  outcomes: {counts} of {len(results)}")
        print(
            f"  time per photo: {statistics.median(times):.2f} s p50, "
            f"{percentile(times, 0.95):.2f} s p95"
        )
        print(f"  memory: {idle:.0f} MB idle, {max(samples):.0f} MB peak")
        print(
            f"  restarts: {ended} when the load ended, {restarts} after settling, "
            f"killed for memory: {killed}"
        )
    finally:
        remove_containers()
        docker("network", "rm", NETWORK, check=False)


if __name__ == "__main__":
    main()
