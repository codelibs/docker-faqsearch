#!/usr/bin/env bash
# Seed labels, related content and enough search-log history for popular words.
#
# popular_words reads the SUGGEST index, not the documents. It needs
# suggest.searchlog=true (default), accumulated search logs, AND a suggest
# updater run. A fresh instance always returns [] until all three happen.
#
# Run this AFTER bin/register-faq-crawl.sh has finished at least one crawl
# (labels are backfilled onto already-indexed documents via the
# label_updater scheduled job, so a prior crawl is not strictly required,
# but search-log seeding below is only meaningful once documents exist).
set -euo pipefail

usage() {
  cat <<'EOF'
seed-faq.sh — seed labels, related content, related query, and search-log
history for the helpdesk theme demo (via fessctl).

Usage:
  FESS_ACCESS_TOKEN=<token> ./bin/seed-faq.sh [options]

Options:
  --no-labels           Skip label registration
  --no-related          Skip related-content / related-query registration
  --no-searchlog        Skip search-log seeding + suggest update
  -h, --help            Show this help and exit

Environment:
  SEED_ROUNDS        Search-log seeding rounds, one minute apart (default: 2;
                     must reach suggest.popular.word.query.freq)
  FESS_ENDPOINT      Fess base URL (default: http://localhost:8080)
  FESS_ACCESS_TOKEN  Admin-api access token (required; consumed by fessctl)

Requirements: fessctl (https://github.com/codelibs/fessctl), curl, python3.
EOF
}

die() { echo "Error: $*" >&2; exit 1; }

do_labels=1
do_related=1
do_searchlog=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-labels)     do_labels=0; shift;;
    --no-related)    do_related=0; shift;;
    --no-searchlog)  do_searchlog=0; shift;;
    -h|--help)       usage; exit 0;;
    *)               usage >&2; die "unknown argument: $1";;
  esac
done

command -v fessctl >/dev/null 2>&1 || die "fessctl not found. Install with: pipx install fessctl (or: uv tool install fessctl). See https://github.com/codelibs/fessctl"
command -v curl    >/dev/null 2>&1 || die "curl not found."
command -v python3 >/dev/null 2>&1 || die "python3 not found."
[ -n "${FESS_ACCESS_TOKEN:-}" ] || die "FESS_ACCESS_TOKEN is not set (an admin-api access token, see /admin/accesstoken/)."
: "${FESS_ENDPOINT:=http://localhost:8080}"; export FESS_ENDPOINT

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

check_status() {
  # Reads a fessctl JSON response on stdin; exits non-zero (with the fessctl
  # message on stderr) unless response.status == 0. Prints nothing on success.
  python3 -c '
import sys, json
d = json.load(sys.stdin).get("response", {})
if d.get("status") != 0:
    sys.stderr.write("fessctl: " + str(d.get("message", "request failed")) + "\n")
    sys.exit(1)
'
}

# ---------------------------------------------------------------------------
# 1. Labels — power both the home view category tiles and the facet sidebar
#    Category group (query.facet.fields=label). included_paths match both
#    the /ja/ and /en/ copy of each topic, so one label covers both
#    languages. Value is the identifier used in fields.label=<value>; name
#    is only the display text.
# ---------------------------------------------------------------------------
if [ "$do_labels" -eq 1 ]; then
  echo "== Registering labels =="

  create_label() {
    local name="$1" value="$2" sort_order="$3"; shift 3
    local paths=("$@")
    local args=(--name "$name" --value "$value" --version-no 0 --sort-order "$sort_order" --permission "{role}guest" --created-time "$(now_ms)")
    for p in "${paths[@]}"; do
      args+=(--included-path "$p")
    done
    echo "  ${name} (value=${value})"
    fessctl labeltype create "${args[@]}" -o json | check_status
  }

  create_label "Account"  "account"  1 'http://content/(ja|en)/account-cancellation\.html'
  create_label "Pricing"  "pricing"  2 'http://content/(ja|en)/pricing-plan\.html'
  create_label "Data"     "data"     3 'http://content/(ja|en)/data-export\.html'
  create_label "Security" "security" 4 'http://content/(ja|en)/(password-reset|two-factor-auth)\.html'
  create_label "Browsers" "browsers" 5 'http://content/(ja|en)/supported-browsers\.html'

  # Labels are matched by URL at crawl time. Documents crawled BEFORE these
  # labels existed have no `label` field yet; the Label Updater job
  # (scheduled_job id: label_updater) re-evaluates label assignment for
  # already-indexed documents via an updateByQuery, without a re-crawl.
  echo "  Backfilling labels onto already-indexed documents (label_updater)..."
  fessctl scheduler start label_updater -o json | check_status || \
    echo "  WARNING: could not start label_updater (crawl may not have run yet); labels will still apply on the next crawl." >&2
