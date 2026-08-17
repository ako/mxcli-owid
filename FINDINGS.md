# FINDINGS

Durable notes for the next session. Append, don't rewrite.

**Versions.** Mendix 11.13.0 · mxcli built from source at `ako/mxcli` main,
commit `5c70014`, reported version `5c70014 (2026-08-17T11:58:55Z)` · DuckDB CLI
1.5.5 · DuckDB JDBC 1.4.1.0 · ANTLR 4.13.2 · Go 1.24.7 · OpenJDK 21.0.10.

---

## 1. Building mxcli from ako/mxcli main

`go install …@latest` does not work — the generated ANTLR parser is not
committed. The build is a two-step:

```bash
pip install 'antlr4-tools==0.2.2'
export ANTLR4_TOOLS_ANTLR_VERSION=4.13.2   # pinned; must match go.mod runtime 4.13.1
make grammar && make build                  # -> bin/mxcli (88 MB)
```

`make grammar` needs a JVM *and* network (antlr4-tools downloads
`antlr4-4.13.2-complete.jar` on first run). Both steps succeeded unmodified.
**Verified:** `./mxcli --version` → `mxcli version 5c70014`; the whole
`new → init → run --setup` path then worked normally.

`.claude/bootstrap-mxcli.sh` was **edited away from the generated default**,
which downloads the `mendixlabs` nightly. It now builds `ako/mxcli` main from
source and only falls back to the nightly when Go, a JVM or the network is
missing. Worth knowing if the hook ever seems slow on a fresh clone: the source
build takes a few minutes, the nightly download seconds.

## 2. `mxcli new` into a git repo — confirmed as documented

`mxcli new` refuses a non-empty directory, and a git repo always has `.git`. The
create-in-subfolder-then-move dance worked as written. The hardlink note is real:
`OwidExplorer/mxcli` is a hardlink to the `./mxcli` you invoked, and `mv` refuses
it as "the same file" — `rm -f` it first.

After the move, `.claude/bootstrap-mxcli.sh` correctly named `OwidExplorer.mpr`;
no fixup needed. `mxcli init --tool claude` is idempotent as advertised.

## 3. The External Database Connector is not usable here — two independent blockers

The request was to query OWID live "using external database connector and
duckdb". Both halves of that ran into walls, and the resolution was to keep
DuckDB and drop the connector.

**Blocker A — mxcli cannot author the document.** `SHOW DATABASE CONNECTIONS` and
`SELECT * FROM CATALOG.…` can *read* external database connections, but MDL has
no `CREATE DATABASE CONNECTION`. mxcli's own docs are explicit:
`docs/01-project/MISSING_CAPABILITIES.md` lists
`DatabaseConnector$DatabaseConnection` under missing document types, "listing
only", and `MDL_FEATURE_MATRIX.md` marks *Ext. DB connector* unsupported across
every write backend. So the connection would have to be created by hand in
Studio Pro — impossible in a headless Linux session.

**Blocker B — no DuckDB driver.** The marketplace External Database Connector
ships a fixed set of JDBC drivers chosen from a database-type dropdown
(PostgreSQL, MySQL, SQL Server, Oracle, Snowflake, Databricks, SAP HANA). DuckDB
is not among them and there is no generic-JDBC option, so even a hand-built
connection could not point at DuckDB.

**What was done instead.** DuckDB runs *inside the Mendix runtime* — the DuckDB
JDBC driver in `userlib/`, driven by a Java action. This is strictly more
capable for this use case: it keeps DuckDB (so `httpfs` reads the OWID parquet
directly), needs no external database server, and is fully authorable headless
because mxcli can create Java actions.

**Verified:** a standalone JVM test (`TestDuck.java`, JDK 21) loaded `httpfs`
in ~1.1 s and returned real WDI rows for Brazil and Japan in ~1.7 s over
`jdbc:duckdb:` — an in-memory DuckDB with no local data file.

