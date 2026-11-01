#!/usr/bin/env python3
"""Write Sources/Credits.rtf: the third-party notices MxU Slides ships with.

Usage:
  apps/mac/scripts/acknowledgements.py           # regenerate (dev Mac)
  apps/mac/scripts/acknowledgements.py --check   # offline coverage check (CI)

The standard About panel shows a bundle's Credits.rtf on its own, so the
notices BSD/MIT/Apache/MPL ask for in "documentation or other materials
provided with the distribution" live there. Every text comes from the
license files themselves, never retyped:

- Swift packages: every remote package in project.yml and
  Packages/*/Package.resolved, read from Xcode's checkouts (build the app
  once first), plus the libsrt (MPL-2.0, with OpenSSL inside) that
  SRTHaishinKit links as a binary.
- Vendored code: every *LICENSE* file under Packages/, and the DeckLink
  SDK notice.
- Rust: the crates statically linked into yffiFFI (YjsKit) and
  automergeFFI (automerge-swift), at the pins those packages build from,
  via cargo tree (normal deps, no proc-macros) and the crates' own files.
- NDI: the redist's libndi_licenses.txt ("should be included with all
  distribution") and the About-box trademark line the NDI SDK requires.

Regenerating needs the network, cargo, Xcode's package checkouts and the
NDI SDK. --check needs none of them: it fails when a remote package, a
vendored license or a Rust pin is missing from the committed Credits.rtf.
Python 3 standard library only.
"""

