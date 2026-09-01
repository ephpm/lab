<?php
/**
 * NOT A MEASURED CELL. This fixture exists only for the divergence probe
 * the harness runs AFTER every measurement in the per-site clustered
 * lanes, and it is deliberately never used as load.
 *
 * It writes one row over stock pdo_mysql. On the site's HRW owner that
 * is an ordinary write which replicates. On a NON-owner it is not
 * forwarded (the documented ephpm#416 gap): it lands in that node's
 * local replica only, is invisible to every other node, and is discarded
 * the next time that replica re-bootstraps from the owner. The probe
 * writes here, then counts on the owner, and prints the divergence --
 * turning a paragraph of prose into an observation.
 *
 * ORDERING IS NOT OPTIONAL. A probe that mutates server state runs after
 * the measurement, never before. This one writes a row that would
 * otherwise show up in the middle of a measured lane's data set, and the
 * lab has been burned by exactly this shape before: a session-leak probe
 * placed BEFORE each pooled proxy lane poisoned the connection pool, and
 * the lanes then recorded 876 requests/second in which every response
 * was an HTTP 500. Serving an error is cheap, so it read as a great
 * throughput number.
 */

header('Content-Type: application/json');

$host = $_SERVER['DB_HOST']     ?? '127.0.0.1';
$port = $_SERVER['DB_PORT']     ?? '3306';
$user = $_SERVER['DB_USER']     ?? 'root';
$pass = $_SERVER['DB_PASSWORD'] ?? '';

try {
    $pdo = new PDO(
        "mysql:host={$host};port={$port}",
        $user,
        $pass,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
    $pdo->exec('INSERT INTO wbench (val) VALUES (99)');
    echo json_encode(['status' => 'ok', 'wrote' => 'local']);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
