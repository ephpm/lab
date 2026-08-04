<?php
/**
 * Row-count probe. Used on a REPLICA to prove replication actually
 * converged before any clustered number is believed.
 *
 * Without this, a clustered lane whose replication is silently broken
 * benchmarks exactly like a fast single node -- and would be reported as
 * a great result. Verify, then measure.
 */

header('Content-Type: application/json');

$host = getenv('DB_HOST') ?: '127.0.0.1';
$port = getenv('DB_PORT') ?: '3306';
$table = preg_replace('/[^a-zA-Z0-9_]/', '', $_GET['t'] ?? 'bench');

try {
    $pdo = new PDO(
        "mysql:host={$host};port={$port}",
        'root',
        '',
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
    $row = $pdo->query("SELECT COUNT(*) AS c FROM {$table}")->fetch(PDO::FETCH_ASSOC);
    echo json_encode(['status' => 'ok', 'table' => $table, 'count' => (int) $row['c']]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
