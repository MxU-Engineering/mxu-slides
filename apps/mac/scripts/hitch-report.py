#!/usr/bin/env python3
"""Summarize an MxU Slides diagnostics bundle's main-thread evidence.

Usage:
  apps/mac/scripts/hitch-report.py <bundle folder | bundle .zip | breadcrumbs-*.log ...>
      [--utc-offset HOURS] [--demangle]

Reads the breadcrumbs-<day>.log files (and report.json when present) that
Help > Report a Problem bundles, and prints per day: hitch count and duration
buckets (a hitch of an hour or more is the Mac asleep and is only
counted), flags (perf.pulse cpu at or above 90% for two minutes or more in
a row, perf.spin runaway main threads, perf.bodyStorm redraw storms),
hitches by hour, the crumbs that precede hitches, perf.hitch.stack
lines grouped by their top app frame, perf.pass lines by run-loop mode and
by the document kinds opened, library.* storms and slow opens by kind,
menu.track summaries, and the launch lines' version / build / commit.
Python 3 standard library only.

Format notes: a line is "<ISO8601 UTC> <kind> — <detail>". The stack, pass
and library lines are parsed loosely (see the regexes below) so format
tweaks degrade to "?" instead of crashing.
"""

import argparse
import collections
import datetime
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import zipfile

LINE = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z) (.+?)(?: — (.*))?$")
DAY_FILE = re.compile(r"breadcrumbs-(\d{4}-\d{2}-\d{2})\.log$")
MS = re.compile(r"(\d+(?:\.\d+)?)\s*ms\b")
KIND_COUNT = re.compile(r"([A-Za-z][\w.-]*)\s*×\s*(\d+)|([A-Za-z][\w.-]*) x(\d+)\b")
OFFSET = re.compile(r"^(.*?)\s*\+\s*((?:0x)?[0-9a-fA-F]+)$")
MODE_NAMED = re.compile(r"\b(k?\w*RunLoop\w*Mode|NSEventTracking\w*|NSModalPanel\w*|NSConnectionReplyMode)\b")
MODE_FIELD = re.compile(r"\bmode[=: ]+([\w.-]+)")
MODE_WORD = re.compile(r"^\s*(default|tracking|eventTracking|modal|modalPanel|common)\b")
SQL = re.compile(r"\bsql[=: ]*(\d+)")

HITCH_BUCKETS = [
    ("<250 ms", lambda ms: ms < 250),
    ("250-500 ms", lambda ms: 250 <= ms < 500),
    ("500-1000 ms", lambda ms: 500 <= ms < 1000),
    ("1-3 s", lambda ms: 1000 <= ms <= 3000),
    (">3 s", lambda ms: ms > 3000),
]
SHORT_MODES = {
    "kCFRunLoopDefaultMode": "default",
    "NSDefaultRunLoopMode": "default",
    "NSEventTrackingRunLoopMode": "eventTracking",
    "NSModalPanelRunLoopMode": "modalPanel",
    "kCFRunLoopCommonModes": "common",
}

APP_MARKERS = (
    "MxU Slides", "MxU_Slides", "MxUSlides", "PresenterCore", "RenderEngine", "MediaEngine",
    "AudioEngine", "OutputEngine", "SlideScene", "LocalAPI", "MxUAPI", "ProImport", "PPTXImport",
    "NDIKit", "StreamEngine", "DeckLinkKit",
)

APP_IMAGES = ("MxU Slides", "MxU Slides.debug.dylib", "MxU Slides", "MxU Slides.debug.dylib")
PRECEDING_LINES = 3
PRECEDING_WINDOW = datetime.timedelta(seconds=30)

SLEEP_MS = 3_600_000

HOT_CPU = 90
HOT_PULSES = 2
PULSE_GAP = datetime.timedelta(seconds=90)
CPU = re.compile(r"\bcpu (\d+(?:\.\d+)?)%")
LASTED = re.compile(r"lasted (\d+(?:\.\d+)?) s")
STORM_VIEW = re.compile(r"\bview=([\w.]+) (\d+)/s")

