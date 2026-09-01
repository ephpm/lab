<?php
/**
 * One-shot seeder for the cluster suite, executed entirely THROUGH THE
 * BRIDGE (ephpm_db_execute), which makes it three things at once:
 *
 *  1. A seeder. Creates `bench` (ids 1..10, val = id, so point.php sums
 *     to the canonical 55) and the append-only `wbench` write table.
 *
 *  2. A function-registration gate. If ephpm_db_* is missing -- an image
 *     without the bridge, or a request that resolved to no per-site
 *     database context -- this returns an error body and the lane never
 *     starts.
 *
 *  3. A WRITE-FORWARDING gate, and this is the part specific to per-site
 *     clustered mode. The bridge on a NON-OWNER node does not touch the
 *     local file at all: it returns a remote proxy to the site's HRW
 *     owner, so this DDL lands on the owner's database and replicates out
 *     from there as CDC. Seeding through the bridge is therefore the only
 *     way to seed a per-site clustered lane correctly. Seeding over stock
 *     pdo_mysql instead would write to whichever node happened to serve
 *     the request -- local-only on a non-owner, and silently discarded
 *     the next time that replica re-bootstraps.
 *
 * Deliberately NOT idempotent-by-accident: it drops first, so a re-run
 * between lanes starts from an identical table on every node.
 */

header('Content-Type: application/json');

if (!function_exists('ephpm_db_query') || !function_exists('ephpm_db_execute')) {
    http_response_code(500);
    echo json_encode([
        'status'  => 'error',
        'message' => 'ephpm_db_* functions are not registered (no [db.sqlite], '
                   . 'or this Host resolved to no per-site database context)',
    ]);
    return;
}

try {
    ephpm_db_execute('DROP TABLE IF EXISTS bench');
    ephpm_db_execute('CREATE TABLE bench (id INTEGER PRIMARY KEY, val INTEGER)');
    // AUTOINCREMENT so concurrent inserters never collide on the primary
    // key -- the write cells run at c=16.
    ephpm_db_execute('DROP TABLE IF EXISTS wbench');
    ephpm_db_execute('CREATE TABLE wbench (id INTEGER PRIMARY KEY AUTOINCREMENT, val INTEGER)');
    for ($i = 1; $i <= 10; $i++) {
        ephpm_db_execute('INSERT INTO bench (id, val) VALUES (?, ?)', [$i, $i]);
    }

    // Read back exactly what point.php will sum: 1..10 = 55.
    $rows = ephpm_db_query('SELECT COUNT(*) AS c, SUM(val) AS s FROM bench');
    echo json_encode([
        'status' => 'ok',
        'count'  => (int) $rows[0]['c'],
        'sum'    => (int) $rows[0]['s'],
    ]);
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
