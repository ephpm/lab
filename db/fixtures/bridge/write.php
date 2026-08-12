<?php
/**
 * Bridge twin of fixtures/sqlite/write.php: one INSERT into the same
 * append-only wbench table, same SQL text, through ephpm_db_execute()
 * instead of PDO. Each request is its own implicit transaction, exactly
 * as on the wire path.
 */

header('Content-Type: application/json');

if (!function_exists('ephpm_db_execute')) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => 'ephpm_db_execute is not registered']);
    return;
}

try {
    $r = ephpm_db_execute('INSERT INTO wbench (val) VALUES (1)');
    echo json_encode(['status' => 'ok', 'affected' => $r['affected_rows']]);
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