> Note for mxcli: `CREATE DATABASE CONNECTION` would be a genuinely useful MDL
> addition — the connector is otherwise a Studio-Pro-only island.

## 4. OWID's published catalog index is stale — use the per-channel indexes

`https://catalog.ourworldindata.org/catalog.feather` (the documented index,
`format_version: 3`) lists only **215** `garden/` entries, mostly a 2021 food
explorer, and advertises `feather`/`csv` only — **no parquet at all**. Taken at
face value it says the parquet files this project depends on do not exist.

They do. The per-channel indexes are current and *do* list parquet:

| index | rows | formats |
| --- | --- | --- |
| `catalog-grapher.feather` | 43,817 | `[feather, parquet]` |
| `catalog-garden.feather` | — | `[feather, parquet]` |
| `catalog-meadow.feather` | — | `[feather, parquet]` |

These are not linked from `catalog.meta.json`; they were found by probing.
Bucket listing is disabled (`?list-type=2` → Cloudflare 404), so probing was the
only route. **Use `catalog-<channel>.feather`, never `catalog.feather`.**

The `arrow` DuckDB extension is unavailable for CLI v1.5.5 linux_amd64 (404 from
`extensions.duckdb.org`), so the feather indexes were read with Python pyarrow,
not DuckDB. Parquet itself needs no extension beyond bundled `parquet` +
`httpfs`.

## 5. GDP per capita: WDI's PPP series is half-empty before 1990

The obvious column, WDI `ny_gdp_pcap_pp_kd`, gave only **53.1 %** coverage over
1960–2023 — it effectively starts in 1990, which would have left the dashboard's
flagship income-vs-life-expectancy chart empty for the first thirty years.

Switched to the **Maddison Project Database**
(`ggdc/2024-04-26/maddison_project_database`, column `gdp_per_capita`) — one
consistent series 1960–2022, **98.4 %** coverage, and the source OWID itself uses
for long-run GDP. Splicing WDI-recent onto Maddison-historical was rejected: a
join seam is exactly the artifact a comparison-over-time chart would show.

Caveat: Maddison is in **2011 int-$**, while the mockup labels GDP
"int-$ (2017 PPP)". The axis label must be corrected to match the data.

## 6. Mean years of schooling arrives on five-year anchors

No single OWID table has it yearly. `undp_hdr` (both grapher and garden) has no
`mys` column at all; the Wittgenstein Center table has only education-share
columns. OWID's own chart `mean-years-of-schooling-long-run` is built on
Barro-Lee + Lee-Lee.

`education/2023-07-17/education_lee_lee` stops at **2010** — NULL for every
recent year. `education/2023-07-17/education_barro_lee_projections` carries the
same column name and covers **1960–2020 in 13 five-year steps**, so it alone
spans the range. Values from 2015 on are *projections*, per OWID's own note.

Interpolated linearly between anchors in SQL and held flat after 2020 (so
2021–2023 repeat the 2020 value — visible as a flat tail in the schooling
series). **Verified:** Brazil 1960 → 2023 reads 2.53 / 4.12 / 6.76 / 8.00 / 8.00,
a smooth curve with the expected plateau.

## 7. Live-query latency is acceptable, but not per-request

Against the remote parquet, cold: **8.5 s** for the full nine-indicator join
(1,728 rows). Warm within one DuckDB session: **2.8 s** full extract, **1.3 s**
single year. Fine for a refresh action; far too slow to serve a chart request.

Hence: DuckDB materializes into Mendix entities once, and OData serves from
there. "Live" means *re-runnable on demand against current OWID data*, not
*fetched per request*.

## 8. Remaining data gaps are real OWID gaps, not bugs

