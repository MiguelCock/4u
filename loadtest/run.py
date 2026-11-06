"""Runs the plan's load tests against the deployed server.

    uv run python run.py smoke --window      # or: baseline, users, admins,
    uv run python run.py all --window        # mixed, long, all

--window says nobody is testing or editing right now. It provisions, runs,
always cleans up, and writes the results to .data/results/<time>/.
"""

import argparse
import json
import os
import signal
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

from loadtool import config
from loadtool.report import render_run

# name: list of (label, navigating users, admins, minutes)
RUNS = {
    "smoke": [("smoke", 1, 1, 3)],
    "baseline": [("baseline", 1, 0, 5)],
    "users": [(f"users-{n}", n, 0, 5) for n in (5, 10, 15, 20)],
    "admins": [(f"admins-{n}", 0, n, 5) for n in (5, 10)],
    "mixed": [("mixed-10-users-5-admins", 10, 5, 10)],
    "long": [("long-10-users", 10, 0, 30)],
}
RUNS["all"] = [step for name in list(RUNS) for step in RUNS[name]]
PAUSE_SECONDS = 60


def build_state(run_root: Path) -> Path:
    env = config.settings()
    trips = json.loads(config.TRIPS_FILE.read_text())
    accounts = json.loads(config.ACCOUNTS_FILE.read_text())
    versions = json.loads(
        (config.REPO / "packages/src/packages/app_versions.json").read_text()
    )
    state = {
        **trips,
        **accounts,
        "app_version": versions["latest"],
        "api_url": env["API_GATEWAY_URL"],
        "supabase_url": env["SUPABASE_URL"],
        "publishable_key": env["SUPABASE_PUBLISHABLE_KEY"],
    }
    path = run_root / "state.json"
    path.write_text(json.dumps(state))
    path.chmod(0o600)
    return path


def run_step(label: str, nav: int, admins: int, minutes: int, state: Path, root: Path):
    out = root / label
    out.mkdir()
    print(f"== {label}: {nav} users, {admins} admins, {minutes} min", flush=True)
    sampler = subprocess.Popen(
        [sys.executable, "sample_server.py", str(out / "server.csv")],
        cwd=config.ROOT,
    )
    try:
        subprocess.run(
            [
                sys.executable,
                "-m",
                "locust",
                "-f",
                "locustfile.py",
                "--headless",
                "--users",
                str(nav + admins),
                "--spawn-rate",
                "1",
                "--run-time",
                f"{minutes}m",
                "--stop-timeout",
                "20",
                "--csv",
                str(out / "run"),
                "--only-summary",
            ],
            cwd=config.ROOT,
            env={
                **os.environ,
                "LOADTEST_STATE": str(state),
                "LOADTEST_RESULTS": str(out),
                "LOADTEST_NAV": str(nav),
                "LOADTEST_ADMINS": str(admins),
            },
            check=False,
            # Past the run time and its stop timeout, it's stuck.
            timeout=minutes * 60 + 120,
        )
    except subprocess.TimeoutExpired:
        (out / "stop_reason.txt").write_text("the run got stuck and was killed\n")
    finally:
        sampler.send_signal(signal.SIGTERM)
        sampler.wait()
    return out


def cpu_credit_mode() -> str:
    """Standard runs out of credits and slows down; unlimited spends money."""
    try:
        result = subprocess.run(
            [
                "aws",
                "ec2",
                "describe-instance-credit-specifications",
                "--instance-ids",
                config.INSTANCE_ID,
                "--region",
                "us-east-1",
                "--query",
                "InstanceCreditSpecifications[0].CpuCredits",
                "--output",
                "text",
            ],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except OSError, subprocess.TimeoutExpired:
        return "unknown"
    return result.stdout.strip() or "unknown"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("run", choices=RUNS)
    parser.add_argument(
        "--window",
        action="store_true",
        help="nobody is testing or editing the map right now",
    )
    args = parser.parse_args()
    if not args.window:
        sys.exit("Refusing to run without --window: see the README.")
    if not config.TRIPS_FILE.exists():
        sys.exit("Run prepare.py first.")

    root = config.RESULTS_DIR / datetime.now(UTC).strftime("%Y%m%d-%H%M%S")
    root.mkdir(parents=True)
    report = [f"CPU credit mode: {cpu_credit_mode()}", ""]
    try:
        subprocess.run([sys.executable, "provision.py"], cwd=config.ROOT, check=True)
        state = build_state(root)
        for index, step in enumerate(RUNS[args.run]):
            if index:
                time.sleep(PAUSE_SECONDS)
            out = run_step(*step, state, root)
            report.append(render_run(step[0], out))
            (root / "report.md").write_text("\n".join(report))
            # The next steps are heavier: don't push a server that's struggling.
            if (out / "stop_reason.txt").exists():
                print(f"Stopped at {step[0]}: skipping the remaining steps.")
                break
    finally:
        # Always, even after Ctrl-C or a failure above.
        cleaned = subprocess.run(
            [sys.executable, "cleanup.py"], cwd=config.ROOT, check=False
        )
        (root / "state.json").unlink(missing_ok=True)
        if cleaned.returncode:
            sys.exit(
                "CLEANUP FAILED: test data is still on the server. Run cleanup.py."
            )
    print(f"Report: {root / 'report.md'}")


if __name__ == "__main__":
    main()
