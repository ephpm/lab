<?php
// kv-micro: RESP2 round-trip latency against ePHPm's embedded RESP listener,
// measured from PHP over a raw TCP socket (no client library — the point is
// the wire round-trip, not Predis's abstraction overhead; Predis/phpredis
// numbers sit above this floor, never below it).
//
// Strict ping-pong: one command, wait for the full reply, next command —
// c=1 round-trip time, the number the kv-from-php guide quotes in µs/op.
//
// GET params: size (value bytes, default 64), ops (default 20000),
//             port (RESP listener port, default 16390).
header('Content-Type: application/json');

$size = max(1, (int) ($_GET['size'] ?? 64));
$ops  = max(500, (int) ($_GET['ops'] ?? 20000));
$port = (int) ($_GET['port'] ?? 16390);

$ctx = stream_context_create(['socket' => ['tcp_nodelay' => true]]);
$sock = @stream_socket_client(
    "tcp://127.0.0.1:{$port}",
    $errno,
    $errstr,
    5,
    STREAM_CLIENT_CONNECT,
    $ctx
);
if ($sock === false) {
    http_response_code(500);
    echo json_encode(['error' => "connect failed: {$errstr} ({$errno})"]);
    exit;
}
stream_set_timeout($sock, 10);

/** Write a RESP2 command array, fully. */
function resp_cmd($sock, array $parts): void
{
    $out = '*' . count($parts) . "\r\n";
    foreach ($parts as $p) {
        $out .= '$' . strlen($p) . "\r\n" . $p . "\r\n";
    }
    for ($off = 0, $len = strlen($out); $off < $len;) {
        $n = fwrite($sock, substr($out, $off));
        if ($n === false || $n === 0) {
            throw new RuntimeException('short write');
        }
        $off += $n;
    }
}

/** Read one RESP2 reply; returns [type, payload]. */
function resp_reply($sock): array
{
    $line = fgets($sock);
    if ($line === false) {
        throw new RuntimeException('read failed');
    }
    $type = $line[0];
    $rest = substr($line, 1, -2);
    if ($type === '+' || $type === '-' || $type === ':') {
        return [$type, $rest];
    }
    if ($type === '$') {
        $n = (int) $rest;
        if ($n < 0) {
            return ['$', null];
        }
        $buf = '';
        $want = $n + 2; // payload + CRLF
        while (strlen($buf) < $want) {
            $chunk = fread($sock, $want - strlen($buf));
            if ($chunk === false || $chunk === '') {
                throw new RuntimeException('short bulk read');
            }
            $buf .= $chunk;
        }
        return ['$', substr($buf, 0, $n)];
    }
    throw new RuntimeException("unexpected reply type: {$type}");
}

$val = str_repeat('x', $size);
$key = "bench:resp:{$size}";

try {
    // Warmup + liveness gate.
    resp_cmd($sock, ['PING']);
    [$t, $p] = resp_reply($sock);
    if ($t !== '+' || strcasecmp($p, 'PONG') !== 0) {
        throw new RuntimeException("PING got {$t}{$p}");
    }
    for ($i = 0; $i < 500; $i++) {
        resp_cmd($sock, ['SET', $key, $val]);
        resp_reply($sock);
        resp_cmd($sock, ['GET', $key]);
        resp_reply($sock);
    }

    $t0 = hrtime(true);
    for ($i = 0; $i < $ops; $i++) {
        resp_cmd($sock, ['SET', $key, $val]);
        [$rt, ] = resp_reply($sock);
        if ($rt === '-') {
            throw new RuntimeException('SET error reply');
        }
    }
    $t1 = hrtime(true);

    $g = null;
    for ($i = 0; $i < $ops; $i++) {
        resp_cmd($sock, ['GET', $key]);
        [, $g] = resp_reply($sock);
    }
    $t2 = hrtime(true);
} catch (RuntimeException $e) {
    http_response_code(500);
    echo json_encode(['error' => $e->getMessage()]);
    exit;
}

// Gate: full value made the round trip.
if ($g !== $val) {
    http_response_code(500);
    echo json_encode(['error' => 'readback mismatch', 'got_len' => strlen((string) $g)]);
    exit;
}

echo json_encode([
    'lane'          => 'resp',
    'size'          => $size,
    'ops'           => $ops,
    'set_us_per_op' => round(($t1 - $t0) / $ops / 1000, 2),
    'get_us_per_op' => round(($t2 - $t1) / $ops / 1000, 2),
]);
