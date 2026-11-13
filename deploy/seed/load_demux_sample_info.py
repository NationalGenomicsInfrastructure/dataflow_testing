#!/usr/bin/env python3
"""Load the test flowcells' demux_sample_info documents into a running stack.

Two sources:

lims (default)  POST deploy/seed/lims_upload/lims_upload_<fc>.json to the
                genomics-status API (/api/v1/demux_sample_info/<fc>), the
                way the LIMS samplesheet generator uploads them. Genomics
                status builds calculated/samplesheets from the seeded
                demux_configuration and projects.
seed            PUT the finished documents in
                deploy/seed/demux_sample_info/demux_sample_info_<fc>.json
                straight into CouchDB.

Flowcells that already have a demux_sample_info document are skipped, so
re-running is harmless; --force deletes their documents first and loads
them again (for lims, through the API's create path, not its reupload).
"""

import argparse
import base64
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

SEED_DIR = os.path.dirname(os.path.abspath(__file__))
SOURCES = {
    "lims": (os.path.join(SEED_DIR, "lims_upload"), "lims_upload_"),
    "seed": (os.path.join(SEED_DIR, "demux_sample_info"), "demux_sample_info_"),
}


def die(msg):
    print(f"load_demux_sample_info: {msg}", file=sys.stderr)
    sys.exit(1)


def request(method, url, body=None, auth=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"}
    if auth:
        headers["Authorization"] = auth
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            payload = json.loads(raw) if raw else None
        except ValueError:
            payload = raw.decode(errors="replace")
        return e.code, payload


def wait_for(url, name, timeout):
    """Poll url until it answers 200; genomics-status takes a while on a cold start."""
    waited = 0
    while True:
        try:
            with urllib.request.urlopen(url, timeout=5) as resp:
                if resp.status == 200:
                    return
        except (urllib.error.URLError, OSError):
            pass
        if waited >= timeout:
            die(f"{name} did not answer at {url} within {timeout}s - is the stack up? try: make compose-up")
        if waited == 0:
            print(f"Waiting for {name} at {url}...")
        time.sleep(2)
        waited += 2


def available_flowcells(source):
    directory, prefix = SOURCES[source]
    found = {}
    for name in sorted(os.listdir(directory)):
        if name.startswith(prefix) and name.endswith(".json"):
            found[name[len(prefix):-len(".json")]] = os.path.join(directory, name)
    return found


def existing_docs(couch, auth, flowcell_id):
    key = urllib.parse.quote(json.dumps(flowcell_id))
    status, res = request(
        "GET", f"{couch}/demux_sample_info/_design/info/_view/flowcell_id?key={key}&include_docs=true", auth=auth
    )
    if status != 200:
        die(f"cannot look up flowcell {flowcell_id} in demux_sample_info (HTTP {status}): {res}")
    return [row["doc"] for row in res["rows"]]


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--source", choices=sorted(SOURCES), default="lims")
    ap.add_argument("--flowcells", default="", help="space or comma separated flowcell ids (default: all in the source)")
    ap.add_argument("--force", action="store_true", help="delete and reload flowcells that already have a document")
    ap.add_argument("--couch-url", default="http://localhost:5984")
    ap.add_argument("--genstat-url", default="http://localhost:9761")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="secret")
    ap.add_argument("--wait", type=int, default=300, help="seconds to wait for CouchDB / genomics-status")
    args = ap.parse_args()

    couch = args.couch_url.rstrip("/")
    genstat = args.genstat_url.rstrip("/")
    auth = "Basic " + base64.b64encode(f"{args.user}:{args.password}".encode()).decode()

    available = available_flowcells(args.source)
    wanted = [f for f in args.flowcells.replace(",", " ").split() if f] or list(available)
    unknown = [f for f in wanted if f not in available]
    if unknown:
        die(f"no {args.source} file for flowcell(s) {', '.join(unknown)} in {SOURCES[args.source][0]}")

    wait_for(f"{couch}/_up", "CouchDB", args.wait)
    if args.source == "lims":
        wait_for(f"{genstat}/", "genomics-status", args.wait)

    loaded = skipped = 0
    for fc in wanted:
        docs = existing_docs(couch, auth, fc)
        if docs and not args.force:
            print(f"  {fc}: skipped, already has a demux_sample_info document (FORCE=1 reloads it)")
            skipped += 1
            continue
        for doc in docs:
            status, res = request(
                "DELETE", f"{couch}/demux_sample_info/{doc['_id']}?rev={doc['_rev']}", auth=auth
            )
            if status not in (200, 202):
                die(f"cannot delete demux_sample_info/{doc['_id']} (HTTP {status}): {res}")

        with open(available[fc]) as fh:
            body = json.load(fh)
        if args.source == "lims":
            status, res = request("POST", f"{genstat}/api/v1/demux_sample_info/{fc}", body)
            if status != 201:
                die(f"{fc}: genomics-status rejected the upload (HTTP {status}): {res}")
        else:
            doc_id = body.pop("_id")
            body.pop("_rev", None)
            status, res = request("PUT", f"{couch}/demux_sample_info/{doc_id}", body, auth=auth)
            if status not in (201, 202):
                die(f"{fc}: cannot write demux_sample_info/{doc_id} (HTTP {status}): {res}")
        print(f"  {fc}: {'reloaded' if docs else 'loaded'} from {args.source}")
        loaded += 1

    print(f"demux_sample_info: {loaded} loaded, {skipped} skipped (source: {args.source}).")


if __name__ == "__main__":
    main()
