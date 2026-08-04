<?php
/**
 * Write-path fixture. The read fixture (db.php) cannot distinguish the
 * clustered lanes from the single-node ones: on a primary, a SELECT
 * never touches replication. The cost of clustering lands on WRITES --
 * sqld ships WAL frames over gRPC, CDC captures a turso_cdc row per
 * write and a tailer polls it -- so this is the fixture that separates
 * lane A from C and B from D.
 *
 * One INSERT per request against an append-only table. Each request is
 * its own implicit transaction, which is the shape a PHP app produces
 * and the shape CDC batches on (one TxnBatch per commit).
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

    $affected = $pdo->exec("INSERT INTO wbench (val) VALUES (1)");
    echo json_encode(['status' => 'ok', 'affected' => $affected]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
