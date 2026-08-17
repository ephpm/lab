<?php
// kv-micro: in-process ephpm_kv_* SAPI latency, measured INSIDE one request
// with hrtime(). Sub-microsecond effects are far below any HTTP load tool's
// resolution, so this is a bare-loop measurement by construction — report it
// with the same caveat RUNTIMES-BENCH.md attaches to its musl/ZTS bare loops.
//
// GET params: size (value bytes, default 64), ops (loop count, default 100000).
// Returns JSON: ns/op for set, get, and incr, plus a readback checksum gate.
header('Content-Type: application/json');

if (!function_exists('ephpm_kv_set') || !function_exists('ephpm_kv_get')) {
    http_response_code(500);
    echo json_encode(['error' => 'ephpm_kv_* functions not registered']);
    exit;
}

$size = max(1, (int) ($_GET['size'] ?? 64));
$ops  = max(1000, (int) ($_GET['ops'] ?? 100000));

$val = str_repeat('x', $size);
$key = "bench:sapi:{$size}";
$ctr = "bench:sapi:ctr:{$size}";

// Warmup: touch the path, fault in the store shard, warm the allocator.
for ($i = 0; $i < 1000; $i++) {
    ephpm_kv_set($key, $val);
    ephpm_kv_get($key);
}
ephpm_kv_del($ctr);

$t0 = hrtime(true);
for ($i = 0; $i < $ops; $i++) {
    ephpm_kv_set($key, $val);
}
$t1 = hrtime(true);

$g = null;
for ($i = 0; $i < $ops; $i++) {
    $g = ephpm_kv_get($key);
}
$t2 = hrtime(true);

for ($i = 0; $i < $ops; $i++) {
    ephpm_kv_incr($ctr);
}
$t3 = hrtime(true);

// Gate: the loop must have moved real data, not a fused no-op.
if ($g !== $val) {
    http_response_code(500);
    echo json_encode(['error' => 'readback mismatch', 'got_len' => strlen((string) $g)]);
    exit;
}
$ctrVal = (int) ephpm_kv_get($ctr);
if ($ctrVal !== $ops) {
    http_response_code(500);
    echo json_encode(['error' => 'incr count mismatch', 'got' => $ctrVal, 'want' => $ops]);
    exit;
}

echo json_encode([
    'lane'          => 'sapi',
    'size'          => $size,
    'ops'           => $ops,
    'set_ns_per_op' => round(($t1 - $t0) / $ops, 1),
    'get_ns_per_op' => round(($t2 - $t1) / $ops, 1),
    'incr_ns_per_op' => round(($t3 - $t2) / $ops, 1),
]);
