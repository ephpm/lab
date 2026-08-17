<?php
// Gate + seed for the db happy-path fixture: 10 deterministic rows through
// the ephpm_db_* bridge (values are fixed functions of the row id — nothing
// random to misreport).
header('Content-Type: application/json');
if (!function_exists('ephpm_db_execute') || !function_exists('ephpm_db_query')) {
    http_response_code(500);
    echo json_encode(['error' => 'ephpm_db_* functions not registered']);
    exit;
}
ephpm_db_execute('DROP TABLE IF EXISTS bench');
ephpm_db_execute('CREATE TABLE bench (id INTEGER PRIMARY KEY, v INTEGER NOT NULL)');
for ($i = 1; $i <= 10; $i++) {
    ephpm_db_execute("INSERT INTO bench (id, v) VALUES ({$i}, {$i})");
}
$rows = ephpm_db_query('SELECT COUNT(*) AS c FROM bench');
echo json_encode(['seeded' => true, 'count' => (int) $rows[0]['c']]);
