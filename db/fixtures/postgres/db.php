<?php
/**
 * Read-path fixture: one connect + ten SEQUENTIAL point SELECTs.
 *
 * Identical in shape to docroot/db.php (the litewire lanes). The only
 * difference is that a real pgsql server needs a database named in the
 * DSN, where litewire has an implicit one. Ten sequential -- never
 * batched, never pipelined -- so each sample is one connect plus ten
 * per-query round trips through whatever is in the path.
 */
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
    $sum = 0;
    for ($i = 1; $i <= 10; $i++) {
        $row = $pdo->query("SELECT id, val FROM bench WHERE id = {$i}")->fetch(PDO::FETCH_ASSOC);
        $sum += (int) ($row['val'] ?? 0);
    }
    echo json_encode(['status' => 'ok', 'sum' => $sum]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
