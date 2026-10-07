#!/usr/bin/env python3
"""Turn a perf check run folder into numbers, a table and a verdict.

  analyze.py <run folder> [baseline.json]

The run folder is what run.sh leaves: steps.jsonl (one JSON object per
measured step: its sample file, its breadcrumb window), the `sample` call
graphs, and the sandbox home's Diagnostics/breadcrumbs-*.log. Prints a
table, writes results.json into the folder, and exits 1 when a metric is
over its threshold in baseline.json (default: the one beside this script).
When the baseline carries `metrics` (a saved results.json, or the committed
reference run), the table shows them side by side.

"Busy" is main-thread samples not parked in the run loop's mach_msg wait
(`__CFRunLoopServiceMachPort`): the same measure as the 2026-09-24 numbers.
Python 3 standard library only.
"""

import collections
import datetime
import glob
import json
import os
import re
import sys

FRAME = re.compile(r"^(\s*[+!:| ]*?)(\d+)\s+(\S.*)$")
THREAD = re.compile(r"^    (\d+) (Thread_\S+)(.*)$")
IDLE = ("__CFRunLoopServiceMachPort",)
RENDER_IDLE = ("__CFRunLoopServiceMachPort", "__psynch_cvwait")

DECODE = re.compile(r"ReplicaParts\.decoding|DocumentStore\.loadValues|DocumentStore\.loadReplicaParts|DocumentStore\.decode\b|deckBundles")
CRUMB = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(?:\.\d+)?Z (\S+)(?: — (.*))?$")
PASS_MS = re.compile(r"(\d+(?:\.\d+)?) ms\b")

def threads(path):
    """[(header, total samples, [(depth, count, symbol)])] per thread."""
    found = []
    current = None
    with open(path, encoding="utf-8", errors="replace") as handle:
        in_graph = False
        for line in handle:
            line = line.rstrip("\n")
            if line.startswith("Call graph:"):
                in_graph = True
                continue
            if not in_graph:
                continue
            if not line.strip() or line.startswith("Total number in stack"):
                if current:
                    found.append(current)
                    current = None
                if line.startswith("Total number in stack"):
                    break
                continue
            header = THREAD.match(line)
            if header:
                if current:
                    found.append(current)
                current = (header.group(2) + header.group(3), int(header.group(1)), [])
                continue
            frame = FRAME.match(line)
            if frame and current:
                current[2].append((len(frame.group(1)), int(frame.group(2)), frame.group(3)))
    if current:
        found.append(current)
    return found

def is_main(header):
    return "Main Thread" in header or "com.apple.main-thread" in header

def busy(thread, idle=IDLE):
    """Percent of the thread's samples not under an idle frame."""
    _, total, frames = thread
    parked = sum(count for _, count, symbol in frames if symbol.startswith(idle))
    return 100.0 * (total - parked) / total if total else 0.0

def outermost(frames, pattern):
    """Samples under frames matching `pattern`, counting each subtree once."""
    total, inside = 0, None
    for depth, count, symbol in frames:
        if inside is not None and depth > inside:
            continue
        inside = None
        if pattern.search(symbol):
            total += count
            inside = depth
    return total

def main_busy(path):
    main = next((thread for thread in threads(path) if is_main(thread[0])), None)
    return round(busy(main), 1) if main else None

def thread_busy(path, name):
    thread = next((thread for thread in threads(path) if name in thread[0]), None)
    return round(busy(thread, RENDER_IDLE), 1) if thread else None

def decode_samples(path):
    return sum(outermost(frames, DECODE) for header, _, frames in threads(path) if not is_main(header))

def crumbs(folder):
    lines = []
    for path in sorted(glob.glob(os.path.join(folder, "breadcrumbs-*.log"))):
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                match = CRUMB.match(line.rstrip("\n"))
                if match:
                    stamp = datetime.datetime.strptime(match.group(1), "%Y-%m-%dT%H:%M:%S")
                    lines.append((stamp, match.group(2), match.group(3) or ""))
    return lines

def stamp(text):
    return datetime.datetime.strptime(text.rstrip("Z").split(".")[0], "%Y-%m-%dT%H:%M:%S")

def within(lines, kind, start, end):
    """Crumbs of `kind` from `start` to `end` (a second either side: the
    stamps are whole seconds)."""
    low, high = stamp(start) - datetime.timedelta(seconds=1), stamp(end) + datetime.timedelta(seconds=1)
    return [detail for at, name, detail in lines if name == kind and low <= at <= high]

def passes(lines, start, end):
    values = []
    for detail in within(lines, "perf.pass", start, end):
        match = PASS_MS.search(detail)
        if match:
            values.append(float(match.group(1)))
    return values

def bodies(detail):
    """`bodies ShellView 3 LibrarySidebar 12` → {name: count}."""
    words = detail.split()[1:]
    return {words[index]: int(words[index + 1]) for index in range(0, len(words) - 1, 2) if words[index + 1].isdigit()}