class Crumb:
    __slots__ = ("at", "kind", "detail")

    def __init__(self, at, kind, detail):
        self.at = at
        self.kind = kind
        self.detail = detail

def parse_stamp(text):
    stamp = text.rstrip("Z").split(".")[0]
    return datetime.datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S")

def parse_lines(lines):
    crumbs = []
    for raw in lines:
        match = LINE.match(raw.rstrip("\n"))
        if match:
            crumbs.append(Crumb(parse_stamp(match.group(1)), match.group(2), match.group(3) or ""))
    return crumbs

def load(paths):
    """{day: [Crumb]} and report.json (or None) from folders, zips or logs."""
    days = collections.defaultdict(list)
    report = None
    for path in paths:
        if os.path.isdir(path):
            for name in sorted(os.listdir(path)):
                full = os.path.join(path, name)
                if DAY_FILE.search(name):
                    with open(full, encoding="utf-8", errors="replace") as handle:
                        days[DAY_FILE.search(name).group(1)].extend(parse_lines(handle))
                elif name == "report.json":
                    with open(full, encoding="utf-8") as handle:
                        report = json.load(handle)
        elif zipfile.is_zipfile(path):
            with zipfile.ZipFile(path) as archive:
                for name in sorted(archive.namelist()):
                    base = os.path.basename(name)
                    if DAY_FILE.search(base):
                        text = archive.read(name).decode("utf-8", errors="replace")
                        days[DAY_FILE.search(base).group(1)].extend(parse_lines(text.splitlines()))
                    elif base == "report.json":
                        report = json.loads(archive.read(name))
        else:
            match = DAY_FILE.search(os.path.basename(path))
            day = match.group(1) if match else os.path.basename(path)
            with open(path, encoding="utf-8", errors="replace") as handle:
                days[day].extend(parse_lines(handle))
    return days, report

def first_ms(text):
    match = MS.search(text)
    return float(match.group(1)) if match else None

def kind_counts(text):
    counts = collections.Counter()
    for match in KIND_COUNT.finditer(text):
        kind = match.group(1) or match.group(3)
        counts[kind] += int(match.group(2) or match.group(4))
    return counts

def run_loop_mode(text):
    named = MODE_NAMED.search(text)
    field = MODE_FIELD.search(text)
    word = MODE_WORD.search(text)
    if named:
        mode = named.group(1)
    elif field:
        mode = field.group(1)
    elif word:
        mode = word.group(1)
    else:
        mode = "?"
    return SHORT_MODES.get(mode, mode)

def is_app_frame(frame):
    return any(marker in frame for marker in APP_MARKERS)

def frame_key(frame):
    """Group key for a frame: symbol frames drop their offset; image+offset
    frames keep it (the offset is all that names the code)."""
    frame = frame.strip()
    match = OFFSET.match(frame)
    if match and match.group(1).strip() not in APP_IMAGES:
        key = match.group(1).strip()
    else:
        key = frame
    return key

def split_frames(detail):
    frames_text = detail.split("|", 1)[1] if "|" in detail else ""
    return [frame.strip() for frame in re.split(r"←|<-", frames_text) if frame.strip()]

def pct(part, whole):
    return f"{100 * part / whole:.0f}%" if whole else "-"

def median(values):
    return statistics.median(values) if values else None

def fmt_ms(value):
    return "?" if value is None else f"{value:.0f} ms"

def wrap(items, indent="    ", width=100):
    lines, current = [], indent
    for item in items:
        if len(current) + len(item) + 3 > width and current.strip():
            lines.append(current.rstrip(" ·"))
            current = indent
        current += item + " · "
    if current.strip():
        lines.append(current.rstrip(" ·"))
    return lines