fi

# ---------------------------------------------------------------------------
# 2. Related content — one exact-match "featured answer" and one regex:
#    match, to demonstrate both modes. RelatedContentHelper compares
#    "regex:"-prefixed terms with a case-sensitive Pattern.matches() (full
#    string match) against the query; the exact-match path is
#    case-insensitive.
# ---------------------------------------------------------------------------
if [ "$do_related" -eq 1 ]; then
  echo "== Registering related content =="

  fessctl relatedcontent create \
    --term "password reset" \
    --content '<p>Forgot your password? On the login screen, select <strong>Forgot your password?</strong> and follow the reset link emailed to you (valid for 24 hours).</p>' \
    --sort-order 1 \
    --created-time "$(now_ms)" \
    -o json | check_status

  fessctl relatedcontent create \
    --term 'regex:.*(cancel|退会).*' \
    --content '<p>Looking to cancel your account or complete 退会手続き? Export your data first from Settings, then use Settings &gt; Account &gt; Cancel Account. Cancellation takes effect immediately.</p>' \
    --sort-order 2 \
    --created-time "$(now_ms)" \
    -o json | check_status

  # -------------------------------------------------------------------------
  # 3. Related query — exactly ONE. See README: this OR-expands into the
  #    actual search query (QueryStringBuilder.buildBaseQuery()), changing
  #    which documents match, not just what's suggested. Registering more
  #    than one here without reading that section first is a mistake.
  # -------------------------------------------------------------------------
  echo "== Registering related query (1 only; see README for the side effect) =="
  fessctl relatedquery create \
    --term "password" \
    --queries "password reset" \
    --version-no 0 \
    --created-time "$(now_ms)" \
    -o json | check_status
fi

# ---------------------------------------------------------------------------
# 4/5. Search-log seeding + suggest update — popular_words needs actual
#    search-log history AND a suggest_indexer run; neither alone is enough.
#
#    THE NON-OBVIOUS PART: a query only counts as "popular" once its
#    queryFreq clears suggest.popular.word.query.freq (the overlay sets 2;
#    PopularWordsRequest.buildQuery() in fess-suggest adds
#    range(query_freq).gte(threshold)). queryFreq is not "times searched":
#    SuggestHelper.indexFromSearchLog() counts an API search again only when
#    the same client IP sent the same word more than one minute
#    (searchStoreInterval) after the last counted one. Repeating a query in a
#    tight loop therefore always yields queryFreq=1 — so each round below
#    issues every query once, and the rounds are one minute apart.
# ---------------------------------------------------------------------------
if [ "$do_searchlog" -eq 1 ]; then
  rounds="${SEED_ROUNDS:-2}"
  echo "== Seeding search-log history (${rounds} rounds, one minute apart; takes about $(( (rounds - 1) * 61 ))s) =="
  queries=(
    "password" "pricing" "export" "cancel" "browser" "パスワード" "料金" "退会"
  )
  total=0
  for round in $(seq 1 "$rounds"); do
    [ "$round" -gt 1 ] && sleep 61
    for q in "${queries[@]}"; do
      curl -s -o /dev/null -G "${FESS_ENDPOINT}/api/v2/search" --data-urlencode "q=${q}"
      total=$((total + 1))
    done
    echo "  round ${round}/${rounds}: issued ${#queries[@]} searches"
  done
  echo "  issued ${total} search requests (${#queries[@]} queries x ${rounds} rounds)"

  echo "  Rebuilding the suggest index from search logs (suggest_indexer)..."
  fessctl scheduler start suggest_indexer -o json | check_status
fi

echo "Done. Popular searches / category tiles / featured answers may take a"
echo "few seconds to appear while the scheduled jobs above finish running."
echo "Progress: ${FESS_ENDPOINT}/admin/scheduler/ — results: ${FESS_ENDPOINT}/"
