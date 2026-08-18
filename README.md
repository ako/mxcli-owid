# OwidExplorer

Two data-visualization dashboards over **Our World in Data**, built as a Mendix
app with [mxcli](https://github.com/ako/mxcli). They read the same public
parquet catalogue through the same DuckDB, and they answer the question "where
does the data live" in opposite ways — which is the point of having both.

| | **The Development Plate** (`/`) | **The Mortality Surface** (`/p/live`) |
| --- | --- | --- |
| Data | copied into Mendix entities | none stored at all |
| Path | refresh job → entities → OData → charts | charts → OData → DuckDB → parquet |
| Rows | 13,760 held | 11.9 M reachable, 0 held |
| Freshness | as of the last refresh | as of this request |
| Cost | one 16 s job, then instant | 0.3–1.4 s per figure |

---

# Page one — "The Development Plate"

## What it is

A dashboard that lets one person explore how 215 countries developed between 1960
and 2023 across nine indicators — income, life expectancy, child mortality,
energy, CO₂, fertility, food supply, schooling and population. You pick a
**topic** (which pair of indicators to plot), scrub or play a **year**, filter by
**region**, and click any country to make it the **focus**; every figure on the
page re-reads that shared state.

It is a **single-user app with no security** — no login, no user roles. Anonymous
access goes straight to the dashboard.

## How it works

DuckDB runs **inside the Mendix runtime** (driver in `userlib/`, driven by the
`RefreshOwidData` Java action). It reads OWID's parquet files over HTTP range
requests, harmonizes nine sources into one country-year table, and materializes
215 countries x 64 years = 13,760 observations into Mendix entities. Those are
published as OData at `/odata/owid/`, and the seven figures are Vega-Lite specs
rendered by a pluggable widget.

"Live" means **re-runnable on demand** against current OWID data — the
*Refresh from OWID* button re-runs the whole extract — not fetched per request:
the extract takes seconds, which is fine for a refresh and far too slow to serve
a chart.

## What it keeps track of

Reference data:

- **Country** — all 215 OWID countries that carry data: name, ISO alpha-3, ISO
  numeric code (for the choropleth), and region. Derived from OWID's own regions
  table, not hand-listed.
- **Indicator** — the nine series: key, label, unit, number format, and whether it
  is drawn on a log scale or "lower is better".
- **Topic** — the six preset x/y indicator pairings the topic switcher offers.

Observation data (fetched from OWID, refreshable):

- **Observation** — one row per country per year, carrying all nine indicator
  values. 215 × 64 = 13,760 rows. Country, ISO code and region are denormalized
  onto the row: that is the flat shape Vega binds to.

## Where the data comes from

Live from OWID's public parquet catalog at `catalog.ourworldindata.org`, read by
**DuckDB running in-process inside the Mendix runtime** (DuckDB JDBC in
`userlib/`, driven by a Java action). DuckDB's `httpfs` extension queries the
remote parquet files directly over HTTP range requests — no bulk download.

| Indicator | Source table |
| --- | --- |
| GDP per capita | `ggdc/2024-04-26/maddison_project_database` (ends 2022) |
| Population, life expectancy, child mortality, fertility, CO₂ | `worldbank_wdi/2026-07-27/wdi` |
| Primary energy per capita | `energy/2026-05-05/primary_energy_consumption` |
| Daily food supply | `faostat/2026-05-22/additional_variables` |
| Mean years of schooling | `education/2023-07-17/education_barro_lee_projections` |

The nine series are harmonized into one country/year table by a single DuckDB
query, materialized into Mendix entities, and **published as an OData service**
that the charts fetch from. A refresh action re-runs the query on demand.

The Mendix **External Database Connector** also reaches the same DuckDB, via
Mendix's `BYOD` ("bring your own driver") type — `Owid.OwidDuck`, exercised by
`ACT_QueryViaConnector` and reachable at `POST /odata/owid/QueryViaConnector`.
The Java-action path drives the dashboard because it expresses the whole
nine-source harmonization; the connector is the supported-product route to the
same data.

See `FINDINGS.md` for the data caveats, and #20 for the two traps in wiring a
BYOD connection (the connection string must be a constant reference, and
username/password must reference constants even when the driver needs neither
— both build green and fail later).

## Look and feel

The **Industry** design system from the supplied mockup: steel-blue `#5980a6` on a
light technical ground `#f2f2f3`, Barlow Condensed headings over Barlow body text,
a modular grid, and cards and figures drawn as square-cornered hairline "blueprint"
objects with `+` registration marks at their corners. Built on mxcli's `signal`
theme with its tokens retuned to the Industry palette.

Charts are Vega-Lite specifications, as in the mockup.

The dashboard opens on **2022**, the last year Maddison publishes GDP for.
Topic, region and year controls all apply on change — the Apply button that
stood in for a broken `OnChange` is gone, fixed upstream (`FINDINGS.md` #26).

---

# Page two — "The Mortality Surface"

## What it is

The same design system over a dataset the app **never copies**. Five figures and
a table over the UN World Population Prospects 2024 life tables as OWID
publishes them: 261 places, single year of age by sex, estimates 1950–2023 and
Medium-variant projections to 2100. 11.9 million rows and 483 MB of parquet, of
which this app stores nothing.

- **FIG 01** — the Lexis surface: death rate by age and year, 74 × 101 cells for
  one place, on a log scale. Its country selector is a **Vega signal**, so
  changing it rebuilds the data URL and the browser fetches a new surface.
- **FIG 02** — the mortality bathtub, World, 1950 / 1990 / 2023.
- **FIG 03** — life expectancy at birth 1950–2100, eight countries, observed
  then projected.
- **FIG 04** — survival curves: of 100 born, the share reaching each age.
- **FIG 05** — the sex gap, female minus male. Russia peaks at 13.8 years in 1994.
- **TAB 01** — every country ranked, 2023.

## How it works

Nothing is stored, and nothing is written on the way back:

```
browser  ──GET /odata/live/LifeTable?$filter=…&$top=…──▶  Mendix
                                                          │
                                          read microflow  │  Owid.DS_LifeTable
                                          Owid.Parse ─────┤  $filter/$orderby/$top/$skip
                                                          │  → SQL fragments
                                External Database Connector  (BYOD, DuckDB)
                                                          │
                                    DuckDB httpfs ────────▶ catalog.ourworldindata.org
                                                             (HTTP range requests)
```

Mendix applies **none** of the query options to a resource served by a read
microflow — `$filter`, `$orderby`, `$top`, `$skip` and the key lookup all arrive
on the URI and all stay there. Left alone that is a 200 with the wrong rows. The
`mendix-odata-pushdown` skill pack does the translation, and this app is its
splice-style caller: parse the URI once, concatenate the fragments onto a base
statement held in a constant, run it through the connector with
`EXECUTE DATABASE QUERY … DYNAMIC`.

The three published resources are `LifeTable`, `LifeExpectancy` and `Places`,
all non-persistable, all `Countable: No` and `UsePaging: No` — the caps live in
the microflow, because the platform cannot page an answer it did not build.

**TAB 01 goes the other way on purpose**: the same connection and the same
parquet, read straight into a Mendix data grid with no HTTP and no OData. The
service is a choice about who the consumer is, not a requirement of reading the
data.

## What it costs

Measured on the running app. Cold is the first request after a restart; warm is
any request after the connector's pooled DuckDB connection has the file's
metadata and pages cached.

| Request | Rows | Cold | Warm |
| --- | --- | --- | --- |
| `Places` (whole set) | 261 | 3.7 s | 0.46 s |
| `LifeTable`, one country, all ages and years | 7,474 | 1.4 s | 0.72 s |
| `LifeTable`, World, three years | 303 | — | 0.26 s |
| `LifeExpectancy`, 8 countries, 1950–2100 | 1,208 | — | 1.25 s |

The whole board is five parallel requests and about 1.5 s. The strip under the
page header prints the milliseconds a probe query took **at that page load**,
because "live" is a claim about latency and a page making the claim should show
the number rather than assert it.

## Trying the service by hand

```bash
curl "http://localhost:8080/odata/live/Places?\$top=3"
curl "http://localhost:8080/odata/live/Places('Japan')"
curl "http://localhost:8080/odata/live/LifeTable?\$filter=location%20eq%20%27Japan%27%20and%20year%20eq%202000%20and%20age%20le%202&\$orderby=age"
```

See `FINDINGS.md` #28–#35 for what was measured and the four traps: paging is
refused on a read-microflow resource (#29), the pack's documented
`IF Rejected` branch is unreachable (#30), the key from the path segment never
reaches a splice caller (#31), and the UN scales three rate columns three
different ways (#32).

---

# Running it

```bash
./mxcli run --local -p OwidExplorer.mpr     # http://localhost:8080/
```

`/` is the stored board, `/p/live` is the live one, and the navigation menu
carries both.

DuckDB is a **declared Java dependency** of the `Owid` module
(`org.duckdb:duckdb_jdbc:1.4.1.0`), resolved into `vendorlib/` and committed, so
a fresh clone compiles as-is. If `vendorlib/` is ever incomplete, repair it with
`./mxcli sync-java-deps -p OwidExplorer.mpr`.

A fresh clone has no `mxcli` binary (it is git-ignored, ~88 MB). The SessionStart
hook in `.claude/settings.json` runs `.claude/bootstrap-mxcli.sh`, which builds
mxcli from **ako/mxcli main** and then caches MxBuild, starts PostgreSQL and
creates the database.

The model is built by the MDL scripts in `mdl/`, applied in numeric order:
`01`–`18` build the stored board, `19`–`24` the live one. The live pages also
need the `mendix-odata-pushdown` skill pack, which ships the parser the read
microflows delegate to:

```bash
./mxcli skill add mendix-odata-pushdown -p OwidExplorer.mpr --module Owid
./mxcli exec .claude/skills/mendix-odata-pushdown/mdl/module.mdl -p OwidExplorer.mpr
```

- Mendix **11.13.0**
- mxcli built from source, `ako/mxcli` main