def demangle(names):
    tool = shutil.which("swift-demangle")
    command = [tool] if tool else (["xcrun", "swift-demangle"] if shutil.which("xcrun") else None)
    mapping = {}
    if command and names:
        try:
            result = subprocess.run(
                command + ["--simplified"], input="\n".join(names), capture_output=True, text=True, timeout=30)
            demangled = result.stdout.splitlines()
            if result.returncode == 0 and len(demangled) == len(names):
                mapping = dict(zip(names, demangled))
        except (OSError, subprocess.SubprocessError):
            mapping = {}
    return mapping

def launches_section(crumbs):
    rows = collections.OrderedDict()
    for crumb in crumbs:
        if crumb.kind == "launch":
            version = re.search(r"\bv(\S+) \((\S+)\)", crumb.detail)
            commit = re.search(r"\bcommit (\S+)", crumb.detail)
            uuid = re.search(r"\buuid (\S+)", crumb.detail)
            key = (
                f"v{version.group(1)} ({version.group(2)})" if version else "v?",
                commit.group(1).rstrip(",") if commit else "(not recorded)",
                uuid.group(1).rstrip(",") if uuid else None,
            )
            rows.setdefault(key, []).append(crumb.at)
    lines = []
    for (version, commit, uuid), times in rows.items():
        image = f", image uuid {uuid}" if uuid else ""
        stamps = ", ".join(at.strftime("%H:%MZ") for at in times[:6]) + (" …" if len(times) > 6 else "")
        lines.append(f"  launches: {len(times)} × {version} commit {commit}{image} ({stamps})")
    return lines or ["  launches: none"]

def flags_section(crumbs):
    """What must not pass as "the app felt slow": sustained CPU, runaway
    main threads, redraw storms."""
    lines = hot_cpu_lines(crumbs) + spin_lines(crumbs) + storm_lines(crumbs)
    return ["  flags:"] + lines if lines else ["  flags: none"]

def hot_cpu_lines(crumbs):
    runs, run = [], []
    for crumb in crumbs:
        if crumb.kind != "perf.pulse":
            continue
        match = CPU.search(crumb.detail)
        cpu = float(match.group(1)) if match else None
        hot = cpu is not None and cpu >= HOT_CPU
        if hot and run and crumb.at - run[-1][0].at <= PULSE_GAP:
            run.append((crumb, cpu))
        else:
            if len(run) >= HOT_PULSES:
                runs.append(run)
            run = [(crumb, cpu)] if hot else []
    if len(run) >= HOT_PULSES:
        runs.append(run)
    return [
        f"    FLAG cpu >= {HOT_CPU}% for {len(run)} pulses in a row"
        f" ({run[0][0].at.strftime('%H:%MZ')}-{run[-1][0].at.strftime('%H:%MZ')}), peak {max(cpu for _, cpu in run):.0f}%"
        for run in runs
    ]

def spin_lines(crumbs):
    spins = [crumb for crumb in crumbs if crumb.kind == "perf.spin"]
    ends = [crumb for crumb in crumbs if crumb.kind == "perf.spin.end"]
    if not spins and not ends:
        return []
    lasted = [float(match.group(1)) for match in (LASTED.search(crumb.detail) for crumb in ends) if match]
    frames = collections.Counter()
    for crumb in spins:
        app = next((frame for frame in split_frames(crumb.detail) if is_app_frame(frame)), None)
        frames[frame_key(app) if app else "(no app frame)"] += 1
    total = f", {sum(lasted):.0f} s in all, longest {max(lasted):.0f} s" if lasted else ""
    lines = [f"    FLAG perf.spin: {len(spins)} runaway main thread{'' if len(spins) == 1 else 's'}{total}"]
    lines.extend(f"      {count:>5}  {key}" for key, count in frames.most_common(6))
    return lines

