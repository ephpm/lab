<?php
/**
 * wp-lite front controller — a WordPress-SHAPED front page/permalink/REST
 * handler that talks to the per-site Turso DB through the ephpm_db_* bridge.
 *
 * It is NOT WordPress: it exists so the scaling sweep can reach high N (1000
 * sites) without provisioning 1000 real WP installs, while still exercising
 * the multi-tenant path that matters — per-request site-key -> per-site DB
 * open (or LRU hit/miss) -> ~20 read queries against that site's own file.
 *
 * Routes (chosen so the SAME loadgen mix drives real WP too):
 *   GET /                         front page  (~20 queries)
 *   GET /?p=<id>                  single post (~8 queries)
 *   GET /wp-json/wp/v2/posts...   REST list   (~5 queries, JSON)
 */
declare(strict_types=1);

if (!function_exists('ephpm_db_query')) {
    http_response_code(500);
    echo 'bridge unavailable';
    return;
}
function q(string $sql, array $p = []): array { return ephpm_db_query($sql, $p); }

$uri = $_SERVER['REQUEST_URI'] ?? '/';

// ---- REST ----
if (str_starts_with($uri, '/wp-json')) {
    header('Content-Type: application/json');
    $opts = q("SELECT option_name, option_value FROM options WHERE autoload = ?", ['yes']);
    $posts = q("SELECT ID, post_title, post_date FROM posts
                WHERE post_status = ? AND post_type = ? ORDER BY post_date DESC LIMIT 10",
               ['publish', 'post']);
    $out = [];
    foreach ($posts as $p) {
        $meta = q("SELECT meta_key, meta_value FROM postmeta WHERE post_id = ?", [$p['ID']]);
        $out[] = ['id' => (int)$p['ID'], 'title' => $p['post_title'],
                  'date' => $p['post_date'], 'meta_count' => count($meta)];
    }
    echo json_encode(['host' => $_SERVER['HTTP_HOST'] ?? '', 'posts' => $out]);
    return;
}

// ---- single post (permalink) ----
if (isset($_GET['p'])) {
    $id = (int)$_GET['p'];
    $opts = q("SELECT option_name, option_value FROM options WHERE autoload = ?", ['yes']); // 1
    $post = q("SELECT * FROM posts WHERE ID = ? AND post_status = ?", [$id, 'publish']);    // 2
    if (empty($post)) { http_response_code(404); echo 'not found'; return; }
    $post = $post[0];
    $author = q("SELECT display_name FROM users WHERE ID = ?", [$post['post_author']]);     // 3
    $meta = q("SELECT meta_key, meta_value FROM postmeta WHERE post_id = ?", [$id]);         // 4
    $terms = q("SELECT name, slug FROM terms ORDER BY count DESC", []);                       // 5
    $prev = q("SELECT ID, post_title FROM posts WHERE ID < ? AND post_status = ? ORDER BY ID DESC LIMIT 1", [$id, 'publish']); // 6
    $next = q("SELECT ID, post_title FROM posts WHERE ID > ? AND post_status = ? ORDER BY ID ASC LIMIT 1", [$id, 'publish']);  // 7
    $recent = q("SELECT ID, post_title FROM posts WHERE post_status = ? ORDER BY post_date DESC LIMIT 5", ['publish']);        // 8
    header('Content-Type: text/html');
    echo "<!doctype html><title>".htmlspecialchars($post['post_title'])."</title>";
    echo "<h1>".htmlspecialchars($post['post_title'])."</h1>";
    echo "<p>by ".htmlspecialchars($author[0]['display_name'] ?? '?')."</p>";
    echo "<div>".htmlspecialchars($post['post_content'])."</div>";
    return;
}

// ---- front page (~20 queries: options, users, recent posts + per-post meta/terms) ----
$n = 0;
$opts = q("SELECT option_name, option_value FROM options WHERE autoload = ?", ['yes']); $n++;
$optMap = [];
foreach ($opts as $o) { $optMap[$o['option_name']] = $o['option_value']; }
$ppp = (int)($optMap['posts_per_page'] ?? 10);

$user = q("SELECT ID, display_name FROM users WHERE ID = ?", [1]); $n++;
$terms = q("SELECT term_id, name, slug, count FROM terms ORDER BY count DESC", []); $n++;
$commentTotal = q("SELECT SUM(comment_count) AS c FROM posts WHERE post_status = ?", ['publish']); $n++;

$posts = q("SELECT ID, post_author, post_date, post_title, post_content, comment_count
            FROM posts WHERE post_status = ? AND post_type = ? ORDER BY post_date DESC LIMIT ?",
           ['publish', 'post', $ppp]); $n++;

header('Content-Type: text/html');
echo "<!doctype html><html><head><title>".htmlspecialchars($optMap['blogname'] ?? 'Site')."</title></head><body>";
echo "<h1>".htmlspecialchars($optMap['blogname'] ?? 'Site')."</h1>";
echo "<p>".htmlspecialchars($optMap['blogdescription'] ?? '')."</p>";

foreach ($posts as $p) {
    // per-post meta + author + term lookups — the N+1 pattern a real theme runs
    $meta = q("SELECT meta_key, meta_value FROM postmeta WHERE post_id = ?", [$p['ID']]); $n++;
    $thumb = null;
    foreach ($meta as $m) { if ($m['meta_key'] === '_thumbnail_id') { $thumb = $m['meta_value']; } }
    echo "<article><h2>".htmlspecialchars($p['post_title'])."</h2>";
    echo "<p>".htmlspecialchars(substr($p['post_content'], 0, 120))."...</p>";
    echo "<footer>".(int)$p['comment_count']." comments";
    if ($thumb !== null) { echo " · thumb #".htmlspecialchars($thumb); }
    echo "</footer></article>";
}

// sidebar widgets: recent, pages, tag cloud (a few more reads)
$recent = q("SELECT ID, post_title FROM posts WHERE post_status = ? ORDER BY post_date DESC LIMIT 5", ['publish']); $n++;
$pages = q("SELECT ID, post_title FROM posts WHERE post_type = ? AND post_status = ? LIMIT 5", ['page', 'publish']); $n++;
$archive = q("SELECT substr(post_date,1,7) AS ym, COUNT(*) AS c FROM posts WHERE post_status = ? GROUP BY ym ORDER BY ym DESC LIMIT 6", ['publish']); $n++;

echo "<aside><h3>Recent</h3><ul>";
foreach ($recent as $r) { echo "<li>".htmlspecialchars($r['post_title'])."</li>"; }
echo "</ul><h3>Categories</h3><ul>";
foreach ($terms as $t) { echo "<li>".htmlspecialchars($t['name'])." (".(int)$t['count'].")</li>"; }
echo "</ul></aside>";
echo "<!-- queries: $n host: ".htmlspecialchars($_SERVER['HTTP_HOST'] ?? '')." -->";
echo "</body></html>";
