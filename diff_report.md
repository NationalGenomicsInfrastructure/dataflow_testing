# BioMate seed document derivation — v2 (new genomics-status schema)

Generated: 2026-10-12 15:00:25 

Target run (BioMate temp): `20260310_LM43899_0385_A12GGASZR5` — flowcell `A12GGASZR5`, instrument `LM43899`,
run `0385` (data form `385`), date `2026-03-10`, operator `John_Doe`.
The two `_biomate` seed docs are re-parameterized to this run and shaped on the
**new** genomics-status demux schema (production docs as structural template).

## Sources

| Source | Path | Role |
|--------|------|------|
| Originals | `example_of_*.json` (repo root) | old-schema format reference (v1); never modified |
| v1 seeds | `deploy/seed/*_biomate.json` (pre-v2) | A12GGASZR5 re-parameterized data: fs events, sample uuids, 18-key settings, LIMS rows |
| BioMate temp | `BioMate/temp/` (`RunInfo.xml`, `SampleSheet.csv`, `bcl-convert.out`) | target-run source of truth |
| Production template | `/tmp/opencode/sc2180665_{fs,dx}_probe.json` | SC2180665-SC3 docs fetched read-only from `ngi-statusdb-dev.scilifelab.se`; **structure only — no production data carried** |

## `flowcell_status_biomate.json`

| Field | Value | Source / note |
|-------|-------|---------------|
| `_id` / `_rev` | regenerated | 32-hex id, `1-<32hex>` rev |
| `runfolder_id` | `20260310_LM43899_0385_A12GGASZR5` | temp RunInfo.xml |
| `flowcell_id` | `A12GGASZR5` | temp RunInfo.xml |
| `events` | 19 (verbatim from v1) | already re-parameterized for this run: rsync commands carry the runfolder (2 occurrences; 3 in final transfer), `destination_path /Illumina/NextSeq`; anchored on 2026-03-10T00:00:00Z, hourly transfers 00:00–14:00, finished+final 15:00, HPC 16:00 |
| `files` | **dropped** | template has no `files` key; the realm never reads it ⚠ |

## `demux_sample_info_biomate.json`

### Top level

Top-level key order = template: `_id, _rev, flowcell_id, metadata, uploaded_lims_info, calculated, samplesheets, config_version`.
`_id`/`_rev` regenerated; `flowcell_id` = `A12GGASZR5`; `config_version` = `1.1.0` (template).

### metadata

| Field | Value | Source / note |
|-------|-------|---------------|
| `num_lanes` | `8` | temp |
| `run_setup` | `151_10_10_151` | temp [Reads] (r1_i1_i2_r2, template underscore form) |
| `setup_lims_step_id` | `""` | ⚠ no source (template had a real LIMS id) |
| `instrument_type` | `NextSeq 2000` | temp says `NextSeq2000`; template uses spaced style |
| `run_mode` | `NextSeq 2000 300` | ⚠ judgment call: 2×151 reads → 300-cycle kit (no source) |
| `first_generated` | `2026-03-10T16:00:00.000+00:00` | `transferred_to_hpc` instant, template timestamp format (ms + `+00:00`) |

### uploaded_lims_info (47 rows, 14 keys, template order)

Row order: lane, then SampleSheet.csv order. `lane`/`sample_id`/`sample_name`/`sample_project`/`description`/`sample_ref`/`control` from v1;
`operator` = `John_Doe`; `flowcell_id` = `A12GGASZR5`; `index`/`index2` from temp (empty for NOINDEX);
⚠ `rc` = `151-151` (template pattern `301-301` = r1-r2 applied to temp reads);
⚠ `recipe` = `151-10-10-151` (template pattern applied to temp reads; v1 old-schema used `151-151`);
⚠ `sw` = `1:1` (template value kept; semantics unknown, no source in temp).

### calculated.lanes (1–8) / sample_rows (47)

Sample uuids **reused from v1** (mapped by (lane, sample_name)). Row fields (template order):
`last_modified` = NEW_TS_MS; ⚠ `library_method` = `Finished library (by user)` (template value, no source);
`project_id` = first token of sample_id (e.g. `P37902`, template rule);
`project_name` = Sample_Project with `__` → `.` (template rule);
`control`/`description`/`flowcell_id` from v1.
Single `settings` entry keyed `2026-03-10T16:00:00.000+00:00`:

| Sub-key | Content | Source / note |
|---------|---------|---------------|
| `other_details` | `named_index`, `operator`, `sample_ref`, `sample_type`, `index_length` from v1 18-key settings; ⚠ `recipe` = `151-10-10-151` (template keeps lims+other_details recipe identical; v1 used `151-151`); ⚠ `umi_config` = `null` (v1 `umi_length` **not carried** — no slot in new schema); `config_sources` from template; `library_method`, `project_id` as above | |
| `per_sample_fields` | `Lane` (string), `Sample_ID`, `index`, `index2`, `OverrideCycles`, `Sample_Name`, `Sample_Project` | that lane's temp SampleSheet.csv row |
| `raw_samplesheet_settings` | `{TrimUMI: true, CreateFastqForIndexReads: true, MinimumTrimmedReadLength: 0, MaskShortReads: 0}` (typed) | temp [BCLConvert_Settings]; ⚠ `MaskShortReads 0` has no temp source (v1 18-key `mask_short_reads`) |
| `samplesheet_settings` | raw minus `TrimUMI` (3 keys) | template rule |

### samplesheets (8 entries, one per lane)

Entry order = template, with the `BCLConvert_Settings` key **renamed `raw_samplesheet_settings`**
(required by the local `demux_realm` validator; dry-run proven).

