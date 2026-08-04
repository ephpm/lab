<?php
/** PG-dialect seeder. SERIAL instead of AUTO_INCREMENT; same rows (1..10 => 55). */
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
    $pdo->exec('DROP TABLE IF EXISTS bench');
    $pdo->exec('CREATE TABLE bench (id INTEGER PRIMARY KEY, val INTEGER)');
    $pdo->exec('DROP TABLE IF EXISTS wbench');
    $pdo->exec('CREATE TABLE wbench (id SERIAL PRIMARY KEY, val INTEGER)');
    for ($i = 1; $i <= 10; $i++) {
        $pdo->exec("INSERT INTO bench (id, val) VALUES ({$i}, {$i})");
    }
    $row = $pdo->query('SELECT COUNT(*) AS c, SUM(val) AS s FROM bench')->fetch(PDO::FETCH_ASSOC);
    echo json_encode(['status' => 'ok', 'count' => (int) $row['c'], 'sum' => (int) $row['s']]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
