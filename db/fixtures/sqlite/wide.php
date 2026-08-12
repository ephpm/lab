<?php
/**
 * Wire wide-select fixture: one SELECT returning 100 rows x 8 columns
 * (three INTs, four fixed-width TEXTs) over pdo_mysql -> litewire.
 *
 * Twin of fixtures/bridge/wide.php — same SQL text, same table, same
 * checksum gate (rows=100, sum(a+b+c)=106050). The table is seeded by
 * bridge/seed.php, which is deliberate: reading rows over the wire that
 * were written through the bridge proves both paths hit the same
 * backend instance.
 *
 * Connection opened per request, as in db.php — that is the cost a real
 * PHP request pays without persistent connections, and removing it is
 * precisely what the bridge lane demonstrates.
 */

header('Content-Type: application/json');

$host = getenv('DB_HOST') ?: '127.0.0.1';
$port = getenv('DB_PORT') ?: '3306';

try {
    $pdo = new PDO(
        "mysql:host={$host};port={$port}",
        'root',
        '',
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );

    $stmt = $pdo->query('SELECT id, a, b, c, d, e, f, g FROM wide ORDER BY id');
    $rows = $stmt->fetchAll(PDO::FETCH_ASSOC);

    $sum = 0;
    foreach ($rows as $row) {
        $sum += (int) $row['a'] + (int) $row['b'] + (int) $row['c'];
    }

    echo json_encode(['status' => 'ok', 'rows' => count($rows), 'sum' => $sum]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