def analyze(folder):
    steps = []
    with open(os.path.join(folder, "steps.jsonl")) as handle:
        steps = [json.loads(line) for line in handle if line.strip()]
    info = next((step for step in steps if step["step"] == "run"), {})
    detail = collections.defaultdict(list)
    for step in steps:
        name = step["step"]
        if name == "run":
            continue
        record = dict(step)
        sample = os.path.join(folder, step["sample"]) if step.get("sample") else None
        if sample and os.path.exists(sample):
            record["mainBusy"] = main_busy(sample)
            record["decodeSamples"] = decode_samples(sample)
            record["renderBusy"] = thread_busy(sample, "RenderEngine.RenderThread")
        home = step.get("diagnostics")
        if home and step.get("from"):
            lines = crumbs(os.path.join(folder, home))
            record["passes"] = passes(lines, step["from"], step["to"])
            marks = within(lines, "perf.mark", step["to"], step["to"])
            if marks:
                record["bodies"] = bodies(marks[-1])
            record["spins"] = len(within(lines, "perf.spin", step["from"], step["to"]))
            record["storms"] = within(lines, "perf.bodyStorm", step["from"], step["to"])
        detail[name].append(record)
    return info, dict(detail), metrics(detail)

def metrics(detail):
    values = {}

    def first(name, key):
        records = detail.get(name) or []
        return records[0].get(key) if records else None

    values["animateIdle.mainBusy"] = first("animateIdle", "mainBusy")
    values["playback.mainBusy"] = first("playback", "mainBusy")
    playback = (detail.get("playback") or [{}])[0]
    seconds = playback.get("seconds") or 0
    if seconds and "bodies" in playback:
        values["playback.timelineBodiesPerSecond"] = round(
            playback["bodies"].get("AnimationTimelinePanel", 0) / seconds, 1)
    values["render.renderBusy"] = first("render", "renderBusy")
    drags = detail.get("drag") or []
    if drags:
        values["drag.firstLongestPass"] = max(drags[0].get("passes") or [0])
        later = drags[1:]
        if later:
            values["drag.laterLongestPass"] = max(max(record.get("passes") or [0]) for record in later)
            values["drag.laterPassesOver100"] = max(len(record.get("passes") or []) for record in later)
            values["drag.laterMainBusy"] = round(sum(record.get("mainBusy") or 0 for record in later) / len(later), 1)
            values["drag.laterDecodeSamples"] = sum(record.get("decodeSamples") or 0 for record in later)
    resizes = detail.get("resize") or []
    if resizes:
        values["resize.longestPass"] = max(max(record.get("passes") or [0]) for record in resizes)
        values["resize.mainBusy"] = round(sum(record.get("mainBusy") or 0 for record in resizes) / len(resizes), 1)
    spins = sum(record.get("spins") or 0 for records in detail.values() for record in records)
    values["alarms.spins"] = spins
    values["alarms.storms"] = sum(len(record.get("storms") or []) for records in detail.values() for record in records)
    return {key: value for key, value in values.items() if value is not None}

def verdict(values, baseline):
    """[(metric, value, reference, limit, ok)] and whether all are ok."""
    limits = baseline.get("thresholds", {})
    reference = baseline.get("metrics", {})
    rows, passed = [], True
    for key in sorted(set(values) | set(limits)):
        value = values.get(key)
        limit = limits.get(key)
        ok = value is None and limit is None or (limit is None or (value is not None and value <= limit))
        passed = passed and ok
        rows.append((key, value, reference.get(key), limit, ok))
    return rows, passed

def table(rows):
    def show(value):
        return "-" if value is None else (f"{value:g}" if isinstance(value, (int, float)) else str(value))
    lines = [f"{'metric':<34}{'this run':>10}{'baseline':>10}{'limit':>8}  "]
    for key, value, reference, limit, ok in rows:
        lines.append(f"{key:<34}{show(value):>10}{show(reference):>10}{show(limit):>8}  {'ok' if ok else 'OVER'}")
    return "\n".join(lines)

def main(argv):
    if not argv or len(argv) > 2:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    folder = argv[0]
    baseline_path = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "baseline.json")
    with open(baseline_path) as handle:
        baseline = json.load(handle)
    info, detail, values = analyze(folder)
    rows, passed = verdict(values, baseline)
    result = {"run": info, "metrics": values, "steps": detail, "passed": passed, "baseline": os.path.abspath(baseline_path)}
    with open(os.path.join(folder, "results.json"), "w") as handle:
        json.dump(result, handle, indent=1, default=str)
    print(f"MxU Slides perf check: {info.get('label', '?')} ({info.get('commit', '?')}) on {info.get('machine', '?')}")
    print(table(rows))
    print(("PASS" if passed else "FAIL") + f" — results: {os.path.join(folder, 'results.json')}")
    return 0 if passed else 1

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
