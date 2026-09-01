<?php
/**
 * Read cell for the cluster suite: ten sequential point SELECTs through
 * ephpm_db_query().
 *
 * The SQL text, the table and the loop are BYTE-IDENTICAL to
 * db/fixtures/bridge/point.php, which is what makes the single-site
 * lanes (S, W) and the multi-tenant lanes (P1, P2, P3) comparable to
 * each other and to the historical `bridge` suite's B-turso lane. If you
 * change one, change both.
 *
 * Sequential is load-bearing, for the same reason it is in db.php: the
 * fixture exists to measure per-query round-trip through whatever sits
 * in the path, so the queries must not batch or pipeline. In per-site
 * clustered mode "whatever sits in the path" is either a local Turso
 * call (on the site's HRW owner) or ten forwarded statements over
 * sql/<site> to the owner (on any other node) -- that difference is the
 * whole point of the P2 vs P3 pair.
 *
 * Gated on the canonical {"sum":55}.
 */

header('Content-Type: application/json');

if (!function_exists('ephpm_db_query')) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'ephpm_db_query is not registered']);
    return;
}

try {
    $sum = 0;
    for ($i = 1; $i <= 10; $i++) {
        $rows = ephpm_db_query("SELECT id, val FROM bench WHERE id = {$i}");
        $sum += (int) ($rows[0]['val'] ?? 0);
    }

    echo json_encode(['status' => 'ok', 'sum' => $sum]);
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
