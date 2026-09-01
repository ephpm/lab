<?php
/**
 * LOCAL row-count probe. Never load -- a gate, and a setup step.
 *
 * It deliberately uses stock pdo_mysql rather than the bridge, and in
 * per-site clustered mode that choice is the entire point:
 *
 *  - the BRIDGE on a non-owner forwards to the site's HRW owner, so a
 *    bridge count would read the owner's database from every node and
 *    would agree with itself even if replication were completely dead.
 *    As a convergence proof it would be worthless.
 *  - stock pdo_mysql is NOT forwarded (the documented gap in ephpm#416):
 *    it resolves the LOCAL per-site database on whichever node served
 *    the request. That is exactly what a replication proof needs -- it
 *    reads this node's own replica.
 *
 * The same call also has a load-bearing SIDE EFFECT, which is why the
 * harness hits it on every node during setup. On a non-owner the bridge
 * never opens the site's local database (it hands back a remote proxy
 * instead), so the registry's open-hook never fires and that node never
 * starts a replica driver for the site -- it would sit there replicating
 * nothing. Opening the site over the wire is what registers it locally
 * and starts the driver. Setup order therefore matters: seed through the
 * bridge, then hit this on EVERY node, then gate on convergence.
 *
 * Credentials come from $_SERVER (see wire-point.php); single-site lanes
 * fall back to the root/empty pair.
 *
 *   GET count.php?t=bench    -- default
 *   GET count.php?t=wbench   -- the write table, used by the convergence gate
 */

header('Content-Type: application/json');

$host  = $_SERVER['DB_HOST']     ?? '127.0.0.1';
$port  = $_SERVER['DB_PORT']     ?? '3306';
$user  = $_SERVER['DB_USER']     ?? 'root';
$pass  = $_SERVER['DB_PASSWORD'] ?? '';
$table = preg_replace('/[^a-zA-Z0-9_]/', '', $_GET['t'] ?? 'bench');

try {
    $pdo = new PDO(
        "mysql:host={$host};port={$port}",
        $user,
        $pass,
        [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]
    );
    $row = $pdo->query("SELECT COUNT(*) AS c FROM {$table}")->fetch(PDO::FETCH_ASSOC);
    echo json_encode([
        'status' => 'ok',
        'scope'  => 'local',
        'table'  => $table,
        'count'  => (int) $row['c'],
    ]);
} catch (PDOException $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'scope' => 'local', 'message' => $e->getMessage()]);
}