import argparse
import collections
import glob
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # apps/mac
OUT = os.path.join(ROOT, "Sources", "Credits.rtf")
NDI_SDK = "/Library/NDI SDK for Apple"
NDI_TRADEMARK = "NDI® is a registered trademark of Vizrt NDI AB."
NDI_URL = "https://ndi.video/"
DECKLINK_SOURCE = "Packages/DeckLinkKit/Sources/CDeckLink/Vendor/DeckLinkAPIDispatch.cpp"
RUST_TARGET = "aarch64-apple-darwin"
DECORATION = r"\s*[*=_-]{3,}\s*"
# Names for vendored license files whose folder name says nothing.
VENDORED_NAMES = {
    "Packages/StreamEngine/Sources/StreamEngine/HLS/Vendored/VendoredLICENSE.md": "HaishinKit (HLS writer vendored in StreamEngine)",
    "Packages/SyphonKit/Sources/Syphon/VendoredLICENSE.txt": "Syphon (vendored in SyphonKit)",
}


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def fetch(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read().decode("utf-8")


def run(args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, capture_output=True, text=True).stdout


# What the binary ships, as the --check side sees it (offline).

def remote_packages():
    """{repo name: URL} of every remote Swift package, direct or transitive."""
    urls = re.findall(r"^\s+url:\s*(\S+)", read(os.path.join(ROOT, "project.yml")), re.M)
    for resolved in glob.glob(os.path.join(ROOT, "Packages", "*", "Package.resolved")):
        urls += [pin["location"] for pin in json.loads(read(resolved))["pins"]]
    urls = {re.sub(r"\.git$", "", url.rstrip("/")) for url in urls}
    return {url.rsplit("/", 1)[-1]: url for url in sorted(urls, key=lambda u: u.rsplit("/", 1)[-1].lower())}


def vendored_licenses():
    paths = glob.glob(os.path.join(ROOT, "Packages", "**", "*LICENSE*"), recursive=True)
    paths = [os.path.relpath(p, ROOT) for p in paths if "/.build/" not in p and os.path.isfile(p)]
    return sorted(paths)


def decklink_notice():
    text = read(os.path.join(ROOT, DECKLINK_SOURCE))
    body = text.split("-LICENSE-START-", 1)[1].split("-LICENSE-END-", 1)[0]
    return "\n".join(re.sub(r"^\*\* ?", "", line).rstrip() for line in body.strip().splitlines()).strip()


def rust_pins():
    """(name, git URL, tag, cargo -p) for each Rust library linked in."""
    yffi = read(os.path.join(ROOT, "Packages/YjsKit/scripts/build-yffi-xcframework.sh"))
    automerge = read(os.path.join(ROOT, "Packages/automerge-swift/Package.swift"))
    return [
        ("y-crdt", "https://github.com/y-crdt/y-crdt.git", re.search(r"^YCRDT_TAG=(\S+)", yffi, re.M).group(1), "yffi", ""),
        ("automerge-swift", "https://github.com/automerge/automerge-swift.git",
         re.search(r"automerge-swift/releases/download/([^/]+)/", automerge).group(1), "uniffi_automerge", "rust"),
    ]


# Regeneration (dev Mac).

def checkouts_dir():
    found = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/MxUSlides-*/SourcePackages"))
    if not found:
        sys.exit("No MxUSlides package checkouts in DerivedData: build the app in Xcode once, then rerun.")
    return max(found, key=os.path.getmtime)


def license_files(directory):
    names = sorted(os.listdir(directory))
    return [os.path.join(directory, n) for n in names
            if re.match(r"(?i)^(licen[cs]e|copying|notice|unlicense)", n) and os.path.isfile(os.path.join(directory, n))]


def swift_package_entries(source_packages):
    entries = []
    for name, url in remote_packages().items():
        checkout = os.path.join(source_packages, "checkouts", name)
        if not os.path.isdir(checkout):
            sys.exit(f"{name} is not in {checkout}: build the app in Xcode once, then rerun.")
        version = subprocess.run(["git", "-C", checkout, "describe", "--tags"], capture_output=True, text=True).stdout.strip()
        files = license_files(checkout)
        if not files:
            sys.exit(f"{name} has no license file in {checkout}.")
        entries.append((f"{name} {version}".strip(), url, "\n\n".join(read(f).strip() for f in files)))
    # SRTHaishinKit links libsrt.a, a binary target with OpenSSL built in.
    haishinkit = read(os.path.join(source_packages, "checkouts", "HaishinKit.swift", "Package.swift"))
    srt = re.search(r"libsrt-xcframework/releases/download/v([\d.]+)/", haishinkit).group(1)
    libsrt = glob.glob(os.path.join(source_packages, "artifacts", "haishinkit.swift", "libsrt", "*", "macos-*", "libsrt.a"))[0]
    openssl = re.search(rb"OpenSSL (\d+\.\d+\.\d+)", open(libsrt, "rb").read()).group(1).decode()
    entries.append((f"SRT {srt} (in HaishinKit's libsrt)", "https://github.com/Haivision/srt",
                    f"Source code: https://github.com/Haivision/srt/tree/v{srt}\n\n"
                    + fetch(f"https://raw.githubusercontent.com/Haivision/srt/v{srt}/LICENSE").strip()))
    entries.append((f"OpenSSL {openssl} (in HaishinKit's libsrt)", "https://www.openssl.org",
                    fetch(f"https://raw.githubusercontent.com/openssl/openssl/openssl-{openssl}/LICENSE.txt").strip()))
    return entries


def pick_license_files(directory, expression):
    """The crate's files for one license it offers (MIT first, then the others)."""
    files = license_files(directory)
    options = [o.strip("() ") for o in re.split(r"\s+OR\s+|/", expression)] if " AND " not in expression else []
    for choice in ("MIT", "BSL-1.0", "Zlib", "0BSD", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "MPL-2.0"):
        if choice not in options:
            continue
        key = {"BSL-1.0": "boost", "Apache-2.0": "apache", "MPL-2.0": ""}.get(choice, choice.lower())
        matching = [f for f in files if key in os.path.basename(f).lower()]
        if choice == "Apache-2.0":
            matching += [f for f in files if "notice" in os.path.basename(f).lower()]
        if matching:
            return matching
        if len(options) == 1 or choice == "MPL-2.0":
            return files
    return files


def repository_license(crate):
    repo = re.match(r"https://github\.com/([^/]+/[^/.]+)", crate.get("repository") or "")
    for name in ("LICENSE", "LICENSE.md", "LICENSE-MIT") if repo else ():
        try:
            return fetch(f"https://raw.githubusercontent.com/{repo.group(1)}/HEAD/{name}").strip()
        except OSError:
            continue
    sys.exit(f"Rust crate {crate['name']} {crate['version']} ({crate.get('license')}) has no license file.")


def rust_entries(work):
    entries = []
    for name, url, tag, package, subdir in rust_pins():
        source = os.path.join(work, name)
        subprocess.run(["git", "-c", "advice.detachedHead=false", "clone", "--quiet", "--depth", "1", "--branch", tag, url, source],
                       check=True)
        manifest_dir = os.path.join(source, subdir)
        tree = run(["cargo", "tree", "--locked", "-p", package, "-e", "normal,no-proc-macro", "--target", RUST_TARGET,
                    "--prefix", "none", "--format", "{p}"], cwd=manifest_dir)
        linked = {tuple(line.split()[:2]) for line in tree.splitlines() if line.strip()}
        metadata = json.loads(run(["cargo", "metadata", "--locked", "--format-version", "1"], cwd=manifest_dir))
        for crate in sorted(metadata["packages"], key=lambda c: (c["name"], c["version"])):
            # The repo's own crates are the "{name} {tag}" entry below.
            if (crate["name"], "v" + crate["version"]) not in linked or crate["source"] is None:
                continue
            files = pick_license_files(os.path.dirname(crate["manifest_path"]), crate.get("license") or "")
            if files:
                text = "\n\n".join(read(f).strip() for f in files)
            else:  # some crates publish without one: their repository's
                text = repository_license(crate)
            if crate.get("license") == "MPL-2.0":
                text = f"Source code: {crate.get('repository') or 'https://crates.io/crates/' + crate['name']}\n\n" + text
            entries.append((f"{crate['name']} {crate['version']}", "", text))
        entries.append((f"{name} {tag}", re.sub(r"\.git$", "", url), read(os.path.join(source, "LICENSE")).strip()))
    # Both static libraries carry their own copy of Rust's standard library.
    entries.append(("Rust standard library", "https://github.com/rust-lang/rust",
                    fetch("https://raw.githubusercontent.com/rust-lang/rust/master/LICENSE-MIT").strip()))
    return entries


def generate():
    ndi_version = read(os.path.join(NDI_SDK, "Version.txt")).split()[-1]
    entries = [(f"NDI® SDK {ndi_version}", NDI_URL, read(os.path.join(NDI_SDK, "lib/macOS/libndi_licenses.txt")).strip())]
    entries += swift_package_entries(checkouts_dir())
    entries += [(VENDORED_NAMES.get(p, os.path.basename(os.path.dirname(p))), "", read(os.path.join(ROOT, p)).strip())
                for p in vendored_licenses()]
    entries.append(("Blackmagic Design DeckLink SDK", "https://www.blackmagicdesign.com/desktopvideo_sdk", decklink_notice()))
    with tempfile.TemporaryDirectory() as work:
        entries += rust_entries(work)

    # One section per distinct text, naming everything that uses it.
    groups = collections.OrderedDict()
    for title, url, text in entries:
        key = normalized(text)
        groups.setdefault(key, ([], text))[0].append((title, url))

    out = [r"{\rtf1\ansi\ansicpg1252\cocoartf2822" "\n" r"{\fonttbl\f0\fswiss\fcharset0 Helvetica;}" "\n"
           r"\pard\ql\sa160\f0\fs22 "]
    out.append(rtf_text("MxU Slides includes the third-party software below. Thank you to everyone who made it.") + r"\par" "\n")
    out.append(r"{\b " + rtf_text(NDI_TRADEMARK) + "} " + rtf_link(NDI_URL) + r"\par" "\n")
    for users, text in groups.values():
        titles = [title for title, _ in users]
        names = "; ".join(t for t in titles if not any(o.startswith(t + " ") for o in titles))
        out.append(r"\pard\ql\sb240\sa80\fs24{\b " + rtf_text(names) + r"}\par" "\n")
        for _, url in users:
            if url:
                out.append(r"\pard\ql\sa80\fs20 " + rtf_link(url) + r"\par" "\n")
        out.append(r"\pard\ql\sa120\fs20 " + "".join(rtf_text(p) + r"\par" "\n" for p in paragraphs(text)))
    out.append("}\n")
    with open(OUT, "w", encoding="ascii") as f:
        f.write("".join(out))
    print(f"Wrote {os.path.relpath(OUT, ROOT)}: {len(groups)} sections, {len(entries)} components.")


def paragraphs(text):
    """License text reflowed for a narrow panel: hard-wrapped lines join,
    while list items, copyright lines, indent changes and short lines keep
    their breaks.
    Rules of *** / === / --- are dropped."""
    for block in re.split(r"\n\s*\n", text.replace("\r\n", "\n").strip()):
        lines = [line.rstrip() for line in block.splitlines() if not re.fullmatch(DECORATION, line)]
        if not lines:
            continue
        out = lines[0].strip()
        for previous, line in zip(lines, lines[1:]):
            indent = lambda text: len(text) - len(text.lstrip())
            keep = (len(previous.strip()) < 40 or indent(line) != indent(previous)
                    or re.match(r"\s*([*\u2022-]|\d+\.|\(|[a-z]\)|Copyright)", line))
            out += ("\n" if keep else " ") + line.strip()
        yield out


def normalized(text):
    return re.sub(r"\s+", " ", "\n".join(line for line in text.splitlines() if not re.fullmatch(DECORATION, line))).strip()


def rtf_text(text):
    out = []
    for ch in text.replace("\r\n", "\n"):
        code = ord(ch)
        if ch in "\\{}":
            out.append("\\" + ch)
        elif ch == "\n":
            out.append("\\line ")
        elif ch == "\t":
            out.append("\\tab ")
        elif code < 0x20:
            continue
        elif code < 0x80:
            out.append(ch)
        elif code < 0x10000:
            out.append("\\u%d?" % (code - 0x10000 if code > 0x7FFF else code))
        else:  # UTF-16 surrogate pair
            code -= 0x10000
            out.append("\\u%d?\\u%d?" % ((0xD800 + (code >> 10)) - 0x10000, (0xDC00 + (code & 0x3FF)) - 0x10000))
    return "".join(out)


def rtf_link(url):
    return r'{\field{\*\fldinst{HYPERLINK "%s"}}{\fldrslt %s}}' % (url, rtf_text(url))


def check():
    plain = normalized(subprocess.run(["textutil", "-convert", "txt", "-stdout", OUT],
                                      check=True, capture_output=True, text=True).stdout)
    missing = [f"remote package {name}" for name in remote_packages() if name + " " not in plain]
    for path in vendored_licenses():
        if normalized(read(os.path.join(ROOT, path))) not in plain:
            missing.append(f"vendored license {path}")
    if normalized(decklink_notice()) not in plain:
        missing.append(f"DeckLink notice in {DECKLINK_SOURCE}")
    missing += [f"Rust pin {name} {tag}" for name, _, tag, _, _ in rust_pins() if f"{name} {tag}" not in plain]
    if NDI_TRADEMARK not in plain:
        missing.append("NDI trademark line")
    if missing:
        sys.exit("Sources/Credits.rtf is out of date (rerun scripts/acknowledgements.py on a dev Mac):\n  "
                 + "\n  ".join(missing))
    print("Sources/Credits.rtf covers every remote package, vendored license and Rust pin.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--check", action="store_true", help="offline: fail when Credits.rtf misses something")
    check() if parser.parse_args().check else generate()