def storm_lines(crumbs):
    views = collections.Counter()
    worst = {}
    for crumb in crumbs:
        if crumb.kind == "perf.bodyStorm":
            match = STORM_VIEW.search(crumb.detail)
            view = match.group(1) if match else "?"
            views[view] += 1
            worst[view] = max(worst.get(view, 0), int(match.group(2)) if match else 0)
    if not views:
        return []
    by_view = ", ".join(f"{view} {count} (worst {worst[view]}/s)" for view, count in views.most_common())
    return [f"    FLAG perf.bodyStorm: {sum(views.values())} by view: {by_view}"]

def hitch_section(crumbs, offset):
    found = [(index, crumb, first_ms(crumb.detail)) for index, crumb in enumerate(crumbs) if crumb.kind == "perf.hitch"]
    hitches = [hitch for hitch in found if hitch[2] is None or hitch[2] < SLEEP_MS]
    if hitches:
        lines = hitch_lines(crumbs, hitches, offset)
    else:
        lines = ["  hitches: none"]
    sleeps = len(found) - len(hitches)
    if sleeps:
        lines.append(f"  left out as sleep (1 h or longer): {sleeps}")
    return lines, hitches

def hitch_lines(crumbs, hitches, offset):
    values = [ms for _, _, ms in hitches if ms is not None]
    lines = [f"  hitches: {len(hitches)}, blocked {sum(values) / 1000:.1f} s total, worst {fmt_ms(max(values) if values else None)}"]
    for label, test in HITCH_BUCKETS:
        count = sum(1 for ms in values if test(ms))
        if count or label != "<250 ms":
            lines.append(f"    {label:<12}{count:>6}  {pct(count, len(values))}")
    by_hour = collections.Counter((crumb.at + offset).hour for _, crumb, _ in hitches)
    lines.append(f"  hitches by hour ({offset_label(offset)}):")
    lines.extend(wrap([f"{hour:02d}h {count}" for hour, count in sorted(by_hour.items())]))
    preceding = collections.Counter()
    for index, crumb, _ in hitches:
        seen, cursor = set(), index - 1
        while cursor >= 0 and len(seen) < PRECEDING_LINES and crumb.at - crumbs[cursor].at <= PRECEDING_WINDOW:
            if not crumbs[cursor].kind.startswith("perf."):
                seen.add(crumbs[cursor].kind)
            cursor -= 1
        preceding.update(seen if seen else {"(nothing within 30 s)"})
    lines.append(f"  crumbs before hitches (up to {PRECEDING_LINES} non-perf lines within 30 s; share of hitches):")
    for kind, count in sorted(preceding.items(), key=lambda item: (-item[1], item[0]))[:8]:
        lines.append(f"    {kind:<34}{count:>6}  {pct(count, len(hitches))}")
    return lines

def stacks_section(crumbs, names):
    stacks = [crumb for crumb in crumbs if crumb.kind == "perf.hitch.stack"]
    if stacks:
        lines = stack_lines(stacks, names)
    else:
        lines = ["  perf.hitch.stack: none"]
    return lines

def stack_lines(stacks, names):
    groups = {}
    modes = collections.Counter()
    for crumb in stacks:
        head = crumb.detail.split("|", 1)[0]
        mode, ms = run_loop_mode(head), first_ms(head)
        modes[mode] += 1
        frames = split_frames(crumb.detail)
        app = next((frame for frame in frames if is_app_frame(frame)), None)
        if app:
            key = frame_key(app)
        elif frames:
            key = "(no app frame) " + frame_key(frames[0])
        else:
            key = "(no frames)"
        group = groups.setdefault(key, {"count": 0, "worst": 0.0, "modes": collections.Counter()})
        group["count"] += 1
        group["worst"] = max(group["worst"], ms or 0.0)
        group["modes"][mode] += 1
    lines = [f"  perf.hitch.stack: {len(stacks)} ({', '.join(f'{mode} {count}' for mode, count in modes.most_common())})"]
    lines.append("    by top app frame:")
    for key, group in sorted(groups.items(), key=lambda item: -item[1]["count"])[:12]:
        mode_text = " ".join(f"{mode}×{count}" for mode, count in group["modes"].most_common())
        lines.append(f"      {group['count']:>5}  worst {group['worst']:.0f} ms  [{mode_text}]  {names.get(key, key)}")
    return lines

