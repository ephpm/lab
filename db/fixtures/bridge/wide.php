<?php
/**
 * Bridge wide-select fixture: one SELECT returning 100 rows x 8 columns
 * (three INTs, four fixed-width TEXTs) through ephpm_db_query().
 *
 * Where point.php measures per-call overhead, this measures RESULT
 * MARSHALLING: the bridge converts rows straight to PHP arrays across
 * the FFI boundary, the wire twin (fixtures/sqlite/wide.php) pays MySQL
 * resultset encode + pdo_mysql decode for the same bytes.
 *
 * Gated on the deterministic checksum from bridge/seed.php:
 * rows=100, sum(a+b+c)=106050.
 */

header('Content-Type: application/json');

if (!function_exists('ephpm_db_query')) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'ephpm_db_query is not registered']);
    return;
}

try {
    $rows = ephpm_db_query('SELECT id, a, b, c, d, e, f, g FROM wide ORDER BY id');

    $sum = 0;
    foreach ($rows as $row) {
        $sum += (int) $row['a'] + (int) $row['b'] + (int) $row['c'];
    }

    echo json_encode(['status' => 'ok', 'rows' => count($rows), 'sum' => $sum]);
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
