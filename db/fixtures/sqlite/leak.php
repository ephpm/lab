<?php
/**
 * Session-state leakage probe for the pooled proxy lanes.
 *
 * The ephpm MySQL proxy holds ONE pooled backend connection for the whole
 * client session and returns it on disconnect -- with COM_RESET_CONNECTION
 * first when the session was "dirty" (reset_strategy = "smart").
 *
 * If that reset silently fails (pool.rs logs the failure at DEBUG and then
 * discards the connection), or if the backend does not implement
 * COM_RESET_CONNECTION at all, session state can outlive a PHP request.
 * ?set=1 dirties a user variable; ?get=1 on a LATER request asks whether
 * it survived. A non-NULL answer from ?get=1 is a leak.
 */
header('Content-Type: application/json');
$host = getenv('DB_HOST') ?: '127.0.0.1';
$port = getenv('DB_PORT') ?: '3306';
try {
    $pdo = new PDO("mysql:host={$host};port={$port}", 'root', '',
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    if (isset($_GET['set'])) {
        $pdo->exec("SET @leak_probe = 'ephpm_was_here'");
        echo json_encode(['status' => 'ok', 'action' => 'set']);
        exit;
    }
    $row = $pdo->query('SELECT @leak_probe AS v')->fetch(PDO::FETCH_ASSOC);
    echo json_encode(['status' => 'ok', 'action' => 'get', 'leaked' => $row['v']]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage()]);
}
