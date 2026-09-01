<?php
/**
 * Write cell for the cluster suite: one INSERT through ephpm_db_execute(),
 * its own implicit transaction.
 *
 * Byte-identical in SQL to db/fixtures/bridge/write.php (see point.php on
 * why that matters).
 *
 * This is the fixture that separates the lanes. A SELECT on a primary
 * never touches replication; an INSERT does:
 *
 *   S  (single-node, no cluster)      -- INSERT, nothing else.
 *   W  (whole-DB clustered, primary)  -- INSERT + CDC capture + ship.
 *   P1 (per-site, single node)        -- INSERT into this tenant's file.
 *   P2 (per-site clustered, OWNER)    -- INSERT + per-site CDC capture.
 *   P3 (per-site clustered, NON-owner)-- one forwarded statement over
 *                                        sql/<site> to the owner, which
 *                                        then does everything P2 does.
 *
 * P3 minus P2 is the cost of the forward hop, and it is the number
 * people ask about first.
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
