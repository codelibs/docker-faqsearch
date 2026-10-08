# FAQ Search on Fess (helpdesk theme demo)

[Fess](https://fess.codelibs.org/) is an Enterprise Search Server. This Docker
environment is a demo/reference deployment of Fess's **`helpdesk`** static
theme (from [fess-themes](https://github.com/codelibs/fess-themes)) — a
self-contained FAQ / support-site search UI where a search result **is** the
answer: clicking a result expands its excerpt inline, with no page
navigation. It crawls a small bundled FAQ site (`data/content/`, served by a
local nginx container) so the whole thing runs standalone, with no external
dependencies.

Search is **hybrid**: every question is answered by keyword (BM25) search and
by vector search over a multilingual embedding model at the same time, and
OpenSearch fuses the two rankings in a single request (Fess 15.9 engine-side
rank fusion). A question that shares no word with the FAQ — "I forgot my login
credentials", "月額料金はいくら" — still finds the right answer, in either
language. The embedding model runs inside OpenSearch (ML Commons), so the demo
stays self-contained.

## Architecture / Theme Model

- **Theme**: Fess static theme system (15.7+) — `theme.default=helpdesk` in
  `system.properties` selects the helpdesk theme. **This is a system
  property, not a `fess_config.properties` key** — see
  `Constants.DEFAULT_THEME_PROPERTY` / `FessProp.getDefaultTheme()` /
  `ThemeRegistry` in the Fess source. It lives in
  `data/fess/opt/fess/system.properties.template` and is applied via
  `data/fess/opt/fess/system.properties` (generated from the template by
  `setup.sh` on first run, then live/git-ignored). Putting `theme.default` in
  the `fess_config.properties` overlay has **no effect** — Fess never reads
  it from there.
- **Content**: a small nginx container (`content` service) serves
  `data/content/` — 12 FAQ pages (6 Japanese, 6 English) plus an
  `index.html` hub linking all of them (crawled for its links, not indexed:
  it lists every question, so it would match almost any search) — over plain HTTP at
  `http://content/`. Fess crawls it as a **WebConfig**, not a data-store
  connector: there is no Git repository or database behind this demo, just
  static HTML, so the crawl target must be reachable over HTTP for the
  cached-page feature (`crawler.document.cache.supported.mimetypes` is
  `text/html`) — a `file://` crawl would leave documents without a cache and
  break the theme's "View original page" link, which depends on it.
- **Fess config (`fess_config.properties`)**: `setup.sh` generates
  `data/fess/opt/fess/fess_config.properties` from the upstream base for the
  pinned Fess version plus the faqsearch overlay
  (`conf/fess_config.overlay.properties`) and an optional local override
  (`conf/fess_config.local.properties`). It is mounted at `/opt/fess`, which
  the image places ahead of its `/etc/fess` default on the classpath, so the
  generated file takes effect. Only the delta is tracked in git; the base
  auto-tracks the pinned version. See
  [Required Fess settings](#required-fess-settings) below.
- **Version pins (`.env`)**: `FESS_VERSION` / `OPENSEARCH_VERSION` /
  `NGINX_IMAGE` are the single source of truth for the image tags
  (`compose.yaml`) and the `fess_config.properties` base. `.env` is
  git-ignored; `setup.sh` bootstraps it from the tracked `.env.example` on
  first run, and both `compose.yaml` and `render-fess-config.sh` fall back to
  the same defaults when it is absent.
- **system.properties**: The live file
  (`data/fess/opt/fess/system.properties`) is generated from
  `data/fess/opt/fess/system.properties.template` by `setup.sh` on first
  run. The live file is git-ignored.
- **Theme files**: The helpdesk static theme is fetched from
  [fess-themes](https://github.com/codelibs/fess-themes) by `setup.sh` and
  stored in `data/fess/themes/helpdesk/`. This directory is mounted into the
  container at `/usr/share/fess/app/themes/helpdesk`.
- **Network**: `fess01`, `search01`, and `content` all join a dedicated
  bridge network (`faqsearch_net`) so `fess01` can resolve `http://content/`
  by container name. `fess01` waits on `content`'s healthcheck
  (`depends_on: content: condition: service_healthy`) so the crawler never
  races nginx's startup.
- **Hybrid search**: see [Hybrid search](#hybrid-search) below. In short:
  the one-shot `init-semantic` service registers and deploys the embedding
  model in OpenSearch ML Commons and writes its id to `data/semantic/model_id`;
  `bin/fess-entrypoint.sh` passes that id to Fess; Fess splits each FAQ into
  chunks and stores their vectors (Content Chunk Vector Indexer job); and
  `rank.fusion.engine.enabled=true` makes each search one OpenSearch `hybrid`
  query.
- **Management CLI (`fessctl`)**: The WebConfig and the demo seed data
  (labels, related content, related query, search-log/suggest seeding) are
  registered with [`fessctl`](https://github.com/codelibs/fessctl), the
  official Fess admin-API CLI (see [Install fessctl](#install-fessctl)).

## Getting Started

### Setup

```bash
$ git clone <this-repo-url> docker-faqsearch   # or use your local checkout
$ cd docker-faqsearch
$ bash ./bin/setup.sh
```

> **Working on the theme itself?** `setup.sh` fetches `helpdesk` from the
> `main` branch of the public fess-themes repo by default. Override either end
> to test unreleased theme changes — `FESS_THEMES_REPO` accepts anything
> `git clone` does, including a local filesystem path:
>
> ```bash
> FESS_THEMES_REPO=/path/to/local/fess-themes \
> FESS_THEMES_BRANCH=my-theme-branch \
>   ./bin/setup.sh
> ```

`setup.sh` will:
1. Create required data directories
2. Fetch the helpdesk static theme from fess-themes (if not already present)
3. Generate `data/fess/opt/fess/system.properties` from the template (if not
   already present) — this is where `theme.default=helpdesk` lives
4. Generate `data/fess/opt/fess/fess_config.properties` from the pinned base
   + faqsearch overlay

### Start the Server

```bash
docker compose -f compose.yaml up -d --wait
docker compose ps   # init-semantic "exited (0)"; the others healthy
```

The **first** start downloads the embedding model (~490 MB) inside OpenSearch;
`fess01` starts only after `init-semantic` has deployed it (a few minutes on
the first run, seconds afterwards — the deployed model is reused).
OpenSearch runs with a 2 GB heap (`OPENSEARCH_HEAP`) because it hosts the model.

Once running, access Fess at [http://localhost:8080/](http://localhost:8080/)
— it should render the **helpdesk** theme immediately (home view with
category tiles), even before anything is crawled. If it renders `docuforge`,
a blank page, or any theme other than `helpdesk`, **suspect
`data/fess/opt/fess/system.properties`'s `theme.default` value first** — see
[Architecture](#architecture--theme-model) above; this is the single most
common way to misconfigure this demo.

### Create an Access Token

`fessctl` authenticates to Fess with an access token. Create one with the
`{role}admin-api` permission on the Admin Access Token page
([http://localhost:8080/admin/accesstoken/](http://localhost:8080/admin/accesstoken/)).
For more details, see the
[Admin Access Token Guide](https://fess.codelibs.org/15.7/admin/accesstoken-guide.html).

### Install fessctl

```bash
pipx install fessctl      # or: uv tool install fessctl
```

`fessctl` requires Python 3.13+ (`pipx` / `uv` provide it automatically).
Point it at the server and the access token created above:

```bash
export FESS_ENDPOINT=http://localhost:8080
export FESS_ACCESS_TOKEN=<your-access-token>
fessctl ping    # reports the search engine status (GREEN when ready)
```

### Register and crawl the FAQ content

Unlike the other `docker-*` demos, this one needs a **web crawl config**
(`WebConfig`), not a data-store connector — there is no precedent for this
in the sibling repos (`docker-codesearch` registers a Git data-store config;
`docker-docsearch` leaves this to the admin UI). `bin/register-faq-crawl.sh`
registers `http://content/` as a `WebConfig`, starts the Default Crawler
(scheduled job id `default_crawler`) and polls until the crawl finishes. It
then enables the **Content Chunk Vector Indexer** (`content-chunk-vector-indexer`,
shipped disabled; set to run hourly so later crawls get vectors too) and runs
it once — Fess computes vectors only in that job, never at crawl time, so
without it search stays keyword-only:

```bash
FESS_ACCESS_TOKEN=<your-access-token> ./bin/register-faq-crawl.sh
```

Re-running it is safe — it updates an existing `WebConfig` named
`faq-content` to the settings of the script (URL, included URL, excluded
document URL, depth, maximum access count, permission) and always (re-)starts
the crawl and the vector job. Documents that are already indexed are not
removed when a setting changes. The script exits with a non-zero status and
says why when the crawl fails, or when the vector job reports `ok` but leaves
the documents without vectors (it skipped its run).

### Seed labels, related content, and popular searches

```bash
FESS_ACCESS_TOKEN=<your-access-token> ./bin/seed-faq.sh
```

This registers the data the helpdesk theme is designed around (see
[Admin-panel registration](#admin-panel-registration-seeded-by-bin-seed-faqsh)
below) and seeds enough search-log history for "Popular searches" to show
something on a fresh instance — see
[Why seed-faq.sh seeds search logs](#why-seed-faqsh-seeds-search-logs) for
why that step is otherwise unavoidable. Re-running the script is safe: it
creates only what is missing (labels are matched by value, related content and
related queries by term) and issues the search-log rounds again.

### Search

View search results at [http://localhost:8080/](http://localhost:8080/).

### Stop the Server

```bash
docker compose -f compose.yaml down
```

## Required Fess settings

**These are required, not optional — the helpdesk theme does not render
usable answers on stock Fess defaults.** `conf/fess_config.overlay.properties`
sets all of them; this section explains *why*, since the reasons are
non-obvious (they duplicate the theme's own README —
[fess-themes/themes/helpdesk/README.md](https://github.com/codelibs/fess-themes/blob/main/themes/helpdesk/README.md)
— for anyone reading only this repo):

```properties
# helpdesk renders content_description AS the answer, expanded inline. Stock
# defaults give a ~120-char teaser with its opening clause removed.
query.highlight.fragment.size=2000
query.highlight.number.of.fragments=1

# THE non-obvious one. With the default `true`, ViewHelper.escapeHighlight()
# walks backward from the FIRST match to the nearest "terminal" character
# (query.highlight.terminal.chars, which includes U+002C, a COMMA, and
# sentence-ending punctuation) and discards everything before it. So the
# beginning of the answer is silently cut off whenever the query term isn't
# in the answer's first clause/sentence — and no fragment.size fixes that,
# because the cut happens before fragment.size is even applied.
query.highlight.boundary.position.detect=false

# Category tiles link to /search?q=&fields.label=X — no query terms, so
# nothing matches `content`, so no highlighted fragment is produced at all,
# and the answer falls back to `digest` (capped at
# crawler.document.html.max.digest.length). fragment.size has ZERO effect on
# this path; only no.match.size controls it.
query.highlight.no.match.size=2000

# Raises the floor for the digest fallback above. Crawl-time: requires a
# re-crawl to take effect on already-indexed documents.
crawler.document.html.max.digest.length=500
```

`fragment.size` and `no.match.size` above (`2000`) are a generous starting
point for this demo's short FAQ answers (200–400 characters); tune them down
once you've measured real answer lengths in your own content, per the theme
README's guidance — `query.highlight.fragment.size` is a **global** server
setting, so raising it increases every search response's payload size, not
just helpdesk's.

**Secrets / per-deployment values** (the cipher key, the initial admin
password) must **not** go in the tracked overlay. Create
`conf/fess_config.local.properties` (git-ignored) — its keys are applied
last and win:

```properties
app.cipher.key=your-secret-key-here
index.user.initial_password=your-admin-password
```

> The cipher key encrypts stored credentials; set it **before first boot**,
> because changing it later invalidates already-encrypted data.

## Hybrid search

### What is configured where

| Setting | Where | Value |
|---|---|---|
| Embedding model | `.env` `MODEL_NAME` / `MODEL_DIMENSION` | `paraphrase-multilingual-MiniLM-L12-v2`, 384 dimensions |
| `content_chunker.*` (chunking, vectors, kNN) | `compose.yaml` `FESS_JAVA_OPTS` as `-Dfess.system.*` | `enabled`, `search.enabled`, `embedding.name=opensearch`, `chunk_size`, `knn.k`, `min_score` |
| Model id | `data/semantic/model_id` → `bin/fess-entrypoint.sh` | generated by `init-semantic` |
| `rank.fusion.engine.enabled=true`, `combination.technique=rrf` | `conf/fess_config.overlay.properties` | engine-side fusion |
| `searcher` in API results | `conf/fess_config.overlay.properties` | shows which half matched a hit |

`content_chunker.*` is read **only** from the system-properties channel, so it
cannot go into `fess_config.properties`; and a value in
`data/fess/opt/fess/system.properties` would override the `-D` option, so keep
those keys out of that file. The index mapping (vector dimension, kNN engine)
is fixed when the index is created: change `MODEL_DIMENSION` or the model only
on a fresh index.

### Tuning for FAQ content

- **`SEMANTIC_MIN_SCORE` (default `0.3`)** is the minimum cosine similarity a
  FAQ needs to be returned by the vector half. A small corpus has no "far away"
  documents, so without a floor every question lists every FAQ. With the
  default model, correct paraphrases score 0.27–0.77 and unrelated questions
  ("weather forecast tomorrow") stay below 0.2; the default gives up the
  weakest paraphrases (e.g. "解約したい", 0.27) to keep unrelated questions out. Scores are model-specific:
  re-measure after changing `MODEL_NAME`.
- **`CHUNK_SIZE` (default `1000`)** must be at least as long as your longest
  answer. Once a document is chunked, Fess stores the chunks back into
  `content`; the helpdesk inline answer is one highlighted fragment, so with
  several chunks it shows only the chunk that matched and cuts the start of the
  answer. One chunk per FAQ keeps the whole answer, and the model embeds its
  first 128 tokens — the question and the start of the answer — while the
  keyword half still matches the rest.

### When a search is not fused in OpenSearch

The keyword and vector halves are fused in one `hybrid` query except for:
requests with an explicit `sort`, advanced-search `as.*` parameters, or a page
beyond `rank.fusion.pagination_depth` (200) — Fess then fuses the two result
lists itself — and requests with no free text to embed, which are answered by
the keyword half alone: the category tiles (`q=` with `fields.label=`), and
queries that use query syntax on the text such as quoted phrases, wildcards or
`NOT`.

### Checking that it works

```bash
curl -s 'http://localhost:8080/api/v2/search?q=I+forgot+my+login+credentials' \
  | jq '.response.data[] | {url, searcher}'
```

`searcher` lists the halves that matched each hit: `default` (keyword),
`semantic_chunk` (vector), or both. A question with no shared keyword should
still return the password FAQ, with `searcher` = `["semantic_chunk"]`.

### system.properties

To modify system-level Fess settings (including `theme.default`), edit
`data/fess/opt/fess/system.properties.template` and re-run `setup.sh`, or
edit the live `data/fess/opt/fess/system.properties` directly. The live file
is git-ignored.

## Admin-panel registration (seeded by `bin/seed-faq.sh`)

The helpdesk theme's home view and result cards are driven entirely by data
an admin registers:

- **Labels** (`/admin/labeltype/`) — power both the home view's category
  tiles and the facet sidebar's Category group
  (`query.facet.fields=label`, set in the overlay above). `seed-faq.sh`
  registers labels such as "Account" / "Pricing" / "Data" / "Security" with
  `included_paths` regexes matching the corresponding FAQ URLs in both
  `/ja/` and `/en/`, then triggers the `label_updater` scheduled job so the
  labels apply retroactively to already-crawled documents without a
  re-crawl.
- **Related content** (`/admin/relatedcontent/`) — an admin-authored
  "Featured answer" card shown above results for a matching search term.
  `seed-faq.sh` registers one exact-match term and one term with Fess's
  `regex:` prefix (e.g. `regex:.*password.*`, matched with a case-sensitive
  full-string `Pattern.matches()` against the query), to demonstrate both
  matching modes.
- **Related query** (`/admin/relatedquery/`) — related-search suggestions.
  `seed-faq.sh` registers exactly **one**, deliberately, because of the
  side effect below.

> **⚠️ Registering a related query changes the search results themselves,
> not just a UI suggestion chip.** Fess's `QueryStringBuilder`
> (`buildBaseQuery()`) OR-expands every registered related query into the
> actual search query sent to OpenSearch — the original query and each
> related query are combined with `OR` and executed as one search. This
> means a related-query registration changes **which documents match and how
> many results come back**, not merely what's suggested. `seed-faq.sh`
> registers only one, so you can see the effect directly; review any
> further related-query registrations with the same care as a query
> rewrite, because that's exactly what they are.

### Why seed-faq.sh seeds search logs

`popular_words` (the "Popular searches" section) reads from Fess's
**suggest index**, not from the documents themselves. On a freshly deployed
instance it always returns `[]`, even after a successful crawl, until all
three of these are true: `suggest.searchlog=true` (the default),
accumulated search-log history exists, and the suggest updater job
(scheduled job id `suggest_indexer`) has run at least once against that
history. `seed-faq.sh` issues a batch of representative queries against
`/api/v2/search` to build that history, then triggers `suggest_indexer` —
skip this step and "Popular searches" will stay empty indefinitely, which
looks like a bug but is actually just missing seed data.

**A second, non-obvious gate sits behind that one.** A query only counts as
"popular" once its `queryFreq` in the suggest index clears
`suggest.popular.word.query.freq` (Fess default: `10`). `queryFreq` is *not*
"number of times searched" — `SuggestHelper.indexFromSearchLog()` dedupes
rapid repeats from the same client (session id, or client IP + word for API
callers with no session) within a hardcoded 1-minute window before they're
even counted, so a seed script hammering the same query in a tight loop
produces `queryFreq=1` no matter how many times it repeats the request,
and can never clear a threshold of 10 in any reasonable amount of time. This
overlay lowers `suggest.popular.word.query.freq` to `2` — the same class of
demo-scale tuning as `adaptive.load.control` above: real production traffic
naturally spans minutes and sessions and would clear 10 on its own; this
demo's synthetic seed traffic does not. To reach `2`, `seed-faq.sh` sends
every query in two rounds one minute apart (`SEED_ROUNDS`, default `2`), so
the search-log step takes about a minute.

## Updating

```bash
git pull
```

Live/generated files (`system.properties`, `fess_config.properties`, theme
assets) are git-ignored and will not be overwritten by `git pull`. So is
`.env`: it keeps the pins it was created with, and `setup.sh` fetches the theme
only when `data/fess/themes/helpdesk` does not exist.

To upgrade the Fess / OpenSearch version, edit the pins in `.env`
(`FESS_VERSION`, `OPENSEARCH_VERSION`) — or delete `.env`, and `setup.sh`
recreates it from `.env.example` — and re-run `setup.sh`:

```bash
bash ./bin/setup.sh
docker compose -f compose.yaml up -d
```

`setup.sh` warns when the pins in an existing `.env` differ from `.env.example`.
Hybrid search needs Fess 15.9 or later: with an older Fess the stack still
starts and even deploys the embedding model, but Fess ignores the
`content_chunker.*` options and answers with keyword search only, without any
message.

> **A crawl does not change the index mapping**: the vector field and its
> dimension are fixed when the document index is created, so re-crawling with
> `register-faq-crawl.sh` does not add them to an existing index. Start from
> empty data or re-index, as described below.

### Coming from the keyword-only (Fess 15.7) version of this demo

That version's document index has no vector mapping, and its `.env` pins Fess
15.7.0 and OpenSearch 3.7.0. Two ways to move on:

**Start from empty data** (the demo holds nothing but the bundled FAQs):

```bash
docker compose -f compose.yaml down
git pull
rm -rf data/opensearch data/fess/home/fess data/fess/var data/fess/themes .env
```

Then run [Getting Started](#getting-started) again. Deleting `.env` lets
`setup.sh` recreate it from `.env.example` (note any value you changed first)
and deleting `data/fess/themes` fetches the current theme. The access token,
labels and crawl config live in OpenSearch, so create them again as Getting
Started describes.

**Keep the documents** (and the access token, labels and crawl config):

1. Update the code, the pins and the theme, and start the new versions:

   ```bash
   docker compose -f compose.yaml down
   git pull
   rm -rf data/fess/themes .env
   bash ./bin/setup.sh
   docker compose -f compose.yaml up -d --wait
   ```

2. In the admin console ([http://localhost:8080/admin/](http://localhost:8080/admin/)),
   open System Info → Maintenance, tick "Replace Aliases" and press "Start"
   under "Re-indexing". It copies the documents into a new index created with
   the current mapping (the vector field and `index.knn`) and points
   `fess.search` at it.
3. Fess 15.7 saved its bundled scheduled jobs with the `groovy` execution
   method, which Fess 15.9 no longer has built in, so the Default Crawler and
   12 other jobs fail (the Fess log says `Settings use the script engine groovy,
   which is not registered`). With [fessctl](#install-fessctl) and an
   [access token](#create-an-access-token) set up, switch them to JavaScript:

   ```bash
   fessctl scheduler list -o json \
     | jq -r '.response.settings[] | select(.script_type == "groovy") | .id' \
     | xargs -n1 -I{} fessctl scheduler update {} --script-type javascript
   ```

   Thumbnail Purger and Index Exporter use Groovy-only syntax and keep failing;
   this demo uses neither.
4. The old crawl config does not exclude the hub page, so the index holds it
   (13 documents instead of 12). In Crawler → Web → `faq-content` set
   "Excluded Doc URLs" to `http://content/(index\.html)?`, then delete the
   hub document under System Info → Search (query `url:"http://content/"`):
   a crawl does not remove a document that is already indexed.
5. Run `FESS_ACCESS_TOKEN=<your-access-token> ./bin/register-faq-crawl.sh`.
   After the crawl it runs the Content Chunk Vector Indexer, which adds the
   vectors to the copied documents. Then
   [check that it works](#checking-that-it-works).
