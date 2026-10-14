#!/usr/bin/env python3
"""Generate fresh flowcell documents for the Yggdrasil demux test stack.

Two modes:

random (default)  Derive COUNT new flowcells from the live template
                  documents: fresh flowcell/runfolder ids, remapped
                  projects/samples, event timestamps rebased to now.
--dir PATH        Build the documents from a real run folder's
                  SampleSheet.csv (e.g. BioMate/temp). Ids come from the
                  run folder name; docs are upserted by flowcell_id, so
                  re-injecting the same run folder replaces the docs.

Both docs land in the running CouchDB (flowcell_status +
demux_sample_info), re-triggering the demux workflow.
"""

import argparse
import base64
import copy
import csv
import json
import os
import random
import re
import string
import sys
import urllib.error
import urllib.request
import uuid
from datetime import datetime, timezone

FCID_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"  # no 0/O/1/I
ISO_Z = "%Y-%m-%dT%H:%M:%SZ"
ISO_MS = "%Y-%m-%dT%H:%M:%S.000+00:00"
RUNFOLDER_RE = re.compile(r"^\d{8}_[A-Za-z0-9]+_[A-Za-z0-9]+_[A-Za-z0-9]+$")
PROJECT_RE = re.compile(r"^([A-Za-z])([_.]+)(.+)_25_(\d{2})$")


def die(msg):
    print(f"generate_flowcell: {msg}", file=sys.stderr)
    sys.exit(1)


def now_dt():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def rand_str(n, alphabet, rng):
    return "".join(rng.choice(alphabet) for _ in range(n))


def rand_digits(n, rng):
    return rand_str(n, string.digits, rng)


def dunder(name):
    """'A.NoIndex_25_08' -> 'A__NoIndex_25_08' (first dot -> double underscore)."""
    if "." in name and "__" not in name:
        return name.replace(".", "__", 1)
    return name


