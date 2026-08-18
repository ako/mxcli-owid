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

## 3. ~~The External Database Connector is not usable here~~ — WRONG, see #20

**This finding is retracted. Both blockers below are false — see #20 for what
actually happens when you try it.** It is left in place because the reasoning
shows how a confident conclusion was reached from documentation alone without
running a single command, which is the mistake worth remembering.

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
- The DuckDB JDBC jar is **81 MB**. I first put it in `userlib/` and
  git-ignored it — **that was wrong, see #21**.

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

## 14. ~~mxcli silently drops OnChange on combobox, radiobuttons and checkbox~~ — FIXED upstream, see #26

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

## 20. RETRACTION of #3: the External Database Connector works, via BYOD

Finding #3 claimed two independent blockers. **Both were wrong**, and both were
asserted from reading docs rather than trying the command. Corrected by test:

**"mxcli cannot author a DatabaseConnection" — false.** `MDLService.g4` has
`createDatabaseConnectionStatement`, and it works:

```sql
create database connection Owid.OwidDuck
  type 'BYOD'
  connection string @Owid.DuckDbUrl
  username @Owid.DuckDbUser
  password @Owid.DuckDbPassword
begin
  query LifeExpectancyByYear
    sql $$SELECT country, year, sp_dyn_le00_in AS le FROM read_parquet('…') …$$
    returns Owid.DuckRow map (country as Country, year as Year, le as Le);
end;
```

`SHOW DATABASE CONNECTIONS` lists it, `DESCRIBE` round-trips it, and mxbuild
accepts it. The microflow side exists too: `EXECUTE DATABASE QUERY
Module.Connection.QueryName (…)`. I had grepped the docs
(`MISSING_CAPABILITIES.md`, `MDL_FEATURE_MATRIX.md`) and stopped there; **those
docs are stale**, and `mxcli syntax` has no `database-connection` topic, which
made the gap look real.