| Field | Value | Source / note |
|-------|-------|---------------|
| `lane` | `"1"`…`"8"` (string) | temp |
| `projects` | lane's unique Sample_Project list (first-appearance order) | temp; multi-project lanes: 2, 3, 5, 7, 8 |
| `settings_index` | `0` | single settings set per lane |
| `sample_count` | per-lane count ({1:1, 2:8, 3:4, 4:5, 5:11, 6:4, 7:8, 8:6} = 47) | temp |
| `filename` | `Lane{n}_{projects[0]}_0.csv` | template rule |
| `Header` | `FileFormatVersion "2"`, ⚠ `RunName "A12GGASZR5"` (production convention — temp [Header] says `DummyRun`), ⚠ `Date "2026-03-10"` (run date; template used the HPC-transfer day) | |
| `raw_samplesheet_settings` | `{CreateFastqForIndexReads: true, MinimumTrimmedReadLength: 0, MaskShortReads: 0}` (3 typed keys) | template shape; temp's `SoftwareVersion`/`FastqCompressionFormat`/`AutoDetectDemuxMode`/`TrimUMI` have no slot here (TrimUMI lives in sample_rows) ⚠ |
| `BCLConvert_Data` | the lane's rows, 7 columns `{Lane, Sample_ID, Sample_Name, index, index2, Sample_Project, OverrideCycles}` in temp CSV order | ⚠ temp's 2 empty `BarcodeMismatches*` columns dropped (template shape) |

### version_history

Single entry keyed `2026-03-10T16:00:00.000+00:00`:
`{generated_by: null, autogenerated: true, comment: "Uploaded from LIMS", auto_run: true, config_version: "1.1.0"}` (template upload-entry shape).

## No-source / judgment calls (all flagged ⚠)

- `files` key dropped from flowcell_status (template-faithful)
- `run_mode "NextSeq 2000 300"` — inferred from 2×151 reads
- `sw "1:1"`, `library_method "Finished library (by user)"`, `setup_lims_step_id ""` — template/empty, no temp source
- `rc`/`recipe` patterns derived from temp reads in the template's format
- `umi_length` not carried into the new schema (`umi_config: null`)
- `Header.RunName` = flowcell id (production convention), `Header.Date` = run date
- 7-column `BCLConvert_Data` (2 empty barcode-mismatch columns dropped)
- 3-key typed settings in the samplesheets entry (template shape)

## v1 → v2 structural changes

- fs: `files` key dropped (template has none)
- dx: top level gains `samplesheets` + `config_version`; metadata keys replaced
  (`instrument_id`/`run_setup`/`.00`-format `first_generated` → `run_setup`/`run_mode`/`+00:00`-format `first_generated`)
- `uploaded_lims_info` 12 → 14 keys (`rc`, `sw`, `index`, `index2` added; `index_1`/`index_2` renamed)
- `sample_rows` flat 18-key settings → nested `other_details` / `per_sample_fields` / `raw_samplesheet_settings` / `samplesheet_settings`
- `version_history` entries gain `comment` + `config_version`
- all sample timestamps `.00` (no tz) → `.000+00:00`

## Validation (all passed)

- temp: 47 rows; lane counts {1:1, 2:8, 3:4, 4:5, 5:11, 6:4, 7:8, 8:6}; [BCLConvert_Settings] 6 keys
- structural conformance with the production template at every level (key order: top, metadata, lims rows,
  sample_rows rows, settings entries + 4 sub-keys, samplesheets entries (with the settings-key rename),
  BCLConvert_Data rows, Header, version_history entry)
- 47/47 samples agree temp ↔ v1 (Sample_ID == `Sample_`+sample_id; index/index2/OverrideCycles/Sample_Project)
- per-lane uuid sets preserved from v1
- samplesheets: per-lane rows verbatim from temp CSV (7 cols); projects unique first-appearance; filename pattern
- no production identity tokens (SC2180665, SH01140, 20260818, MiSeq, P40759, N__Street, 301_*, 2026-08-18/19,
  Maria_Gyftea, franziska, DummyRun) and no old/original tokens (VH00203, AAHNNGLM5, 260304, 233KCWLT4,
  GE10018, 30RMNSCK9, 260930, Lars_Eriksson)
- fs: 19 events verbatim from v1; final transfer `destination_path /Illumina/NextSeq`; runfolder in rsync commands
- realm: `validate_lane_payload` passes on all 8 samplesheets entries; `render_bcl_convert_samplesheet`
  round-trips Header / settings / BCLConvert_Data per lane

## Live verification (local stack, 2026-10-12)

- Both docs seeded via `make compose-seed-status` (the `_id`s above); the dmx_realm watcher joined them on `flowcell_id` (runfolder `20260310_LM43899_0385_A12GGASZR5`, `destination_path` `/Illumina/NextSeq`).
- Realm (c31ea02) accepted all 8 `samplesheets` entries (validator + render round-trip) and created + auto-approved `dmx_realm:A12GGASZR5:init` plus `dmx_realm:A12GGASZR5:lane_{1..8}:settings_0` (6 steps each: runfolder validation + 5 pipeline steps).
- Execution: **all 8 lane plans completed** (demux, results collection and upload simulated; config materialization + SampleSheet generation are real workdir writes).
- The `init` plan failed as expected on the one REAL step: `Upsert x_flowcells Pre-Demux Document` → `FileNotFoundError: /Illumina/NextSeq/20260310_LM43899_0385_A12GGASZR5/RunInfo.xml` (HPC runfolder absent on the test machine); no `x_flowcells` doc was created.
