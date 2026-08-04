<?php
/**
 * One-shot seeder for the db.php benchmark fixture.
 *
 * Creates `bench` and fills ids 1..10. Idempotent: drops first, so a
 * re-run between engine lanes starts from an identical table.
 *
 * Kept separate from db.php so the measured path contains only the ten
 * SELECTs — no DDL, no writes.
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

    $pdo->exec('DROP TABLE IF EXISTS bench');
    $pdo->exec('CREATE TABLE bench (id INTEGER PRIMARY KEY, val INTEGER)');
    // Write-path table for write.php. AUTOINCREMENT so concurrent
    // inserters never collide on the primary key.
    $pdo->exec('DROP TABLE IF EXISTS wbench');
    $pdo->exec('CREATE TABLE wbench (id INTEGER PRIMARY KEY AUTOINCREMENT, val INTEGER)');
    for ($i = 1; $i <= 10; $i++) {
        $pdo->exec("INSERT INTO bench (id, val) VALUES ({$i}, {$i})");
    }

    // Verify the fixture reads back exactly what db.php will sum: 1..10 = 55.
    $row = $pdo->query('SELECT COUNT(*) AS c, SUM(val) AS s FROM bench')
        ->fetch(PDO::FETCH_ASSOC);

    echo json_encode(['status' => 'ok', 'count' => $row['c'], 'sum' => $row['s']]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