**"No DuckDB driver" — false.** Mendix has a **`BYOD`** type ("bring your own
driver") that skips the driver-presence check and takes the connection string
verbatim. mxcli's own linter says so, unprompted:

> type "duckdb" is not one Studio Pro offers … Use one of: 'MSSQL', 'MySQL',
> 'Oracle', 'PostgreSQL', 'Snowflake', 'BYOD'. For a JDBC driver Mendix has no
> entry for, use 'BYOD'. *(MDL-DB01)*

**Verified end to end.** `POST /odata/owid/QueryViaConnector` returns:

```json
{"value": "rows=25 first=Afghanistan le=61.454"}
```

— 25 rows read by the External Database Connector, through DuckDB's JDBC driver,
from OWID's parquet over `httpfs`. Afghanistan's 2020 life expectancy is 61.45.
Note this needs **no** DatabaseConnector marketplace module in the project; the
connector runtime is part of the platform.

### Two traps on the way, both of which build green

1. **The connection string must be a constant reference, not a literal.** A
   literal produces a project that *cannot be opened at all* —
   `StorageLoadException: "is not a valid ConstantIdentifier"`. mxcli's linter
   catches this (MDL058); mxbuild does not.
2. **`username`/`password` must reference constants even when the driver needs
   neither.** Omitting them writes `username @` with an empty reference, the
   build stays green, and the query fails only at run time with
   `ExternalDatabaseConnector: Could not find value for constant ''`.

### What this means for the app

The DuckDB-inside-a-Java-action path (#3's "what was done instead") still drives
the dashboard: it does the whole nine-source harmonization, which is far more
than one connector query expresses. But the connector was never the blocker it
was reported to be, and `Owid.OwidDuck` now exists in the model as a working
second path, exercised by `ACT_QueryViaConnector`.

**Lesson, not incidental:** every claim in #3 was checkable in about five
minutes. "The docs say it is unsupported" is a hypothesis, not a finding.

## 21. Don't hand-drop jars in userlib/ — declare them as Java dependencies

The merged branch would not build for anyone else: `RefreshOwidData` imports
`org.duckdb`, and I had put the driver in `userlib/` and **git-ignored it**
(81 MB), so a plain clone had no driver. The SessionStart hook fetched it, which
hid the problem from me completely — it only bites someone who clones and
builds without running the hook. This is the exact failure the vega-charts pack
warns about for a git-ignored `widgets/`; I applied the lesson there and not
here.

The fix is not "commit the jar in userlib" — it is to declare it:

```sql
ALTER MODULE Owid
  ADD JAR DEPENDENCY (
    group = 'org.duckdb', artifact = 'duckdb_jdbc',
    version = '1.4.1.0', included = true
  );
```

then `mxcli sync-java-deps -p OwidExplorer.mpr`, which resolves it from Maven
Central into **`vendorlib/`** and writes `vendorlib-sbom.json` beside it.
`vendorlib/` is tracked (only `/vendorlib/temp/` is ignored), so the jar is in
the repository — but now it is *declared, versioned and inventoried* rather than
an anonymous binary someone dropped in a folder.

`ALTER MODULE ... ADD JAR DEPENDENCY` on its own is not enough, and mxcli says
so plainly: *"not in vendorlib/, so it is not on the classpath yet — the build
will still succeed and fail at runtime."* Declaring without syncing gives you a
green build and a `ClassNotFoundException`.

**Verified** with `userlib/` empty: the project compiles, the connector path
returns `rows=25 first=Afghanistan le=61.454`, and clicking *Refresh from OWID*
logs a second `RefreshRun` of 13,760 observations. Both DuckDB routes work from
the declared dependency alone.

## 22. Vega warnings: a bound-but-loading attribute is not "no data"

Two distinct problems behind a wall of console warnings.

**`The input spec uses Vega-Lite v5, but the current version is v6.4.3`** — the
pack bundles `vega-lite@6.4.3`; my specs declared the v5 `$schema`. Vega-Lite
compiles v5 specs under v6 anyway, so everything drew correctly and only warned.
All seven specs now declare `.../vega-lite/v6.json`.

**`Infinite extent for field "x": [Infinity, -Infinity]`** (and the matching
*Log scale domain includes zero*) — an extent computed over **zero rows**. Not a
data bug: measured 19 warnings on cold load and **0** after any re-render, so it
was one transient first paint before the data arrived.

Cause is in the widget:

```ts
if (!parsedData.value) { return parsedSpec.value; }   // embeds with NO data
```

`chartData?.status === "available" ? chartData.value : undefined` collapses two
different states into `undefined` — *no data attribute bound* (legal: the URL
form, where the spec carries its own `data.url`) and *attribute bound but still
loading*. The second must wait; embedding then hands Vega an empty dataset and
it warns once per encoded field.

Fixed by distinguishing them:

```ts
const awaitingData = chartData !== undefined && chartData.status !== "available";
...
if (!hostRef.current || !resolvedSpec || awaitingData) { return; }
```

**Verified:** 0 warnings on cold load, 0 after Apply, mark counts unchanged
(255/99/27/333/217/243/202). Worth pushing upstream — it affects every
attribute-fed chart in the pack, not just this app.

## 23. Dark OS made the table black-on-black; Datagrid 2 has no `<th>`/`<td>`

Reported as "table is unreadable, black on black" — and invisible to me, because
Playwright defaults to `colorScheme: light` and every screenshot I had taken was
light. Reproduced immediately with `colorScheme: 'dark'`.

Two compounding causes:

**The theme followed the OS.** `mxcli theme apply` defaults to
`--variant auto`, which ships both palettes and follows `prefers-color-scheme`.
Under a dark OS, Atlas painted `.widget-datagrid-grid` at `rgb(22,27,34)` while
this stylesheet kept Industry's dark ink `rgb(29,31,32)` — a contrast ratio of
about **1.0**. Industry is a light-only design, so the fix is to stop it
switching at all:

```bash
mxcli theme apply signal -p OwidExplorer.mpr --variant light
```

That edits the generated block the supported way rather than by hand.

**Datagrid 2 is divs, not a table.** The styling was written as
`.owid-table th` / `.owid-table td` and matched almost nothing: the widget emits
`<div class="th">` / `<div class="td">` inside `.widget-datagrid-grid`. Probing
computed styles showed `th` resolving to `null` — the tell. Selectors are now
`.owid-table .th` / `.owid-table .td`, and the ground and ink are stated
explicitly rather than inherited, so the table survives whatever palette is
around it. Right-alignment needs `justify-content: flex-end` as well as
`text-align`, since the cells are flex containers.

**Verified** by measuring contrast in both schemes, identical in each:
body text **14.79:1**, headers **4.52:1** — both pass WCAG AA.

**Method note:** this class of bug is invisible to a default headless run.
Render at `colorScheme: 'dark'` as well as light before calling a UI done.

## 24. Task queues on call activities — PARTLY RESOLVED upstream, see #25

**Update: `ako/mxcli` main (`4f893ce`) has since acted on this — but not by
adding `in queue`. See #25 for what actually shipped, which is more important
than what I asked for.**

Mendix can run **both** a *Call microflow* and a *Call Java action* activity on
a task queue — it is a property on the call activity, not a separate construct.
MDL exposes it on **neither**. My earlier note that "MDL cannot mark a call as
queued" was right about the language and wrong about the cause: this is not a
missing capability in mxcli, it is unwired plumbing, and it is missing on both
activities equally.

What is actually there, checked layer by layer:

| Layer | State |
| --- | --- |
| `CREATE QUEUE Mod.Name (Parallelism: n, ClusterWide: b)` | **works** — `createQueueStatement`, `MDLDomainModel.g4:345` |
| `MicroflowCall.SetQueueQualifiedName(string)` | **generated** — `modelsdk/gen/microflows/types.go:7738` |
| `MicroflowCall.SetQueueSettings(element)` | **generated** — same file, 7728 |
| `JavaActionCallAction.SetQueueQualifiedName` | **generated** — 6019 |
| Anything calling those setters | **nothing** — `grep -rn SetQueueQualifiedName --include=*.go .` outside `modelsdk/gen` returns zero hits |
| `callMicroflowStatement` grammar | **no queue clause** — `MDLMicroflow.g4:358` |
| `callJavaActionStatement` grammar | **no queue clause** — `MDLMicroflow.g4:367` |
| Queues elsewhere in MDL | catalog **read only** — `buildQueues` lists `Queues$Queue` units for SHOW/DESCRIBE |

Both call rules are identical in shape, and the only optional trailing clause on
either is `onErrorClause`:

```antlr
callMicroflowStatement
    : (VARIABLE EQUALS)? CALL MICROFLOW   qualifiedName LPAREN callArgumentList? RPAREN onErrorClause? ;
callJavaActionStatement
    : (VARIABLE EQUALS)? CALL JAVA ACTION qualifiedName LPAREN callArgumentList? RPAREN onErrorClause? ;
```

So the model-write side is already generated and reachable; what is missing is a
grammar clause on each and one setter call apiece. Something like:

```sql
CALL MICROFLOW   Owid.ACT_RefreshFromOwid ()        IN QUEUE Owid.RefreshQueue;
CALL JAVA ACTION Owid.RefreshOwidData (BaseUrl = …) IN QUEUE Owid.RefreshQueue;
```

The feature matrix marks *Task queue* as `N` across every backend, which reads
as "not implemented at all" and undersells how close it is.

### What works today instead

The runtime API is fully reachable from a Java action, which MDL *can* author.
Verified against `com.mendix.public-api.jar`:

```java
ActionCallBuilder.executeInBackground(IContext ctx, String queueName)
ActionCallBuilder.executeInBackground(IContext ctx, String queueName, Date when)
ActionCallBuilder.withExponentialRetry(int, Duration, Duration)
```

This gives queueing *and* retry, which the activity property does not offer.

**A Java action can be queued directly** — no wrapper microflow. Generated Java
actions extend `UserAction<R>` (confirmed: `RefreshOwidData extends
UserAction<Long>`), and `Core.userActionCall(String)` returns a
`UserActionCallBuilder extends ActionCallBuilder`, so:

```java
Core.userActionCall("Owid.RefreshOwidData")
    .withParams(baseUrl, yearFrom, yearTo)
    .withExponentialRetry(5, Duration.ofSeconds(2), Duration.ofMinutes(2))
    .executeInBackground(ctx, "Owid.RefreshQueue");
```

That is the better shape here: the queue runs the actual worker rather than a
wrapper microflow whose only job is to call it. `Core.microflowCall(...)` is the
equivalent when the unit of work really is a microflow.

### Why this app should use it

`ASU_Seed` is the `AfterStartupMicroflow` and runs the whole DuckDB extract
**synchronously**, so first boot blocks for ~15 s with the app unavailable. The
*Refresh from OWID* button likewise holds an HTTP request for the full extract,
and a single CDN hiccup fails the load with no retry.

`RefreshRun` already carries `StartedAt` / `CompletedAt` / `Succeeded` /
`Message` — a status record for an asynchronous job. The reporting was designed
for a queue and then the work was run inline anyway.

## 25. What actually shipped for queues — and the data-loss bug behind it

Re-checked against `ako/mxcli` main at `4f893ce`, built and run. `in queue` on a
call is **still deliberately unimplemented** — the source says so outright:

```go
// MDL cannot yet author a queued call, so the binding cannot be restated in the
// script either — refusing is the only option that does not lose data
// (guard-don't-drop, ADR-0005). Remove this guard when `in queue` exists …
```

**Verified by test**, not by reading:

| | result |
| --- | --- |
| `CREATE QUEUE Owid.RefreshQueue (Parallelism: 1, ClusterWide: true)` | **works** |
| `SHOW QUEUES` / `DESCRIBE QUEUE` | **round-trips** as `create or modify queue …` |
| `CALL MICROFLOW … IN QUEUE …` | **parse error** — `mismatched input 'IN' expecting ';'` |

### The part that matters more than the feature I asked for

The real find was a **silent data-loss bug**, not a missing surface:
`Microflows$MicroflowCall` carried `QueueSettings` in `NullFields` of
`codec.RegisterTypeDefaults` (the legacy writer hardcoded null too). Correct for
a newly authored call, destructive for a stored one — and since
`CREATE OR REPLACE MICROFLOW` rebuilds the whole microflow, it fired on **every
rewrite**. A queue binding made in Studio Pro was silently dropped by any MDL
rewrite of that microflow.

Worse, the damage read as an improvement: `mx check` went from
`[CE1613] "The selected task queue no longer exists"` to **0 errors**, because
the configuration the error referred to had been deleted. Any "did the error
count go down?" check would have scored the data loss as a fix.

The fix is `mdl/executor/validate_queued_calls.go` — `checkNoQueuedCalls`
**refuses** the rewrite rather than half-authoring it, plus queue authoring in
both engines (`mdl/backend/modelsdk/queue_write.go`, `sdk/mpr/queues.go`).

### Bearing on this project

This app rewrites microflows constantly — `CREATE OR REPLACE`, and repeated
drop-and-recreate cycles during development. **No harm done here**, because
nothing in it has a queued call. But had any microflow been queue-bound in
Studio Pro, my rewrites would have destroyed the binding silently and the
project would have looked *healthier* afterwards.

Two lessons from their write-up worth carrying:

- **A green build can be the bug.** The correct fix made `mx check` report
  *more* errors, because the binding it complains about survived.
- **`describe` showing nothing is not evidence of nothing.** The binding was
  invisible from every angle — describe omitted it, check went quiet, the write
  reported success — and only a stored-BSON probe exposed it. My own habit of
  trusting `DESCRIBE` round-trips as proof has exactly this blind spot.

## 26. FIXED: OnChange now survives on combobox, radiobuttons and checkbox

`ako/mxcli` main at `443e80d` fixes #14, and the **Apply-button workaround has
been removed from the dashboard** — the controls are native again.

Two commits did it, and the second is the more interesting one:

- `622386c fix(check): an action slot is authorable by its source, not its
  storage key` — mapping `onChangeEvent` so that `OnChange:` reached it had
  made `onChangeEvent:` an accepted MDL property name that the engine never
  read, so it would be *accepted by check and dropped on write* — the same
  silent-drop class, one layer up. An action mapping is now authorable by its
  Source only (`Action`/`OnClick`/`OnChange`), and the storage key is an error
  that names the spelling that works.
- `7256062 fix(pages): read a pluggable widget's action back` — `DESCRIBE`
  could not see a ComboBox's `OnChange`, so **describe → exec deleted it**: the
  write was already correct, but the read looked only at the built-in
  `OnChangeAction` slot, which a pluggable widget does not use.

**Verified in three layers**, because the model storing it does not prove the
browser fires it:

| | result |
| --- | --- |
| `DESCRIBE PAGE` round-trip | `OnChange: microflow Owid.ACT_Apply(State: $currentObject)` on **both** combobox and checkbox |
| Runtime, combobox, no Apply pressed | topic switched — figure title and note both changed |
| Runtime, after removing the button | `Apply button present: 0`; topic still switches, year still steps, 0 Vega warnings, all seven figures drawing |

That second commit is a direct hit on the habit flagged in #25: I had been
treating a `DESCRIBE` round-trip as proof. Here `DESCRIBE` was itself the
lossy layer — a correct write, read back incorrectly, so round-tripping the
output *destroyed* the thing it was meant to verify. A round trip proves the
pair agree, not that either is right.
