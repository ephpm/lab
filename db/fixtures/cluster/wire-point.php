<?php
/**
 * The stock-pdo_mysql twin of point.php: the same ten sequential point
 * SELECTs, over the MySQL wire instead of through the bridge.
 *
 * In a per-site deployment ONE MySQL listener serves every tenant, and a
 * connection's database is fixed by the credential it authenticates
 * with, not by anything it claims. The router injects that credential
 * into this site's $_SERVER per request:
 *
 *   $_SERVER['DB_USER']     = the canonical site key
 *   $_SERVER['DB_PASSWORD'] = HMAC-SHA256(per-process master secret, site key)
 *
 * They are in $_SERVER, NOT the process environment -- getenv() will not
 * find them, and a fixture that used getenv() here would silently fall
 * back to an anonymous connection and fail auth. The single-site lanes
 * (S, W) have no per-site credential at all, so this falls back to the
 * root/empty pair those lanes use.
 *
 * WHY THIS CELL EXISTS, and why it is not redundant with point.php:
 * in per-site CLUSTERED mode the bridge forwards to the site's owner but
 * stock pdo_mysql does NOT -- it resolves the LOCAL database on whatever
 * node served the request (a documented gap in ephpm#416). So on a
 * non-owner this cell reads that node's local replica with no forward
 * hop, while point.php pays the hop. Measuring both is what makes the
 * "the hop is the difference" claim falsifiable rather than asserted:
 * if P3's wire-point were also slower than P2's, the slowdown would be
 * something other than forwarding.
 *
 * The per-request PDO connect is part of this number ON PURPOSE -- it is
 * what a real PHP request pays without persistent connections.
 *
 * Gated on the canonical {"sum":55}.
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
