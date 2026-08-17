<?php
// Happy-path fixture B: ten SEQUENTIAL point SELECTs through the ephpm_db_*
// bridge — the same shape as the canonical db.php, minus the wire (the
// containment A/B must not be confounded by pdo_mysql connect cost).
// Sequential is load-bearing: per-query round-trip, no batching.
header('Content-Type: application/json');
if (!function_exists('ephpm_db_query')) {
    http_response_code(500);
    echo json_encode(['error' => 'ephpm_db_* functions not registered']);
    exit;
}
$sum = 0;
for ($i = 1; $i <= 10; $i++) {
    $rows = ephpm_db_query("SELECT v FROM bench WHERE id = {$i}");
    $sum += (int) $rows[0]['v'];
}
echo json_encode(['sum' => $sum]); // canonical gate: {"sum":55}
