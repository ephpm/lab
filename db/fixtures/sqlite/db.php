<?php
/**
 * Canonical `db.php` benchmark fixture per
 * site/content/benchmarking/methodology.md:
 *
 *   | `db.php` | 10 sequential PDO `SELECT`s | the database wire path
 *   | (proxy/litewire + PHP `pdo_mysql`) |
 *
 * Ten *sequential* point SELECTs on one connection. Sequential matters:
 * the fixture measures per-query round-trip through litewire's wire
 * translation, so the queries must not be batched or pipelined.
 *
 * The connection is opened per request (that is what a real PHP request
 * does without persistent connections), so each sample includes one
 * connect plus ten query round-trips.
 *
 * Seeded by seed.php, which must be called once before the run.
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

    $sum = 0;
    for ($i = 1; $i <= 10; $i++) {
        $stmt = $pdo->query("SELECT id, val FROM bench WHERE id = {$i}");
        $row = $stmt->fetch(PDO::FETCH_ASSOC);
        $sum += (int) ($row['val'] ?? 0);
    }

    echo json_encode(['status' => 'ok', 'sum' => $sum]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