def passes_section(crumbs):
    passes = [crumb for crumb in crumbs if crumb.kind == "perf.pass"]
    if passes:
        lines = pass_lines(passes)
    else:
        lines = ["  perf.pass: none"]
    return lines

def pass_lines(passes):
    by_mode = collections.defaultdict(list)
    opens = collections.Counter()
    passes_with = collections.Counter()
    sql = []
    for crumb in passes:
        by_mode[run_loop_mode(crumb.detail)].append(first_ms(crumb.detail) or 0.0)
        counts = kind_counts(crumb.detail)
        opens.update(counts)
        passes_with.update(counts.keys())
        match = SQL.search(crumb.detail)
        if match:
            sql.append(int(match.group(1)))
    lines = [f"  perf.pass: {len(passes)}" + (f", sql per pass median {median(sql):.0f} max {max(sql)}" if sql else "")]
    lines.append("    by mode:")
    for mode, values in sorted(by_mode.items(), key=lambda item: -len(item[1])):
        lines.append(f"      {mode:<16}{len(values):>6}  median {fmt_ms(median(values))}  worst {fmt_ms(max(values))}")
    lines.append("    by opens kind:")
    if opens:
        lines.extend(wrap(indent="      ", items=[
            f"{kind}×{count} in {passes_with[kind]} pass{'' if passes_with[kind] == 1 else 'es'}"
            for kind, count in opens.most_common(12)]))
    else:
        lines.append("      (no opens named)")
    return lines

def library_section(crumbs):
    events = collections.defaultdict(lambda: {"lines": 0, "kinds": collections.Counter(), "opens": collections.Counter()})
    for crumb in crumbs:
        if crumb.kind.startswith("library."):
            event = events[crumb.kind]
            event["lines"] += 1
            counts = kind_counts(crumb.detail)
            if counts:
                event["kinds"][counts.most_common(1)[0][0]] += 1
                event["opens"].update(counts)
            else:
                match = re.search(r"\bkind[=: ]+([\w-]+)", crumb.detail) or re.search(r"([A-Za-z][\w-]*)/", crumb.detail)
                event["kinds"][match.group(1) if match else "?"] += 1
    lines = []
    for name, event in sorted(events.items()):
        kinds = ", ".join(f"{kind} {count}" for kind, count in event["kinds"].most_common(8))
        opens = " (opens " + " ".join(f"{kind}×{count}" for kind, count in event["opens"].most_common(8)) + ")" if event["opens"] else ""
        lines.append(f"  {name}: {event['lines']} by kind: {kinds}{opens}")
    return lines or ["  library.storm / library.slowOpen: none"]

def menus_section(crumbs):
    menus = [crumb.detail for crumb in crumbs if crumb.kind == "menu.track"]
    if menus:
        lines = menu_lines(menus)
    else:
        lines = ["  menu.track: none"]
    return lines

