#!/usr/bin/env bash
# Register the web crawl config for the local FAQ content service and run it.
#
# There is no precedent for this in the other docker-* repos: docker-codesearch
# registers a *data* config (fess-ds-git) and docker-docsearch punts to the admin
# UI. A demo that needs a human to click through /admin/webconfig/ before it shows
# anything is not a demo.
#
# Contract mirrors docker-codesearch/bin/register_github.sh: connection/auth use
# fessctl's own environment variables (FESS_ENDPOINT, FESS_ACCESS_TOKEN).
set -euo pipefail

usage() {
  cat <<'EOF'
register-faq-crawl.sh — register the FAQ WebConfig (http://content/) and crawl it (via fessctl).

Usage:
  FESS_ACCESS_TOKEN=<token> ./bin/register-faq-crawl.sh [options]

Options:
  --depth N            Crawl depth (default: 3; index.html -> /ja|en/ -> page)
  --max-access-count N Maximum access count (default: 100)
  --no-crawl           Register the WebConfig only; do not start the crawler
  --no-wait            Start the crawler but do not poll for completion
  -h, --help           Show this help and exit

Environment:
  VECTOR_JOB_CRON    Schedule for the Content Chunk Vector Indexer (default: "0 * * * *")
  MAX_WAIT           Seconds to wait for each job (default: 600)
Environment (consumed by fessctl):
  FESS_ENDPOINT      Fess base URL (default: http://localhost:8080)
  FESS_ACCESS_TOKEN  Admin-api access token (required)

Requirements: fessctl (https://github.com/codelibs/fessctl), python3.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

# --- parse arguments ---
depth=3
max_access_count=100
crawl=1
wait_for_crawl=1
while [ $# -gt 0 ]; do
  case "$1" in
    --depth)              depth="${2:?--depth needs a value}"; shift 2;;
    --max-access-count)   max_access_count="${2:?--max-access-count needs a value}"; shift 2;;
    --no-crawl)           crawl=0; shift;;
    --no-wait)            wait_for_crawl=0; shift;;
    -h|--help)             usage; exit 0;;
    *)                     usage >&2; die "unknown argument: $1";;
  esac
done

# --- preflight checks ---
command -v fessctl >/dev/null 2>&1 || die "fessctl not found. Install with: pipx install fessctl (or: uv tool install fessctl). See https://github.com/codelibs/fessctl"
command -v python3 >/dev/null 2>&1 || die "python3 not found."
[ -n "${FESS_ACCESS_TOKEN:-}" ] || die "FESS_ACCESS_TOKEN is not set (an admin-api access token, see /admin/accesstoken/)."
: "${FESS_ENDPOINT:=http://localhost:8080}"; export FESS_ENDPOINT

name="faq-content"
target_url="http://content/"

