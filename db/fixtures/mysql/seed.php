<?php
/**
 * MySQL-dialect twin of docroot/seed.php.
 *
 * Differences from the litewire seeder, and only these:
 *   * AUTO_INCREMENT (MySQL) instead of AUTOINCREMENT (SQLite)
 *   * the DSN names a database -- a real server has no implicit "main"
 *
 * db.php and write.php are byte-identical copies of the litewire ones, so
 * the measured path is the same fixture in every MySQL-shaped lane.
 */
header('Content-Type: application/json');
$host = getenv('DB_HOST') ?: '127.0.0.1';
$port = getenv('DB_PORT') ?: '3306';
$name = getenv('DB_NAME') ?: 'bench';
$user = getenv('DB_USER') ?: 'root';
$pass = getenv('DB_PASSWORD');
$pass = ($pass === false) ? '' : $pass;
try {
    $pdo = new PDO("mysql:host={$host};port={$port};dbname={$name}", $user, $pass,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $pdo->exec('DROP TABLE IF EXISTS bench');
    $pdo->exec('CREATE TABLE bench (id INTEGER PRIMARY KEY, val INTEGER)');
    $pdo->exec('DROP TABLE IF EXISTS wbench');
    $pdo->exec('CREATE TABLE wbench (id INTEGER PRIMARY KEY AUTO_INCREMENT, val INTEGER)');
    for ($i = 1; $i <= 10; $i++) {
        $pdo->exec("INSERT INTO bench (id, val) VALUES ({$i}, {$i})");
    }
    $row = $pdo->query('SELECT COUNT(*) AS c, SUM(val) AS s FROM bench')->fetch(PDO::FETCH_ASSOC);
    echo json_encode(['status' => 'ok', 'count' => (int) $row['c'], 'sum' => (int) $row['s']]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
