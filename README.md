# OwidExplorer — "The Development Plate"

A single-page data-visualization dashboard over **Our World in Data** development
indicators, built as a Mendix app with [mxcli](https://github.com/ako/mxcli).

## What it is

A dashboard that lets one person explore how 27 countries developed between 1960
and 2023 across nine indicators — income, life expectancy, child mortality,
energy, CO₂, fertility, food supply, schooling and population. You pick a
**topic** (which pair of indicators to plot), scrub or play a **year**, filter by
**region**, and click any country to make it the **focus**; every figure on the
page re-reads that shared state.

It is a **single-user app with no security** — no login, no user roles. Anonymous
access goes straight to the dashboard.

## What it keeps track of

Reference data (fixed, seeded):

- **Country** — the 27-country sample: display name, the OWID name it is fetched
  under, ISO numeric code (for the choropleth), and region.
- **Indicator** — the nine series: key, label, unit, number format, and whether it
  is drawn on a log scale or "lower is better".
- **Topic** — the six preset x/y indicator pairings the topic switcher offers.

Observation data (fetched from OWID, refreshable):

- **Observation** — one row per country per year, carrying all nine indicator
  values. 27 × 64 = 1,728 rows.

## Where the data comes from

Live from OWID's public parquet catalog at `catalog.ourworldindata.org`, read by
**DuckDB running in-process inside the Mendix runtime** (DuckDB JDBC in
`userlib/`, driven by a Java action). DuckDB's `httpfs` extension queries the
remote parquet files directly over HTTP range requests — no bulk download.

| Indicator | Source table |
| --- | --- |
| GDP per capita | `ggdc/2024-04-26/maddison_project_database` |
| Population, life expectancy, child mortality, fertility, CO₂ | `worldbank_wdi/2026-07-27/wdi` |
| Primary energy per capita | `energy/2026-05-05/primary_energy_consumption` |
| Daily food supply | `faostat/2026-05-22/additional_variables` |
| Mean years of schooling | `education/2023-07-17/education_barro_lee_projections` |

The nine series are harmonized into one country/year table by a single DuckDB
query, materialized into Mendix entities, and **published as an OData service**
that the charts fetch from. A refresh action re-runs the query on demand.

See `FINDINGS.md` for why it is embedded DuckDB rather than the Mendix External
Database Connector, and for the data caveats.

## Look and feel

The **Industry** design system from the supplied mockup: steel-blue `#5980a6` on a
light technical ground `#f2f2f3`, Barlow Condensed headings over Barlow body text,
a modular grid, and cards and figures drawn as square-cornered hairline "blueprint"
objects with `+` registration marks at their corners. Built on mxcli's `signal`
theme with its tokens retuned to the Industry palette.

Charts are Vega-Lite specifications, as in the mockup.

## Running it

```bash
./mxcli run --local -p OwidExplorer.mpr     # http://localhost:8080/
```

A fresh clone has no `mxcli` binary (it is git-ignored, ~88 MB). The SessionStart
hook in `.claude/settings.json` runs `.claude/bootstrap-mxcli.sh`, which builds
mxcli from **ako/mxcli main** and then caches MxBuild, starts PostgreSQL and
creates the database.

- Mendix **11.13.0**
- mxcli built from source, `ako/mxcli` main