# --- skip create if a WebConfig with this name already exists (idempotent re-runs) ---
existing=$(fessctl webconfig list -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
name = sys.argv[1]
for s in d.get("response", {}).get("settings", []):
    if s.get("name") == name:
        print(s.get("id", ""))
        break
' "$name" || true)

if [ -n "$existing" ]; then
  echo "WebConfig already registered: ${name} (id=${existing}); skipping create."
else
  echo "Registering WebConfig: ${name} -> ${target_url}"
  # The hub page (index.html) is the crawl entry point: follow its links but do
  # not index it. It lists every FAQ title, so as a document it matches almost
  # any question, pushes real answers down and has no category label.
  fessctl webconfig create \
    --name "$name" \
    --url "$target_url" \
    --included-url "http://content/.*" \
    --excluded-doc-url "http://content/(index\.html)?" \
    --depth "$depth" \
    --max-access-count "$max_access_count" \
    --permission "{role}guest" \
    -o json \
  | python3 -c '
import sys, json
d = json.load(sys.stdin).get("response", {})
if d.get("status") != 0:
    sys.stderr.write("fessctl: " + str(d.get("message", "create failed")) + "\n")
    sys.exit(1)
print("Created WebConfig id=" + str(d.get("id", "")))
' || die "failed to create the WebConfig."
fi

if [ "$crawl" -ne 1 ]; then
  echo "Registered only (--no-crawl). Start the crawl later with: fessctl scheduler start default_crawler"
  exit 0
fi

# --- resolve the built-in Default Crawler scheduler id ---
scheduler_id=$(fessctl scheduler list -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for s in d.get("response", {}).get("settings", []):
    if s.get("name") == "Default Crawler" or s.get("id") == "default_crawler":
        print(s.get("id", ""))
        break
' || true)
scheduler_id="${scheduler_id:-default_crawler}"

# --- latest_run <job name>: "<id> <status>" of the newest job-log row of that job ---
# Fess writes a run's job-log row from the job thread, after the start API has
# returned, so right after a start the newest row can still be the PREVIOUS run.
latest_run() {
  fessctl joblog list -o json 2>/dev/null | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
# Newest entries are sorted first; report the newest run of this job.
for log in d.get("response", {}).get("logs", []):
    if log.get("job_name") == sys.argv[1]:
        print(log.get("id", ""), log.get("job_status", ""))
        break
' "$1" || true
}

# --- wait_job <job name> <id of the run before the start>: poll the job log until
#     a NEWER run of that job has finished ---
wait_job() {
  local job_name="$1" before="$2" max_wait="${MAX_WAIT:-600}" elapsed=0 interval=5 run id status
  while [ "$elapsed" -lt "$max_wait" ]; do
    run=$(latest_run "$job_name")
    id="${run%% *}"; status="${run#* }"
    [ -n "$run" ] && [ "$id" != "$before" ] || status=""
    case "$status" in
      *[Rr]unning*|"") ;;
      *)
        echo "${job_name} finished (job_status=${status})."
        return 0
        ;;
    esac
    sleep "$interval"
    elapsed=$((elapsed + interval))
    echo "  ...still running (${elapsed}s elapsed)"
  done
  echo "Timed out after ${max_wait}s waiting for ${job_name}; check ${FESS_ENDPOINT}/admin/joblog/" >&2
  return 1
}

crawl_before=$(latest_run "Default Crawler"); crawl_before="${crawl_before%% *}"
echo "Starting the Default Crawler (${scheduler_id})..."
fessctl scheduler start "$scheduler_id" -o json \
| python3 -c '
import sys, json
d = json.load(sys.stdin).get("response", {})
if d.get("status") != 0:
    sys.stderr.write("fessctl: " + str(d.get("message", "start failed")) + "\n")
    sys.exit(1)
' || die "failed to start the crawler."

if [ "$wait_for_crawl" -ne 1 ]; then
  echo "Crawl started (--no-wait). Progress: ${FESS_ENDPOINT}/admin/scheduler/ — results: ${FESS_ENDPOINT}/"
  exit 0
fi

echo "Waiting for the crawl to finish (polling job log)..."
wait_job "Default Crawler" "$crawl_before" || exit 1

# --- generate the chunk vectors (the semantic half of the hybrid search) ---
# Fess embeds documents only from the Content Chunk Vector Indexer job, never at
# crawl time, and ships that job disabled. Enable it hourly so later crawls get
# vectors too, then run it once now. A freshly enabled job becomes startable
# only after the scheduler picks it up (scheduler.monitor.interval, 30s), so
# the start is retried.
vector_job_id="content-chunk-vector-indexer"
vector_job_name="Content Chunk Vector Indexer"
echo "Enabling the ${vector_job_name} (${vector_job_id})..."
fessctl scheduler update "$vector_job_id" --available --cron-expression "${VECTOR_JOB_CRON:-0 * * * *}" -o json \
| python3 -c '
import sys, json
d = json.load(sys.stdin).get("response", {})
if d.get("status") != 0:
    sys.stderr.write("fessctl: " + str(d.get("message", "update failed")) + "\n")
    sys.exit(1)
' || die "failed to enable ${vector_job_id}."

vector_before=$(latest_run "$vector_job_name"); vector_before="${vector_before%% *}"
echo "Starting the ${vector_job_name}..."
started=0
for _ in $(seq 1 12); do
  if fessctl scheduler start "$vector_job_id" -o json 2>/dev/null | python3 -c '
import sys, json
sys.exit(0 if json.load(sys.stdin).get("response", {}).get("status") == 0 else 1)
' 2>/dev/null; then
    started=1
    break
  fi
  sleep 10
done
[ "$started" -eq 1 ] || die "could not start ${vector_job_id}; start it from ${FESS_ENDPOINT}/admin/scheduler/."
wait_job "$vector_job_name" "$vector_before" || exit 1
echo "Results: ${FESS_ENDPOINT}/"