class Couch:
    """Minimal stdlib-only CouchDB client."""

    def __init__(self, base_url, user, password):
        self.base = base_url.rstrip("/")
        self.auth = "Basic " + base64.b64encode(f"{user}:{password}".encode()).decode()

    def _request(self, method, path, body=None):
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(
            self.base + path,
            data=data,
            method=method,
            headers={"Authorization": self.auth, "Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                payload = json.loads(raw) if raw else None
            except ValueError:
                payload = raw.decode(errors="replace")
            return e.code, payload

    def get(self, path):
        return self._request("GET", path)

    def put(self, path, body):
        return self._request("PUT", path, body)

    def post(self, path, body):
        return self._request("POST", path, body)


def normalize_flowcell_id(fcid):
    """Canonical SC... vs ASC... matching (mirrors demux_realm)."""
    fcid = fcid or ""
    return fcid[1:] if fcid.startswith("ASC") else fcid


def fetch_doc(couch, db, doc_id, what):
    status, doc = couch.get(f"/{db}/{doc_id}")
    if status == 404:
        die(f"{what} '{doc_id}' not found in db '{db}' - is the stack up and "
            f"seeded? try: make compose-up && make compose-seed-status")
    if status != 200 or not isinstance(doc, dict):
        die(f"unexpected HTTP {status} fetching {what} '{doc_id}': {doc}")
    return doc


def list_flowcell_ids(couch, db):
    status, listing = couch.get(f"/{db}/_all_docs?include_docs=true")
    if status != 200 or not isinstance(listing, dict):
        die(f"cannot list db '{db}' (HTTP {status}): {listing}")
    ids = set()
    for row in listing.get("rows", []):
        fcid = (row.get("doc") or {}).get("flowcell_id")
        if fcid:
            ids.add(normalize_flowcell_id(fcid))
    return ids


def rebase_flowcell_status(template, old_runfolder, new_runfolder, new_fcid):
    """Deep-copy a flowcell_status template for a new run: runfolder rewritten
    in every string, event timestamps rebased so the last event lands on now."""
    doc = copy.deepcopy(template)
    events = doc["events"]
    stamps = [datetime.strptime(e["timestamp"], ISO_Z) for e in events]
    delta = now_dt() - stamps[-1]
    for e, t in zip(events, stamps):
        e["timestamp"] = (t + delta).strftime(ISO_Z)

    def fix(value):
        if isinstance(value, str) and old_runfolder and old_runfolder in value:
            value = value.replace(old_runfolder, new_runfolder)
        return value

    def walk(node):
        if isinstance(node, dict):
            return {k: walk(v) for k, v in node.items()}
        if isinstance(node, list):
            return [walk(v) for v in node]
        return fix(node)

    doc = walk(doc)
    doc["runfolder_id"] = new_runfolder
    doc["flowcell_id"] = new_fcid
    return doc


def collect_identifiers(template):
    """Gather every identifier string in a demux_sample_info doc (values and
    timestamp-looking dict keys)."""
    ident = {"names": set(), "ids": set(), "projects": set(), "pids": set(),
             "timestamps": set(), "dates": set()}

    def add(key, value):
        if value:
            ident[key].add(value)

    for ss in template.get("samplesheets", []):
        for r in ss.get("BCLConvert_Data", []):
            add("names", r.get("Sample_Name"))
            add("ids", r.get("Sample_ID"))
            add("projects", r.get("Sample_Project"))
    for r in template.get("uploaded_lims_info", []):
        add("names", r.get("sample_name"))
        add("ids", r.get("sample_id"))
        add("projects", r.get("sample_project"))
    for lane in (template.get("calculated") or {}).get("lanes", {}).values():
        for row in lane.get("sample_rows", {}).values():
            add("pids", row.get("project_id"))
            add("projects", row.get("project_name"))
            for s in (row.get("settings") or {}).values():
                psf = s.get("per_sample_fields") or {}
                add("names", psf.get("Sample_Name"))
                add("ids", psf.get("Sample_ID"))
                add("projects", psf.get("Sample_Project"))

    def _stamp(s):
        if re.fullmatch(r"\d{4}-\d{2}-\d{2}T.*", s):
            ident["timestamps"].add(s)
        elif re.fullmatch(r"\d{4}-\d{2}-\d{2}", s):
            ident["dates"].add(s)

    def scan(node):
        if isinstance(node, dict):
            for k, v in node.items():
                if isinstance(k, str):
                    _stamp(k)
                scan(v)
        elif isinstance(node, list):
            for v in node:
                scan(v)
        elif isinstance(node, str):
            _stamp(node)

    scan(template)
    return ident


def new_flowcell_id(taken, rng):
    for _ in range(100000):
        fcid = rand_str(11, FCID_ALPHABET, rng)
        if normalize_flowcell_id(fcid) not in taken:
            taken.add(normalize_flowcell_id(fcid))
            return fcid
    die("could not generate a unique flowcell id")


def rewrite_document(doc, mapping):
    """Rewrite identifier strings in two phases (old -> sentinel -> new),
    longest old string first so substrings (P37902 inside P37902_1001,
    date inside full timestamps) are replaced safely."""
    text = json.dumps(doc, indent=2, ensure_ascii=False)
    prefix = uuid.uuid4().hex.upper()
    olds = sorted(mapping, key=len, reverse=True)
    for i, old in enumerate(olds):
        text = text.replace(old, f"\x00{prefix}{i}\x00")
    for i, old in enumerate(olds):
        text = text.replace(f"\x00{prefix}{i}\x00", mapping[old])
    return json.loads(text)


def transform_lanes(doc, m, fresh_name):
    """Keep lanes 1..m; lanes beyond the template's range deep-copy source
    lanes (round-robin over 1..8) with fresh sample names. fresh_name(project)
    must return a unique name per call."""
    ss = doc.get("samplesheets", [])
    by_lane = {}
    for b in ss:
        by_lane.setdefault(str(int(b["lane"])), b)

    ext = {}
    for i in range(9, m + 1):
        src = str((i - 1) % 8 + 1)
        if src in by_lane:
            ext[i] = [fresh_name(r.get("Sample_Project", ""))
                      for r in by_lane[src]["BCLConvert_Data"]]

    keep = [b for b in ss if int(b["lane"]) <= m]
    for i in range(9, m + 1):
        src = str((i - 1) % 8 + 1)
        if src not in by_lane or i not in ext:
            continue
        nb = copy.deepcopy(by_lane[src])
        nb["lane"] = str(i)
        for r, name in zip(nb["BCLConvert_Data"], ext[i]):
            r["Lane"] = str(i)
            r["Sample_Name"] = name
            if "Sample_ID" in r:
                r["Sample_ID"] = "Sample_" + name
        nb["sample_count"] = len(nb["BCLConvert_Data"])
        keep.append(nb)
    doc["samplesheets"] = keep

    lims = doc.get("uploaded_lims_info", [])
    keep_l = [r for r in lims if int(r["lane"]) <= m]
    for i in range(9, m + 1):
        src = str((i - 1) % 8 + 1)
        if i not in ext:
            continue
        src_rows = [r for r in lims if str(int(r["lane"])) == src]
        for r0, name in zip(src_rows, ext[i]):
            nr = copy.deepcopy(r0)
            nr["lane"] = str(i)
            nr["sample_name"] = name
            nr["sample_id"] = name
            keep_l.append(nr)
    doc["uploaded_lims_info"] = keep_l

    calc = doc.get("calculated") or {}
    lanes = calc.get("lanes")
    if lanes:
        new_lanes = {k: v for k, v in lanes.items() if int(k) <= m}
        for i in range(9, m + 1):
            src = str((i - 1) % 8 + 1)
            if src not in lanes or i not in ext:
                continue
            nv = copy.deepcopy(lanes[src])
            rows = {}
            for v, name in zip(nv.get("sample_rows", {}).values(), ext[i]):
                v = copy.deepcopy(v)
                for s in (v.get("settings") or {}).values():
                    psf = s.get("per_sample_fields") or {}
                    if "Lane" in psf:
                        psf["Lane"] = str(i)
                    if "Sample_Name" in psf:
                        psf["Sample_Name"] = name
                    if "Sample_ID" in psf:
                        psf["Sample_ID"] = "Sample_" + name
                rows[str(uuid.uuid4())] = v
            nv["sample_rows"] = rows
            new_lanes[str(i)] = nv
        calc["lanes"] = new_lanes

    meta = doc.get("metadata")
    if meta is not None:
        meta["num_lanes"] = m
    return doc

# ---------------------------------------------------------------------------
# DIR mode: build docs from a real run folder's SampleSheet.csv
# ---------------------------------------------------------------------------

def parse_samplesheet(path):
    """Parse an Illumina v2 SampleSheet.csv -> (header, reads, settings, rows)."""
    header, reads, settings, data = {}, {}, {}, []
    fields, section = None, None
    with open(path, newline="") as fh:
        for row in csv.reader(fh):
            if not row or not row[0].strip():
                continue
            cell = row[0].strip()
            if cell.startswith("[") and cell.endswith("]"):
                section = cell[1:-1]
                continue
            if len(row) < 2:
                continue
            key, val = row[0].strip(), row[1].strip()
            if section == "Header":
                header[key] = val
            elif section == "Reads":
                reads[key] = int(val)
            elif section == "BCLConvert_Settings":
                settings[key] = val
            elif section == "BCLConvert_Data":
                if fields is None:
                    fields = [c.strip() for c in row]
                else:
                    data.append(dict(zip(fields, row)))
    return header, reads, settings, data


def resolve_run_folder(path):
    """Accept a run folder (contains SampleSheet.csv) or a dir whose immediate
    subfolders do; prefer a basename shaped YYYYMMDD_machine_runnum_flowcell."""
    path = os.path.abspath(path)
    if not os.path.isdir(path):
        die(f"not a directory: {path}")
    candidates = []
    if os.path.isfile(os.path.join(path, "SampleSheet.csv")):
        candidates.append(path)
    for entry in sorted(os.listdir(path)):
        sub = os.path.join(path, entry)
        if os.path.isdir(sub) and os.path.isfile(os.path.join(sub, "SampleSheet.csv")):
            candidates.append(sub)
    if not candidates:
        die(f"no SampleSheet.csv in {path} or its immediate subdirectories")
    preferred = [c for c in candidates if RUNFOLDER_RE.match(os.path.basename(c))]
    if len(preferred) == 1:
        return preferred[0]
    if len(preferred) > 1:
        die("ambiguous run folders: " + ", ".join(map(os.path.basename, preferred)))
    if len(candidates) == 1:
        die(f"run folder name '{os.path.basename(candidates[0])}' does not look "
            f"like YYYYMMDD_machine_runnum_flowcell")
    die("multiple SampleSheet.csv candidates without a recognizable run folder name: "
        + ", ".join(map(os.path.basename, candidates)))


def build_demux_from_dir(run_dir, template, m, rng):
    """Build a demux_sample_info doc from a run folder's SampleSheet.csv
    (run_dir may be the folder itself or a parent containing it), using the
    live template for LIMS fields (sample_ref, operator, sw, ...)."""
    run_dir = resolve_run_folder(run_dir)
    runfolder = os.path.basename(run_dir)
    fcid = runfolder.split("_")[-1]
    header, reads, settings, rows = parse_samplesheet(
        os.path.join(run_dir, "SampleSheet.csv"))
    if not rows:
        die(f"no [BCLConvert_Data] rows in {os.path.join(run_dir, 'SampleSheet.csv')}")

    r1, r2 = reads.get("Read1Cycles", 0), reads.get("Read2Cycles", 0)
    i1, i2 = reads.get("Index1Cycles", 0), reads.get("Index2Cycles", 0)
    tm = template.get("metadata") or {}
    platform = header.get("InstrumentPlatform", "")
    same_instrument = platform.replace(" ", "") == (tm.get("instrument_type") or "").replace(" ", "")
    instrument = tm.get("instrument_type") if same_instrument else (
        re.sub(r"([A-Za-z]+)(\d+)$", r"\1 \2", platform) or platform)
    run_mode = tm.get("run_mode") if same_instrument else f"{instrument} {r1 + r2}"
    now = now_dt()
    now_ms = now.strftime(ISO_MS)
    today = now.strftime("%Y-%m-%d")
    first_lims = (template.get("uploaded_lims_info") or [{}])[0]
    rs = {
        "CreateFastqForIndexReads": settings.get("CreateFastqForIndexReads", "1") in ("1", "true", "True"),
        "MinimumTrimmedReadLength": int(settings.get("MinimumTrimmedReadLength", "0") or 0),
        "MaskShortReads": int(settings.get("MaskShortReads", "0") or 0),
    }

    by_lane, pid_of = {}, {}
    for r in rows:
        proj = (r.get("Sample_Project") or "").strip()
        name = (r.get("Sample_Name") or "").strip()
        mpid = re.match(r"^([A-Z]\d{5})_\d+$", name)
        if proj and mpid and proj not in pid_of:
            pid_of[proj] = mpid.group(1)
        by_lane.setdefault(int(r.get("Lane", "0")), []).append(r)
    lane_nums = sorted(by_lane)
    if not lane_nums:
        die("no lanes found in SampleSheet.csv")
    if m is None:
        m = max(lane_nums)
    if m < 1:
        die("lanes must be >= 1")

    used_names = set()

    def fresh_name(proj):
        pid = pid_of.get(proj, "P00000")
        while True:
            cand = f"{pid}_{rand_digits(4, rng)}"
            if cand not in used_names:
                used_names.add(cand)
                return cand

    def make_block(lane, lane_rows):
        projects = sorted({(r.get("Sample_Project") or "").strip() for r in lane_rows})
        bcd = [{
            "Lane": str(lane),
            "Sample_ID": r.get("Sample_ID", ""),
            "Sample_Name": r.get("Sample_Name", ""),
            "index": r.get("index", ""),
            "index2": r.get("index2", ""),
            "Sample_Project": r.get("Sample_Project", ""),
            "OverrideCycles": r.get("OverrideCycles", ""),
        } for r in lane_rows]
        return {
            "lane": str(lane),
            "projects": projects,
            "settings_index": 0,
            "sample_count": len(bcd),
            "filename": f"Lane{lane}_{projects[0] if projects else ''}_0.csv",
            "Header": {
                "FileFormatVersion": header.get("FileFormatVersion", "2"),
                "RunName": fcid,
                "Date": today,
            },
            "raw_samplesheet_settings": dict(rs),
            "BCLConvert_Data": bcd,
        }

    blocks = [make_block(l, by_lane[l]) for l in lane_nums if l <= m]
    if m > max(lane_nums):
        ext_src = sorted(l for l in lane_nums if l <= 8) or lane_nums
        for i in range(max(lane_nums) + 1, m + 1):
            src = ext_src[(i - 1) % len(ext_src)]
            lane_rows = copy.deepcopy(by_lane[src])
            for r in lane_rows:
                r["Lane"] = str(i)
                name = fresh_name((r.get("Sample_Project") or "").strip())
                r["Sample_Name"] = name
                if (r.get("Sample_ID") or "").startswith("Sample_"):
                    r["Sample_ID"] = "Sample_" + name
                else:
                    r["Sample_ID"] = name
            blocks.append(make_block(i, lane_rows))
    blocks.sort(key=lambda b: int(b["lane"]))

    lims = []
    for b in blocks:
        for r in b["BCLConvert_Data"]:
            proj = (r.get("Sample_Project") or "").strip()
            lims.append({
                "lane": r["Lane"],
                "sample_id": r["Sample_Name"],
                "sample_name": r["Sample_Name"],
                "sample_project": proj,
                "description": proj,
                "sample_ref": first_lims.get("sample_ref", ""),
                "rc": f"{r1}-{r2}",
                "recipe": f"{r1}-{i1}-{i2}-{r2}",
                "control": first_lims.get("control", "N"),
                "operator": first_lims.get("operator", ""),
                "flowcell_id": fcid,
                "sw": first_lims.get("sw", "1:1"),
                "index": r.get("index", ""),
                "index2": r.get("index2", ""),
            })

    return {
        "flowcell_id": fcid,
        "metadata": {
            "num_lanes": m,
            "run_setup": f"{r1}_{i1}_{i2}_{r2}",
            "setup_lims_step_id": "",
            "instrument_type": instrument,
            "run_mode": run_mode,
            "first_generated": now_ms,
        },
        "uploaded_lims_info": lims,
        "calculated": {
            "version_history": {
                now_ms: {
                    "generated_by": None,
                    "autogenerated": True,
                    "comment": f"Injected from {run_dir}",
                    "auto_run": True,
                    "config_version": template.get("config_version", ""),
                }
            }
        },
        "samplesheets": blocks,
        "config_version": template.get("config_version", ""),
    }


# ---------------------------------------------------------------------------
# Random mode: derive a fresh flowcell from the live templates
# ---------------------------------------------------------------------------

def build_random_mapping(template, old_runfolder, new_runfolder, new_fcid, rng):
    """old string -> new string for every identifier in a demux template."""
    ident = collect_identifiers(template)
    mapping = {}

    def put(old, new):
        if old and old not in mapping:
            mapping[old] = new

    put(template.get("flowcell_id", ""), new_fcid)
    put(old_runfolder, new_runfolder)

    used_names = set(mapping.values())

    def new_project(old):
        m = PROJECT_RE.match(old)
        sep = m.group(2) if m else "__"
        middle = m.group(3) if m else old
        while True:
            cand = f"{rng.choice(string.ascii_uppercase)}{sep}{middle}_25_{rand_digits(2, rng)}"
            if cand not in used_names:
                used_names.add(cand)
                return cand

    for p in sorted(ident["projects"]):
        put(p, new_project(p))

    used_pids = set()

    def new_pid(old):
        while True:
            cand = f"P{rand_digits(5, rng)}"
            if cand not in used_pids:
                used_pids.add(cand)
                return cand

    pid_new = {p: new_pid(p) for p in sorted(ident["pids"])}
    for p, n in pid_new.items():
        put(p, n)

    # project -> old pid (calculated sample_rows carry both in one row)
    proj_pid = {}
    for lane in (template.get("calculated") or {}).get("lanes", {}).values():
        for row in lane.get("sample_rows", {}).values():
            pn, pid = row.get("project_name"), row.get("project_id")
            if pn and pid:
                proj_pid[dunder(pn)] = pid
                proj_pid[pn] = pid
    # sample name -> project (samplesheet rows, lims rows as fallback)
    name_proj = {}
    for ss in template.get("samplesheets", []):
        for r in ss.get("BCLConvert_Data", []):
            if r.get("Sample_Name"):
                name_proj[r["Sample_Name"]] = dunder(r.get("Sample_Project") or "")
    for r in template.get("uploaded_lims_info", []):
        if r.get("sample_name"):
            name_proj.setdefault(r["sample_name"], dunder(r.get("sample_project") or ""))

    used_samples = set()

    def new_sample(proj):
        old_pid = proj_pid.get(proj)
        pid = pid_new.get(old_pid, "P00000") if old_pid else "P00000"
        while True:
            cand = f"{pid}_{rand_digits(4, rng)}"
            if cand not in used_samples:
                used_samples.add(cand)
                return cand

    for n in sorted(ident["names"]):
        put(n, new_sample(name_proj.get(n, "")))
    for i in sorted(ident["ids"]):
        if i.startswith("Sample_"):
            put(i, "Sample_" + mapping.get(i[len("Sample_"):], i))
        else:
            put(i, mapping.get(i, i))

    now_ms = now_dt().strftime(ISO_MS)
    today = now_dt().strftime("%Y-%m-%d")
    for t in sorted(ident["timestamps"]):
        put(t, now_ms)
    for d in sorted(ident["dates"]):
        put(d, today)
    return mapping, pid_new


def generate_random(couch, t_flowcell, t_demux, lanes, taken, rng):
    """One fresh (flowcell_status, demux_sample_info) doc pair."""
    fcid = new_flowcell_id(taken, rng)
    runfolder_old = t_flowcell.get("runfolder_id", "")
    machine = runfolder_old.split("_")[1] if len(runfolder_old.split("_")) >= 2 else "LM00000"
    runfolder = f"{now_dt().strftime('%Y%m%d')}_{machine}_{rand_digits(4, rng)}_{fcid}"

    status_doc = rebase_flowcell_status(t_flowcell, runfolder_old, runfolder, fcid)

    m = lanes if lanes else int((t_demux.get("metadata") or {}).get("num_lanes") or 8)
    demux_doc = copy.deepcopy(t_demux)
    mapping, pid_new = build_random_mapping(t_demux, runfolder_old, runfolder, fcid, rng)

    used_ext = set()

    def fresh_name(proj):
        while True:
            cand = "TMPX" + uuid.uuid4().hex[:8]
            if cand not in used_ext:
                used_ext.add(cand)
                return cand

    transform_lanes(demux_doc, m, fresh_name)

    # Map each extension placeholder to a final name (project pid + 4 digits).
    proj_pid = {}
    for lane in (t_demux.get("calculated") or {}).get("lanes", {}).values():
        for row in lane.get("sample_rows", {}).values():
            pn, pid = row.get("project_name"), row.get("project_id")
            if pn and pid:
                proj_pid[dunder(pn)] = pid
    used = set(mapping.values())
    ext_remap = {}

    def final_name(proj, ph):
        old_pid = proj_pid.get(dunder(proj))
        base = pid_new.get(old_pid, "P00000") if old_pid else "P00000"
        while True:
            cand = f"{base}_{rand_digits(4, rng)}"
            if cand not in used:
                used.add(cand)
                ext_remap[ph] = cand
                ext_remap["Sample_" + ph] = "Sample_" + cand
                return cand

    # Walk extension lanes and assign final names placeholder by placeholder.
    for b in demux_doc["samplesheets"]:
        if int(b["lane"]) > int((t_demux.get("metadata") or {}).get("num_lanes") or 8):
            for r in b["BCLConvert_Data"]:
                final_name(r.get("Sample_Project", ""), r["Sample_Name"])
    mapping.update(ext_remap)

    demux_doc = rewrite_document(demux_doc, mapping)
    demux_doc.pop("_id", None)
    demux_doc.pop("_rev", None)
    (status_doc).pop("_id", None)
    status_doc.pop("_rev", None)
    return fcid, runfolder, status_doc, demux_doc


def write_docs(couch, mode, fcid, runfolder, status_doc, demux_doc):
    """POST (random mode) or upsert by flowcell_id (DIR mode)."""
    written = []
    for db, doc in (("flowcell_status", status_doc), ("demux_sample_info", demux_doc)):
        if mode == "random":
            status, res = couch.post(f"/{db}", doc)
            if status != 201:
                die(f"POST /{db} failed (HTTP {status}): {res}")
            written.append((db, res.get("id"), "created"))
        else:
            target = None
            status, listing = couch.get(f"/{db}/_all_docs?include_docs=true")
            if status != 200:
                die(f"cannot list db '{db}' (HTTP {status}): {listing}")
            for row in listing.get("rows", []):
                d = row.get("doc") or {}
                if normalize_flowcell_id(d.get("flowcell_id")) == normalize_flowcell_id(fcid):
                    target = (d.get("_id"), d.get("_rev"))
                    break
            body = dict(doc)
            if target:
                body["_id"], body["_rev"] = target
                status, res = couch.put(f"/{db}/{target[0]}", body)
                label = "updated"
            else:
                status, res = couch.post(f"/{db}", body)
                target = (res.get("id"), None)
                label = "created"
            if status != 201:
                die(f"write to /{db} failed (HTTP {status}): {res}")
            written.append((db, target[0], label))
    for db, doc_id, label in written:
        print(f"  {db}: {label} '{doc_id}'")
    print(f"Injected flowcell {fcid} (runfolder {runfolder}).")
    print("Watch the workflow with: make compose-logs")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--base-url", default="http://localhost:5984")
    ap.add_argument("--user", default="admin")
    ap.add_argument("--password", default="secret")
    ap.add_argument("--count", type=int, default=1)
    ap.add_argument("--template-flowcell-id", required=True)
    ap.add_argument("--template-demux-id", required=True)
    ap.add_argument("--lanes", type=int, default=0)
    ap.add_argument("--dir", default="")
    args = ap.parse_args()

    if args.count < 1:
        die("count must be >= 1")
    if args.lanes and args.lanes < 1:
        die("lanes must be >= 1")
    if args.dir and args.count > 1:
        die("DIR mode injects a single flowcell; drop --count")

    couch = Couch(args.base_url, args.user, args.password)
    rng = random.Random()
    t_flowcell = fetch_doc(couch, "flowcell_status", args.template_flowcell_id, "template flowcell_status")
    t_demux = fetch_doc(couch, "demux_sample_info", args.template_demux_id, "template demux_sample_info")

    if args.dir:
        run_dir = resolve_run_folder(args.dir)
        doc = build_demux_from_dir(run_dir, t_demux, args.lanes or None, rng)
        fcid = doc["flowcell_id"]
        runfolder = os.path.basename(run_dir)
        status_doc = rebase_flowcell_status(
            t_flowcell, t_flowcell.get("runfolder_id", ""), runfolder, fcid)
        status_doc.pop("_id", None)
        status_doc.pop("_rev", None)
        doc.pop("_id", None)
        doc.pop("_rev", None)
        print(f"DIR mode: run folder {run_dir}")
        write_docs(couch, "dir", fcid, runfolder, status_doc, doc)
        return

    taken = list_flowcell_ids(couch, "flowcell_status") | list_flowcell_ids(couch, "demux_sample_info")
    for _ in range(args.count):
        fcid, runfolder, status_doc, demux_doc = generate_random(
            couch, t_flowcell, t_demux, args.lanes or None, taken, rng)
        print(f"random mode: generated flowcell {fcid}")
        write_docs(couch, "random", fcid, runfolder, status_doc, demux_doc)


if __name__ == "__main__":
    main()
