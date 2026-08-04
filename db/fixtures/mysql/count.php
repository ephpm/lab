<?php
/** Row-count probe -- used as a lane gate, never as a load fixture. */
header('Content-Type: application/json');
$table = preg_replace('/[^a-zA-Z0-9_]/', '', $_GET['t'] ?? 'bench');
try {
$host = getenv('DB_HOST') ?: '127.0.0.1';
$port = getenv('DB_PORT') ?: '3306';
$name = getenv('DB_NAME') ?: 'bench';
$user = getenv('DB_USER') ?: 'root';
$pass = getenv('DB_PASSWORD');
$pass = ($pass === false) ? '' : $pass;
$pdo = new PDO("mysql:host={$host};port={$port};dbname={$name}", $user, $pass,
    [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $row = $pdo->query("SELECT COUNT(*) AS c FROM {$table}")->fetch(PDO::FETCH_ASSOC);
    echo json_encode(['status' => 'ok', 'table' => $table, 'count' => (int) $row['c']]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
