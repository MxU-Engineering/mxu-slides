#!/usr/bin/env python3
"""The perf check's library, built through a sandbox instance's Local API.

  make-library.py mint <local-api-tokens.json>
      Writes a token file holding one Edit-scope key and prints its secret.
      The app reads the hashed file at launch (APITokenStore: a salted
      SHA-256 record, `<salt hex>$<sha256(salt + secret) hex>`), so no UI
      and no Keychain are involved.
  make-library.py build --port P --token SECRET --fixtures DIR [--decks N]
      Adds N copies (default 300) of fixtures/bulk-deck.json (the Welcome
      deck as the Local API returns it) and "Path Text Perf": the 24-slide
      deck made from fixtures/path-text-deck.json's first slide (a card with
      three path-text tickers over it, the 2026-09-24 editor-drag case).

Python 3 standard library only.
"""

import argparse
import copy
import hashlib
import json
import os
import secrets
import sys
import urllib.request
import uuid

def mint(path):
    secret = "mxu_" + secrets.token_hex(24)
    salt = secrets.token_bytes(16)
    record = salt.hex() + "$" + hashlib.sha256(salt + secret.encode()).hexdigest()
    token = {
        "id": str(uuid.uuid4()).upper(),
        "name": "Perf check",
        "scope": "edit",
        "secretRecord": record,
        "prefix": secret[:9],

        "createdAt": 0,
    }
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as handle:
        json.dump([token], handle)
    print(secret)

def request(port, token, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        f"http://127.0.0.1:{port}{path}", method=method, data=data,
        headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as response:
        return response.read()

def path_text_deck(template):
    deck = copy.deepcopy(template)
    first = deck["slides"][0]
    slides = []
    for number in range(1, 25):
        text = json.dumps(first).replace(first["id"], f"perf.slide{number}")
        slide = json.loads(text)
        slide["name"] = f"Path Text {number}"
        slides.append(slide)
    deck["slides"] = slides
    return deck

def build(port, token, fixtures, count):
    with open(os.path.join(fixtures, "bulk-deck.json")) as handle:
        bulk = json.load(handle)
    with open(os.path.join(fixtures, "path-text-deck.json")) as handle:
        perf = json.load(handle)
    request(port, token, "POST", "/v1/documents/presentations", path_text_deck(perf))
    source_id = bulk["id"]
    for index in range(count):
        deck = json.loads(json.dumps(bulk).replace(source_id, f"bulk{index:03d}"))
        deck["id"] = f"bulk{index:03d}"
        deck["name"] = f"Bulk Deck {index:03d}"
        request(port, token, "POST", "/v1/documents/presentations", deck)
    print(f"created {count + 1} decks")

def main(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    minting = commands.add_parser("mint")
    minting.add_argument("path")
    building = commands.add_parser("build")
    building.add_argument("--port", type=int, required=True)
    building.add_argument("--token", required=True)
    building.add_argument("--fixtures", required=True)
    building.add_argument("--decks", type=int, default=300)
    args = parser.parse_args(argv)
    if args.command == "mint":
        mint(args.path)
    else:
        build(args.port, args.token, args.fixtures, args.decks)
    return 0

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