Coverage over the 1,728 country-year cells: pop 100 %, fertility 100 %, life
expectancy 100 %, GDP 98.4 %, child mortality 95.7 %, schooling 92.6 %, food
91.9 %, energy 87.6 %, CO₂ 84.4 %. Energy and CO₂ thin out in the early 1960s;
FAO food supply starts in 1961. The UI must render nulls as "—" rather than zero
— a zero here would read as a real measurement.

## 9. Country naming: OWID's harmonized names ≠ the mockup's labels

OWID uses `Turkey` (not `Türkiye`), `Democratic Republic of Congo` (not
`DR Congo`), `South Korea`, `Russia`, `Vietnam`. The 27-country roster therefore
stores **both** an `OwidName` (the fetch key) and a `DisplayName` (the label).

The roster also carries the **ISO numeric** code, which the choropleth needs to
join against world-atlas topojson. OWID's `reference/countries_regions.csv` has
`iso_alpha2`/`iso_alpha3` but **no numeric code**, and no continent column — so
country → region and country → ISO-numeric are app reference data, seeded, not
fetched.

## 10. Environment notes

- DuckDB `httpfs` reached `catalog.ourworldindata.org` from inside the JVM
  without any explicit proxy configuration. It does **not** read the JVM's
  `-Dhttps.proxyHost` settings — it has its own HTTP client — so if a future
  environment blocks direct egress, set DuckDB's own
  `SET http_proxy = …` rather than relying on `JAVA_TOOL_OPTIONS`.
- The DuckDB JDBC jar is **81 MB**. It goes in `userlib/` and will be committed
  unless deliberately excluded — worth a conscious decision, since it dwarfs the
  rest of the repo.

## 11. Publishing OData from pure MDL: avoid association nav properties

mxcli's own `mendix-vega-charts` skill pack records that an OData service
authored purely in MDL could not be built: the service's *association
representation* defaults to "associated object ID", CE7375 then demands the
entity's own `ID` as key, and that representation is **not a property MDL can
set**. Their note says it needs one manual fix in Studio Pro — impossible here.