def menu_lines(menus):
    durations, opened, submenu_after, gaps = [], [], [], []
    no_submenu = hovered = hovered_stuck = reporting_hover = late = hitches = 0
    for detail in menus:
        duration = re.search(r"(\d+(?:\.\d+)?) s\b", detail)
        peak = re.search(r"menu windows peak (\d+)", detail)
        click = re.search(r"opened after (\d+) ms", detail)
        shown = re.search(r"submenu after (\d+) ms", detail)
        hover = re.search(r"hovered submenu item: (yes|no)", detail)
        gap = re.search(r"longest tick gap (\d+) ms", detail)
        late_ticks = re.search(r"late ticks (\d+)", detail)
        hitch = re.search(r"hitches (\d+)", detail)
        if duration:
            durations.append(float(duration.group(1)))
        opened_submenu = bool(shown) or (peak is not None and int(peak.group(1)) >= 2)
        no_submenu += 0 if opened_submenu else 1
        if click:
            opened.append(int(click.group(1)))
        if shown:
            submenu_after.append(int(shown.group(1)))
        if hover:
            reporting_hover += 1
            hovered += hover.group(1) == "yes"
            hovered_stuck += hover.group(1) == "yes" and not opened_submenu
        if gap:
            gaps.append(int(gap.group(1)))
        late += int(late_ticks.group(1)) if late_ticks else 0
        hitches += int(hitch.group(1)) if hitch else 0
    lines = [
        f"  menu.track: {len(menus)} menus, median up {median(durations) or 0:.2f} s, hitches while up {hitches}",
        f"    never showed a submenu: {no_submenu} of {len(menus)}"
        + (f"; submenu after median {fmt_ms(median(submenu_after))}" if submenu_after else ""),
    ]
    if reporting_hover:
        lines.append(
            f"    open latency: median {fmt_ms(median(opened))} worst {fmt_ms(max(opened) if opened else None)}"
            f" ({len(opened)} of {reporting_hover} with a click)")
        lines.append(
            f"    hovered a submenu item: {hovered} of {reporting_hover}; hovered but no submenu: {hovered_stuck}")
        lines.append(f"    longest tick gap: median {fmt_ms(median(gaps))} worst {fmt_ms(max(gaps) if gaps else None)}, late ticks {late}")
    else:
        lines.append("    open latency / hover / tick gap: not in these lines (build predates them)")
    return lines

def offset_label(offset):
    hours = offset.total_seconds() / 3600
    return "UTC" if hours == 0 else f"UTC{hours:+g}"

def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("paths", nargs="+", help="bundle folder, bundle .zip, or breadcrumbs-<day>.log files")
    parser.add_argument("--utc-offset", type=float, default=0, help="hours to shift the by-hour table (e.g. -4)")
    parser.add_argument("--demangle", action="store_true", help="demangle Swift frames with swift-demangle")
    args = parser.parse_args(argv)
    offset = datetime.timedelta(hours=args.utc_offset)

    days, report = load(args.paths)
    if days:
        print_report(args, days, report, offset)
        status = 0
    else:
        print("no breadcrumbs-<day>.log found in " + ", ".join(args.paths))
        status = 1
    return status

def print_report(args, days, report, offset):
    print("MxU Slides hitch report — " + ", ".join(args.paths))
    info = (report or {}).get("system_info", {})
    if report is not None:
        print(
            f"report.json: app_version {info.get('app_version', '?')}, app_build {info.get('app_build', '?')},"
            f" app_commit {info.get('app_commit', '(not recorded)')}")
    names = {}
    if args.demangle:
        keys = sorted({frame_key(frame) for crumbs in days.values() for crumb in crumbs
                       if crumb.kind == "perf.hitch.stack" for frame in split_frames(crumb.detail)})
        names = demangle(keys)

    all_hitches, all_crumbs = 0, 0
    for day in sorted(days):
        crumbs = sorted(days[day], key=lambda crumb: crumb.at)
        all_crumbs += len(crumbs)
        print()
        print(f"== {day} ({len(crumbs)} crumbs)")
        lines = launches_section(crumbs)
        lines += flags_section(crumbs)
        hitch_lines, hitches = hitch_section(crumbs, offset)
        all_hitches += len(hitches)
        lines += hitch_lines
        lines += stacks_section(crumbs, names)
        lines += passes_section(crumbs)
        lines += library_section(crumbs)
        lines += menus_section(crumbs)
        print("\n".join(lines))
    print()
    print(f"== all days: {len(days)} days, {all_crumbs} crumbs, {all_hitches} hitches")

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
