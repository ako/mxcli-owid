LOAD httpfs;
SET VARIABLE base = 'https://catalog.ourworldindata.org/';
SET VARIABLE isocsv = '/home/user/mxcli-owid/resources/iso3166_numeric.csv';

CREATE OR REPLACE VIEW years AS SELECT unnest(generate_series(1960, 2023)) AS year;

CREATE OR REPLACE VIEW reg AS
SELECT * FROM read_parquet(getvariable('base') || 'garden/regions/2023-01-01/regions/regions.parquet');

-- country -> continent, by unnesting each continent's member list.
-- OWID splits the Americas; the design's palette has five regions, so fold them.
CREATE OR REPLACE VIEW continent_of AS
SELECT unnest(CAST(members AS VARCHAR[])) AS code,
       CASE WHEN name IN ('North America','South America') THEN 'Americas' ELSE name END AS region
FROM reg WHERE region_type = 'continent';

-- The country roster: real countries only (no aggregates, no historical states),
-- carrying the ISO numeric code the choropleth joins on.
CREATE OR REPLACE VIEW roster AS
SELECT r.name AS country, r.code, c.region, i.iso_num
FROM reg r
JOIN continent_of c ON c.code = r.code
JOIN read_csv(getvariable('isocsv')) i ON i.iso3 = r.iso_alpha3
WHERE r.region_type = 'country' AND NOT r.is_historical;

CREATE OR REPLACE VIEW wdi AS
SELECT country, year, sp_pop_totl pop, sp_dyn_le00_in le,
       sh_dyn_mort cm, sp_dyn_tfrt_in fe, en_ghg_co2_pc_ce_ar5 co2
FROM read_parquet(getvariable('base') || 'grapher/worldbank_wdi/2026-07-27/wdi/wdi.parquet')
WHERE year BETWEEN 1960 AND 2023;

CREATE OR REPLACE VIEW gdppc AS
SELECT country, year, gdp_per_capita gdp
FROM read_parquet(getvariable('base') || 'grapher/ggdc/2024-04-26/maddison_project_database/maddison_project_database.parquet')
WHERE year BETWEEN 1960 AND 2023 AND gdp_per_capita IS NOT NULL;

CREATE OR REPLACE VIEW energy AS
SELECT country, year, primary_energy_consumption_per_capita__kwh en
FROM read_parquet(getvariable('base') || 'grapher/energy/2026-05-05/primary_energy_consumption/primary_energy_consumption.parquet')
WHERE year BETWEEN 1960 AND 2023;

CREATE OR REPLACE VIEW food AS
SELECT country, year,
  coalesce(cereals_and_grains,0)+coalesce(pulses,0)+coalesce(starchy_roots,0)
 +coalesce(fruits_and_vegetables,0)+coalesce(oils_and_fats,0)+coalesce(sugar,0)
 +coalesce(meat,0)+coalesce(dairy_and_eggs,0)+coalesce(alcoholic_beverages,0)
 +coalesce(other,0) AS kc
FROM read_parquet(getvariable('base') || 'grapher/faostat/2026-05-22/additional_variables/food_available_for_consumption.parquet')
WHERE year BETWEEN 1960 AND 2023;

CREATE OR REPLACE VIEW school_anchor AS
SELECT country, year, mf_youth_and_adults__15_64_years__average_years_of_education sc
FROM read_parquet(getvariable('base') || 'grapher/education/2023-07-17/education_barro_lee_projections/education_barro_lee_projections.parquet')
WHERE year BETWEEN 1960 AND 2023
  AND mf_youth_and_adults__15_64_years__average_years_of_education IS NOT NULL;

CREATE OR REPLACE VIEW school AS
WITH grid AS (SELECT r.country, y.year FROM roster r CROSS JOIN years y),
j AS (
  SELECT g.country, g.year, a.sc,
         last_value(a.sc IGNORE NULLS) OVER w_prev AS prev_v,
         last_value(CASE WHEN a.sc IS NOT NULL THEN g.year END IGNORE NULLS) OVER w_prev AS prev_y,
         first_value(a.sc IGNORE NULLS) OVER w_next AS next_v,
         first_value(CASE WHEN a.sc IS NOT NULL THEN g.year END IGNORE NULLS) OVER w_next AS next_y
  FROM grid g LEFT JOIN school_anchor a ON a.country = g.country AND a.year = g.year
  WINDOW w_prev AS (PARTITION BY g.country ORDER BY g.year ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW),
         w_next AS (PARTITION BY g.country ORDER BY g.year ROWS BETWEEN CURRENT ROW AND UNBOUNDED FOLLOWING)
)
SELECT country, year,
       CASE WHEN sc IS NOT NULL THEN sc
            WHEN prev_v IS NOT NULL AND next_v IS NOT NULL AND next_y > prev_y
              THEN prev_v + (next_v - prev_v) * (year - prev_y) / (next_y - prev_y)
            ELSE coalesce(prev_v, next_v) END AS sc
FROM j;

CREATE OR REPLACE VIEW observation AS
SELECT r.country, r.iso_num AS id, r.region, y.year,
       w.pop, g.gdp, w.le, w.cm, w.fe, w.co2, e.en, f.kc, s.sc
FROM roster r
CROSS JOIN years y
LEFT JOIN wdi    w ON w.country = r.country AND w.year = y.year
LEFT JOIN gdppc  g ON g.country = r.country AND g.year = y.year
LEFT JOIN energy e ON e.country = r.country AND e.year = y.year
LEFT JOIN food   f ON f.country = r.country AND f.year = y.year
LEFT JOIN school s ON s.country = r.country AND s.year = y.year;