Designed around it rather than into it: `PublishAssociations: No`, and
country name / ISO numeric / region are **denormalized onto `Observation`**.
Vega binds to a flat row anyway (`{country, id, region, year, pop, …}` — exactly
the mockup's `window.OWID.rows` shape), so the flattening removes a client-side
join as well as the blocker. The `Observation_Country` association still exists
for model integrity; it is simply never published. Same for `Topic`, which
carries `XKey`/`YKey` strings instead of two references to `Indicator`.

**Not yet verified** — this is a design decision taken from the skill pack's
report. Confirm it survives `mxcli check` and a real build.

## 12. Vega fetches an OData feed exactly once

From the same skill pack: with `chartData` unbound, the widget passes the spec
through and Vega's own loader fetches the URL. It does **not** follow
`@odata.nextLink`. A chart pointed at a paged endpoint silently plots the first
page and looks fine.

At 13,760 rows this is a live risk, so every figure caps its own request with
`$filter`/`$top` rather than trusting `PageSize`. The single-year figures (map,
ranked, distribution, table) pull ~215 rows; only the sparkline and focus-line
figures need a full series, and those filter by country.

Also from that pack: same-origin requests carry the session cookie, so a
session-authenticated endpoint is reachable from a chart in the same app. Not
needed here — security is off — but it is why the URL form is viable at all.

## 13. Widening to all countries changes the coverage picture

Switching from the mockup's 27-country sample to all OWID countries:

- OWID's regions table has **276** countries, but 243 survive a join to an ISO
  numeric code and **215** carry any observations at all. The other 61 are
  territories (Tokelau, Vatican, Norfolk Island) with no WDI/Maddison series.
  Filtering to "has population and (GDP or life expectancy)" is what keeps a
  country out of the picker and off the ranked chart.
- Coverage across 13,760 country-year cells: population / life expectancy /
  fertility 99.8 %, child mortality 84.5 %, CO₂ 79.7 %, food 73.2 %, GDP 72.7 %,
  energy 70.1 %, schooling 67.0 %. GDP and schooling fall because Maddison and
  Barro-Lee cover fewer countries than the WDI — a real source limit, not a bug.
- OWID uses **six** continents (North and South America split); the mockup's
  palette has five. North + South America are folded to `Americas`.
- Full extract now ~4 s cold against the remote parquet.

**Verified:** 215 countries, 13,760 rows, coverage as above.

## 14. mxcli silently drops OnChange on combobox, radiobuttons and checkbox

The dashboard's controls did nothing. The MDL parsed, `mxcli check` passed, and
`exec` reported success — but `DESCRIBE PAGE` showed the property was never
written:

```
-- written:
radiobuttons rbTopic (Label: 'Topic', Attribute: TopicSel, Class: 'owid-topics')
combobox     cbTopic (Label: 'Topic', Attribute: TopicSel, Class: 'owid-topics')
checkbox     cbAfrica (Label: 'Africa', Attribute: ShowAfrica)
-- but authored with:
   OnChange: MICROFLOW Owid.ACT_Apply(State: $currentObject)
```

**Verified** in the browser: clicking a radio checked it but produced **zero**
`/xas/` requests — no server round-trip at all. `textbox` and `actionbutton`
keep their actions; those three drop them. Silently, which is the expensive
part: nothing in check/exec/lint flags it, and the page looks correct.

Worked around with an explicit **Apply** button (an `actionbutton`, which
works). The year textbox and the year step buttons still update immediately.

> For mxcli: either write the property or fail loudly. A dropped event handler
> on a page that otherwise builds is very hard to attribute.

## 15. The grid belongs on `.mx-dataview-content`, not on the data view

`.owid-page` was `display: grid` and a full 1632 px wide, yet every figure
stacked in one ~330 px column. Mendix nests all of a data view's widgets inside
a `.mx-dataview-content` wrapper, so the grid had exactly **one** child.

Fix: `.owid-page > .mx-dataview-content { display: grid; ... }`. Same for the
responsive overrides. Worth knowing before debugging CSS that is already correct.

## 16. A changed non-persistable object needs `CHANGE ... REFRESH`

Controls that did reach the server still left the page showing stale payloads:
`CHANGE $State (...)` without `REFRESH` does not tell the client to re-read the
object, and a data view over a non-persistable object has nothing else to
trigger on. `CHANGE $Obj (...) REFRESH;` is the "Refresh in client" flag.

## 17. `mxcli run --local` will not take over a port it already owns

Re-running `run --local` after an edit fails with *"port 8080 (app) is already
in use ... That is not a process mxcli started"* — it will not adopt or replace
the previous runtime, deliberately. The previous JVM and the `mxbuild --serve`
process must be killed first. Note that `pkill -f "mxcli run"` matches the shell
running it and kills your own command; match the java/mxbuild processes instead.

## 18. Vendor the fonts and the topojson — the browser has no egress

The runtime is reachable but the *browser* in this environment cannot reach
`fonts.googleapis.com` or `cdn.jsdelivr.net`. Two consequences, both silent:
Barlow fell back to a system sans, and the choropleth rendered **8 marks**
instead of 335 because the world-atlas topojson never arrived.

Both are now vendored under `theme/web/vendor/` (Mendix copies `theme/web/**`
into `deployment/web/`, so they serve from the app at `/vendor/...`). A font or
map that silently degrades is worse than one that fails loudly, so this is not
just an offline nicety.

## 19. Maddison's GDP ends in 2022, so the dashboard opens on 2022

At year 2023 the flagship income-vs-life-expectancy figure was **empty**: every
GDP value is null, so the `datum.x != null` filter removed every mark. The year
range stays 1960–2023 (life expectancy, population and fertility do reach 2023),
but the opening year is `YearTo - 1`. Anything plotting GDP at 2023 will be
blank — that is the source, not a bug.
