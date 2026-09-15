-- sql.js (WebAssembly 版 SQLite) が端末内で実行します。
CREATE TABLE languages (name TEXT, year INTEGER, runs_on_device INTEGER);

INSERT INTO languages VALUES
  ('JavaScript', 1995, 1),
  ('Python',     1991, 1),
  ('Ruby',       1995, 1),
  ('C',          1972, 0),
  ('Rust',       2010, 0);

SELECT name, year,
       CASE runs_on_device WHEN 1 THEN '端末内' ELSE 'サーバー' END AS engine
FROM languages
ORDER BY year;
