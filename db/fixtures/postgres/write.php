<?php
/** Write-path fixture: one INSERT per request, each its own implicit txn. */
header('Content-Type: application/json');
try {
$host = getenv('DB_HOST') ?: '127.0.0.1';
$port = getenv('DB_PORT') ?: '5432';
$name = getenv('DB_NAME') ?: 'bench';
$user = getenv('DB_USER') ?: 'postgres';
$pass = getenv('DB_PASSWORD');
$pass = ($pass === false) ? 'bench' : $pass;
$pdo = new PDO("pgsql:host={$host};port={$port};dbname={$name}", $user, $pass,
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $affected = $pdo->exec('INSERT INTO wbench (val) VALUES (1)');
    echo json_encode(['status' => 'ok', 'affected' => $affected]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
