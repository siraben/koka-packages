#!/usr/bin/env python3
"""Build, measure, and plot the cross-language package benchmarks.

Case manifests live below ``cases/``. Commands run without a shell, relative
to the manifest (or an implementation's optional ``cwd``). The only required
runtime argument convention is a literal ``{work}`` placeholder.

Collection follows the methodology of Koka's Perceus figure:
execution time and peak resident set size are averaged over ten process runs
and normalized to Koka. Raw samples, exact commands, and checksums are retained
in JSON.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import platform
import statistics
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any
from xml.sax.saxutils import escape


HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
CASES = HERE / "cases"
RESULTS = HERE / "results.json"
FIGURES = HERE / "figures"

COLORS = {
    "Koka": "#9f2f2f",
    "C++": "#6159a5",
    "Go": "#3f92a8",
    "Python": "#e0a126",
}
FALLBACK_COLORS = ["#4c956c", "#7a6c5d", "#b56576", "#577590"]
PACKAGE_ORDER = [
    "bytes",
    "strbuilder",
    "hashmap",
    "json",
    "logging",
    "http",
    "runtime",
    "sqlite",
    "fileio",
    "resource",
]


def load_manifests() -> list[dict[str, Any]]:
    cases: list[dict[str, Any]] = []
    seen: set[str] = set()
    for path in sorted(CASES.glob("**/manifest.json")):
        manifest = json.loads(path.read_text())
        for case in manifest.get("cases", []):
            case_id = case.get("id")
            if not case_id or case_id in seen:
                raise SystemExit(f"missing or duplicate case id in {path}: {case_id!r}")
            seen.add(case_id)
            copied = dict(case)
            copied["_manifest"] = str(path.relative_to(ROOT))
            copied["_base"] = str(path.parent)
            cases.append(copied)
    if not cases:
        raise SystemExit(f"no manifest.json files found below {CASES}")
    return cases


def expanded(argv: list[str], work: int) -> list[str]:
    return [arg.format(work=work) for arg in argv]


def implementation_cwd(case: dict[str, Any], implementation: dict[str, Any]) -> Path:
    return Path(case["_base"]) / implementation.get("cwd", ".")


def run_checked(argv: list[str], cwd: Path, *, capture: bool = False) -> str:
    print(f"+ ({cwd.relative_to(ROOT)}) {' '.join(argv)}", flush=True)
    result = subprocess.run(
        argv,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.STDOUT if capture else None,
    )
    if result.returncode != 0:
        output = result.stdout or ""
        raise SystemExit(
            f"command failed with status {result.returncode}: {' '.join(argv)}\n{output}"
        )
    return (result.stdout or "").strip()


def build(cases: list[dict[str, Any]]) -> None:
    for case in cases:
        for implementation in case["implementations"]:
            command = implementation.get("build")
            if command:
                run_checked(
                    expanded(command, int(case["default_work"])),
                    implementation_cwd(case, implementation),
                )


def version_of(case: dict[str, Any], implementation: dict[str, Any]) -> str:
    command = implementation.get("version_command")
    if not command:
        return "not recorded"
    output = run_checked(
        expanded(command, int(case["default_work"])),
        implementation_cwd(case, implementation),
        capture=True,
    )
    lines = [line.strip() for line in output.splitlines() if line.strip()]
    if not lines:
        return "unknown"
    language = implementation["language"]
    if language == "Koka":
        return next((line for line in lines if line.startswith("Koka ")), lines[0])
    return lines[0]


def _linux_peak_rss(proc: subprocess.Popen[bytes]) -> int:
    """Poll the kernel-maintained post-exec high-water RSS for ``proc``."""

    status_path = Path(f"/proc/{proc.pid}/status")
    cmdline_path = Path(f"/proc/{proc.pid}/cmdline")
    try:
        parent_cmdline = Path("/proc/self/cmdline").read_bytes()
        # Popen may fork before exec. Sampling in that window records the
        # collector's own high-water mark and gives every implementation the
        # same false floor. Wait until the child's command line changes.
        while proc.poll() is None:
            try:
                if cmdline_path.read_bytes() != parent_cmdline:
                    break
            except OSError:
                break
            time.sleep(0.0001)

        peak_kib = 0
        while True:
            try:
                for line in status_path.read_text().splitlines():
                    if line.startswith("VmHWM:"):
                        peak_kib = max(peak_kib, int(line.split()[1]))
                        break
            except (OSError, ValueError):
                pass
            if proc.poll() is not None:
                break
            time.sleep(0.0005)
        return peak_kib
    except OSError:
        return 0


def measure_once(argv: list[str], cwd: Path) -> tuple[float, int, str]:
    """Return wall milliseconds, peak RSS KiB, and stripped stdout.

    Linux's ``VmHWM`` gives the post-exec high-water RSS for this exact child.
    A temporary file prevents a verbose or accidentally broken candidate from
    filling a pipe and deadlocking before it can be rejected.
    """

    with tempfile.TemporaryFile() as stdout, tempfile.TemporaryFile() as stderr:
        started = time.perf_counter_ns()
        proc = subprocess.Popen(argv, cwd=cwd, stdout=stdout, stderr=stderr)
        rss_kib = _linux_peak_rss(proc)
        returncode = proc.wait()
        elapsed_ms = (time.perf_counter_ns() - started) / 1_000_000
        stdout.seek(0)
        stderr.seek(0)
        output = stdout.read().decode("utf-8", "replace").strip()
        errors = stderr.read().decode("utf-8", "replace").strip()
    if returncode != 0:
        raise SystemExit(
            f"benchmark failed with status {returncode}: {' '.join(argv)}\n{errors}"
        )
    if rss_kib <= 0:
        raise SystemExit(
            "peak RSS collection requires Linux /proc and a workload long "
            f"enough to observe: {' '.join(argv)}"
        )
    return elapsed_ms, rss_kib, output


def collect(cases: list[dict[str, Any]], trials: int, warmups: int) -> dict[str, Any]:
    build(cases)
    collected_cases: list[dict[str, Any]] = []
    for case in cases:
        work = int(case["default_work"])
        implementations = case["implementations"]
        if not any(impl["language"] == "Koka" for impl in implementations):
            raise SystemExit(f"{case['id']} has no Koka baseline")

        commands: dict[str, tuple[list[str], Path]] = {}
        versions: dict[str, str] = {}
        samples: dict[str, list[dict[str, Any]]] = {
            implementation["id"]: [] for implementation in implementations
        }
        checksums: dict[str, str] = {}
        for implementation in implementations:
            impl_id = implementation["id"]
            commands[impl_id] = (
                expanded(implementation["run"], work),
                implementation_cwd(case, implementation),
            )
            versions[impl_id] = version_of(case, implementation)

        print(f"\n### {case['id']}: {case['title']}", flush=True)
        for warmup in range(warmups):
            for implementation in implementations:
                command, cwd = commands[implementation["id"]]
                _elapsed, _rss, checksum = measure_once(command, cwd)
                checksums.setdefault(implementation["id"], checksum)
                print(
                    f"warmup {warmup + 1}/{warmups} {implementation['language']}",
                    flush=True,
                )

        # Rotate order on each trial. This is deterministic while avoiding a
        # permanent first/last implementation bias as caches and temperature
        # settle.
        for trial in range(trials):
            ordered = implementations[trial % len(implementations) :] + implementations[
                : trial % len(implementations)
            ]
            for implementation in ordered:
                impl_id = implementation["id"]
                command, cwd = commands[impl_id]
                elapsed_ms, rss_kib, checksum = measure_once(command, cwd)
                previous = checksums.setdefault(impl_id, checksum)
                if checksum != previous:
                    raise SystemExit(
                        f"{case['id']}/{impl_id} checksum changed: "
                        f"{previous!r} vs {checksum!r}"
                    )
                samples[impl_id].append(
                    {"elapsed_ms": round(elapsed_ms, 3), "peak_rss_kib": rss_kib}
                )
                print(
                    f"trial {trial + 1}/{trials} {implementation['language']}: "
                    f"{elapsed_ms:.1f} ms, {rss_kib / 1024:.1f} MiB",
                    flush=True,
                )

        distinct_checksums = {checksum for checksum in checksums.values()}
        if len(distinct_checksums) != 1:
            detail = ", ".join(f"{key}={value!r}" for key, value in checksums.items())
            raise SystemExit(f"{case['id']} implementations disagree: {detail}")

        result_implementations: list[dict[str, Any]] = []
        for implementation in implementations:
            impl_id = implementation["id"]
            elapsed = [sample["elapsed_ms"] for sample in samples[impl_id]]
            rss = [sample["peak_rss_kib"] for sample in samples[impl_id]]
            result_implementations.append(
                {
                    "id": impl_id,
                    "language": implementation["language"],
                    "version": versions[impl_id],
                    "command": commands[impl_id][0],
                    "checksum": checksums[impl_id],
                    "mean_elapsed_ms": round(statistics.fmean(elapsed), 3),
                    "stdev_elapsed_ms": round(statistics.stdev(elapsed), 3)
                    if len(elapsed) > 1
                    else 0.0,
                    "mean_peak_rss_kib": round(statistics.fmean(rss)),
                    "samples": samples[impl_id],
                }
            )

        koka = next(
            implementation
            for implementation in result_implementations
            if implementation["language"] == "Koka"
        )
        for implementation in result_implementations:
            implementation["relative_time"] = round(
                implementation["mean_elapsed_ms"] / koka["mean_elapsed_ms"], 3
            )
            implementation["relative_rss"] = round(
                implementation["mean_peak_rss_kib"] / koka["mean_peak_rss_kib"], 3
            )

        collected_cases.append(
            {
                "id": case["id"],
                "title": case["title"],
                "chart_label": case.get("chart_label", case["title"]),
                "package": case.get("package", case["id"].split("-")[0]),
                "unit": case["unit"],
                "work": work,
                "equivalence": case["equivalence"],
                "manifest": case["_manifest"],
                "implementations": result_implementations,
            }
        )

    uname = platform.uname()
    result = {
        "schema": 1,
        "collected_at": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat(),
        "machine": {
            "processor": _cpu_name(),
            "threads": os.cpu_count(),
            "memory_kib": _memory_kib(),
            "os": f"{uname.system} {uname.release} {uname.machine}",
        },
        "method": {
            "trials": trials,
            "warmups": warmups,
            "time": "arithmetic mean of wall-clock process elapsed time",
            "memory": "arithmetic mean of post-exec Linux /proc VmHWM",
            "normalization": "Koka = 1.0; lower is better",
            "order": "deterministic rotation across implementations",
            "validation": "stdout checksum must be stable and identical across languages",
        },
        "cases": collected_cases,
    }
    RESULTS.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    return result


def _cpu_name() -> str:
    try:
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith("model name"):
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown"


def _memory_kib() -> int | None:
    try:
        for line in Path("/proc/meminfo").read_text().splitlines():
            if line.startswith("MemTotal:"):
                return int(line.split()[1])
    except OSError:
        pass
    return None


def language_colors(data: dict[str, Any]) -> dict[str, str]:
    languages = language_order(data)
    colors = dict(COLORS)
    for language in languages:
        if language not in colors:
            colors[language] = FALLBACK_COLORS[len(colors) % len(FALLBACK_COLORS)]
    return colors


def language_order(data: dict[str, Any]) -> list[str]:
    return list(
        dict.fromkeys(
            implementation["language"]
            for case in data["cases"]
            for implementation in case["implementations"]
        )
    )


def svg_start(width: int, height: int, title: str, description: str) -> list[str]:
    return [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-labelledby="title desc">',
        f'<title id="title">{escape(title)}</title>',
        f'<desc id="desc">{escape(description)}</desc>',
        "<style>",
        "text{font-family:ui-sans-serif,system-ui,-apple-system,sans-serif;fill:#172033}",
        ".title{font-size:24px;font-weight:700}.sub{font-size:12px;fill:#58677c}",
        ".axis{font-size:11px;fill:#66758a}.label{font-size:12px;font-weight:650}",
        ".value{font-size:10px;font-weight:700}.grid{stroke:#d9e1ea;stroke-width:1}",
        "</style>",
        '<rect width="100%" height="100%" rx="12" fill="#f8fafc"/>',
        f'<text class="title" x="28" y="38">{escape(title)}</text>',
        f'<text class="sub" x="28" y="59">{escape(description)}</text>',
    ]


def render_overview(data: dict[str, Any]) -> str:
    package_rank = {package: rank for rank, package in enumerate(PACKAGE_ORDER)}
    cases = sorted(
        data["cases"],
        key=lambda case: package_rank.get(case["package"], len(package_rank)),
    )
    colors = language_colors(data)
    width = 1200
    row_height = 70
    top = 134
    bottom_pad = 58
    height = top + row_height * len(cases) + bottom_pad
    time_x = 250
    rss_x = 742
    plot_width = 395
    field_limits = {
        field: max(
            1.0,
            math.ceil(
                max(
                    float(implementation[field])
                    for case in cases
                    for implementation in case["implementations"]
                )
            ),
        )
        for field in ("relative_time", "relative_rss")
    }
    lines = svg_start(
        width,
        height,
        "koka-packages across languages",
        f'mean of {data["method"]["trials"]} process runs, normalized to '
        "Koka = 1.00×; lower is better",
    )

    languages = language_order(data)
    language_rank = {language: rank for rank, language in enumerate(languages)}
    legend_x = 28
    for language in languages:
        lines.extend(
            [
                f'<rect x="{legend_x}" y="77" width="13" height="13" rx="2" '
                f'fill="{colors[language]}"/>',
                f'<text class="label" x="{legend_x + 19}" y="88">{escape(language)}</text>',
            ]
        )
        legend_x += 84

    for panel_x, field, heading in [
        (time_x, "relative_time", "relative execution time"),
        (rss_x, "relative_rss", "relative peak RSS"),
    ]:
        limit = field_limits[field]
        lines.append(f'<text class="label" x="{panel_x}" y="104">{heading}</text>')
        for tick in range(0, 6):
            x = panel_x + (tick / 5) * plot_width
            tick_value = tick * limit / 5
            lines.append(
                f'<line class="grid" x1="{x:.1f}" y1="{top - 10}" '
                f'x2="{x:.1f}" y2="{height - bottom_pad + 2}"/>'
            )
            lines.append(
                f'<text class="axis" x="{x:.1f}" y="{top - 17}" '
                f'text-anchor="middle">{tick_value:g}×</text>'
            )

    for case_index, case in enumerate(cases):
        row_top = top + case_index * row_height
        label_y = row_top + 21
        lines.extend(
            [
                f'<text class="label" x="28" y="{label_y}">{escape(case["package"])}</text>',
                f'<text class="axis" x="28" y="{label_y + 17}">'
                f'{escape(case["chart_label"])}</text>',
                f'<line class="grid" x1="28" y1="{row_top + row_height - 5}" '
                f'x2="{width - 28}" y2="{row_top + row_height - 5}"/>',
            ]
        )
        implementations = sorted(
            case["implementations"],
            key=lambda implementation: language_rank[implementation["language"]],
        )
        lane_height = min(11.0, 43.0 / max(1, len(implementations)))
        for panel_x, field in [
            (time_x, "relative_time"),
            (rss_x, "relative_rss"),
        ]:
            limit = field_limits[field]
            for implementation_index, implementation in enumerate(implementations):
                value = float(implementation[field])
                bar_width = (value / limit) * plot_width
                y = row_top + 4 + implementation_index * lane_height
                lines.append(
                    f'<rect x="{panel_x}" y="{y:.1f}" width="{max(3, bar_width):.1f}" '
                    f'height="{max(5, lane_height - 2):.1f}" rx="2" '
                    f'fill="{colors[implementation["language"]]}"/>'
                )
                lines.append(
                    f'<text class="value" x="{min(panel_x + bar_width + 5, panel_x + plot_width - 30):.1f}" '
                    f'y="{y + max(7, lane_height - 3):.1f}">{value:.2f}×</text>'
                )

    machine = data["machine"]
    lines.append(
        f'<text class="sub" x="28" y="{height - 20}">'
        f'{escape(machine["processor"])} ({machine["threads"]} threads) · '
        f'{escape(data["collected_at"])}</text>'
    )
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def render_case(data: dict[str, Any], case: dict[str, Any]) -> str:
    width = 820
    row_height = 52
    rank = {language: index for index, language in enumerate(language_order(data))}
    implementations = sorted(
        case["implementations"],
        key=lambda implementation: rank[implementation["language"]],
    )
    height = 142 + row_height * len(implementations) + 48
    colors = language_colors(data)
    lines = svg_start(
        width,
        height,
        case["title"],
        f'mean of {data["method"]["trials"]} process runs, normalized to '
        "Koka = 1.00×; lower is better",
    )
    lines.append(
        f'<text class="sub" x="28" y="83">equivalent work and identical checksum · '
        f'{case["work"]} {escape(case["unit"])}</text>'
    )
    x_time, x_rss, scale = 190, 500, 230
    time_limit = max(
        1.0, math.ceil(max(float(item["relative_time"]) for item in implementations))
    )
    rss_limit = max(
        1.0, math.ceil(max(float(item["relative_rss"]) for item in implementations))
    )
    lines.extend(
        [
            f'<text class="label" x="{x_time}" y="111">execution time</text>',
            f'<text class="label" x="{x_rss}" y="111">peak RSS</text>',
        ]
    )
    y = 132
    for implementation in implementations:
        time_ratio = float(implementation["relative_time"])
        rss_ratio = float(implementation["relative_rss"])
        time_width = scale * time_ratio / time_limit
        rss_width = scale * rss_ratio / rss_limit
        color = colors[implementation["language"]]
        lines.extend(
            [
                f'<text class="label" x="28" y="{y + 15}">{escape(implementation["language"])}</text>',
                f'<rect x="{x_time}" y="{y}" width="{max(3, time_width):.1f}" height="20" '
                f'rx="4" fill="{color}"/>',
                f'<text class="value" x="{x_time + max(3, time_width) + 7:.1f}" '
                f'y="{y + 14}">{time_ratio:.2f}×</text>',
                f'<rect x="{x_rss}" y="{y}" width="{max(3, rss_width):.1f}" height="20" '
                f'rx="4" fill="{color}"/>',
                f'<text class="value" x="{x_rss + max(3, rss_width) + 7:.1f}" '
                f'y="{y + 14}">{rss_ratio:.2f}×</text>',
            ]
        )
        y += row_height
    lines.append(
        f'<text class="sub" x="28" y="{height - 20}">Raw samples and commands: '
        f'benchmarks/cross/results.json · {escape(data["machine"]["processor"])}</text>'
    )
    lines.append("</svg>")
    return "\n".join(lines) + "\n"


def render(data: dict[str, Any]) -> None:
    FIGURES.mkdir(parents=True, exist_ok=True)
    for old_figure in FIGURES.glob("*.svg"):
        old_figure.unlink()
    (FIGURES / "cross-language.svg").write_text(render_overview(data))
    for case in data["cases"]:
        (FIGURES / f"{case['id']}.svg").write_text(render_case(data, case))
    print(f"wrote {len(data['cases']) + 1} cross-language figures")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--collect", action="store_true", help="build and run every case")
    parser.add_argument("--build-only", action="store_true", help="only build every case")
    parser.add_argument("--trials", type=int, default=10)
    parser.add_argument("--warmups", type=int, default=1)
    args = parser.parse_args()
    if args.trials <= 0 or args.warmups < 0:
        parser.error("trials must be positive and warmups cannot be negative")
    cases = load_manifests()
    if args.build_only:
        build(cases)
        return
    if args.collect:
        data = collect(cases, args.trials, args.warmups)
    else:
        if not RESULTS.exists():
            raise SystemExit(f"{RESULTS} does not exist; use --collect")
        data = json.loads(RESULTS.read_text())
    render(data)


if __name__ == "__main__":
    main()
