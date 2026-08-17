<?php
/**
 * wp-lite seeder — run ONCE per site via `GET /seed.php` (the loadgen -seed
 * mode fans this out across all N vhosts in parallel).
 *
 * Everything here goes through the ephpm_db_* bridge, so the server opens the
 * requesting site's own Turso database (<db.dir>/<site-key>.db) and this DDL
 * lands in that file only. That is the multi-tenant provisioning path under
 * test: no wp-cli, no copied files, each DB created by the engine itself.
 *
 * The schema is a deliberately small, WordPress-shaped subset (options / posts
 * / postmeta / users / terms) — enough to drive a ~20-query front page, a
 * single-post permalink, and a REST list without dragging in WP core.
 */
declare(strict_types=1);
header('Content-Type: text/plain');

if (!function_exists('ephpm_db_execute')) {
    http_response_code(500);
    echo "ephpm_db_* bridge unavailable — is [db.sqlite] active?\n";
    exit;
}

function ex(string $sql, array $p = []): void { ephpm_db_execute($sql, $p); }
function q(string $sql, array $p = []): array { return ephpm_db_query($sql, $p); }

// --- schema (MySQL dialect; litewire translates to the Turso/SQLite engine) ---
ex("CREATE TABLE IF NOT EXISTS options (
      option_id INTEGER PRIMARY KEY,
      option_name VARCHAR(191),
      option_value TEXT,
      autoload VARCHAR(20))");
ex("CREATE TABLE IF NOT EXISTS users (
      ID INTEGER PRIMARY KEY,
      user_login VARCHAR(60),
      display_name VARCHAR(250))");
ex("CREATE TABLE IF NOT EXISTS posts (
      ID INTEGER PRIMARY KEY,
      post_author INTEGER,
      post_date VARCHAR(30),
      post_title TEXT,
      post_content TEXT,
      post_status VARCHAR(20),
      post_type VARCHAR(20),
      comment_count INTEGER)");
ex("CREATE TABLE IF NOT EXISTS postmeta (
      meta_id INTEGER PRIMARY KEY,
      post_id INTEGER,
      meta_key VARCHAR(191),
      meta_value TEXT)");
ex("CREATE TABLE IF NOT EXISTS terms (
      term_id INTEGER PRIMARY KEY,
      name VARCHAR(191),
      slug VARCHAR(191),
      count INTEGER)");

// --- idempotency guard: only seed content once ---
$already = q("SELECT option_value FROM options WHERE option_name = ?", ['seeded']);
if (!empty($already)) {
    echo "already seeded\n";
    exit;
}

// options (front page reads the autoloaded set in one query)
$opts = [
    ['siteurl', 'http://'.($_SERVER['HTTP_HOST'] ?? 'site')],
    ['blogname', 'Site '.($_SERVER['HTTP_HOST'] ?? '?')],
    ['blogdescription', 'A multi-tenant scalebench site'],
    ['posts_per_page', '10'],
    ['template', 'scalebench'],
    ['stylesheet', 'scalebench'],
    ['active_plugins', 'a:0:{}'],
    ['permalink_structure', ''],
    ['seeded', '1'],
];
$oid = 1;
foreach ($opts as [$k, $v]) {
    ex("INSERT INTO options (option_id, option_name, option_value, autoload) VALUES (?,?,?,?)",
        [$oid++, $k, $v, 'yes']);
}

ex("INSERT INTO users (ID, user_login, display_name) VALUES (?,?,?)", [1, 'admin', 'Site Admin']);

// a handful of published posts + a page, each with a couple of meta rows
$mid = 1;
for ($i = 1; $i <= 12; $i++) {
    $type = $i === 12 ? 'page' : 'post';
    ex("INSERT INTO posts (ID, post_author, post_date, post_title, post_content, post_status, post_type, comment_count)
        VALUES (?,?,?,?,?,?,?,?)",
        [$i, 1, '2026-01-'.sprintf('%02d', $i).' 12:00:00',
         "Post $i title", str_repeat("Lorem ipsum dolor sit amet. ", 20),
         'publish', $type, $i % 4]);
    ex("INSERT INTO postmeta (meta_id, post_id, meta_key, meta_value) VALUES (?,?,?,?)",
        [$mid++, $i, '_edit_last', '1']);
    ex("INSERT INTO postmeta (meta_id, post_id, meta_key, meta_value) VALUES (?,?,?,?)",
        [$mid++, $i, '_thumbnail_id', (string)(100 + $i)]);
}

$terms = [['Uncategorized', 'uncategorized', 11], ['News', 'news', 3], ['Reviews', 'reviews', 2]];
$tid = 1;
foreach ($terms as [$n, $s, $c]) {
    ex("INSERT INTO terms (term_id, name, slug, count) VALUES (?,?,?,?)", [$tid++, $n, $s, $c]);
}

echo "seeded ".($_SERVER['HTTP_HOST'] ?? '?')."\n";
