<?php
/**
 * Bridge twin of fixtures/sqlite/db.php: the SAME ten sequential point
 * SELECTs, same SQL text, same table — but through ephpm_db_query()
 * instead of PDO over the MySQL wire.
 *
 * Two deliberate differences, both of which ARE the thing being
 * measured, not confounds:
 *
 *  - No connect. The wire fixture opens a PDO connection per request
 *    because that is what a real PHP request pays without persistent
 *    connections. The bridge has no connection to open — a per-thread
 *    litewire Session is created lazily once per worker thread and
 *    reused. The delta between this fixture and db.php is exactly
 *    "one TCP connect plus ten wire round-trips" vs "ten C calls".
 *
 *  - No wire encode/decode. Same translation, same backend (the bridge
 *    shares the backend instance the MySQL frontend serves), no
 *    resultset marshalling through the MySQL protocol.
 *
 * Gated on the same canonical {"sum":55} as db.php.
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
