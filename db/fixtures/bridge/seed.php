<?php
/**
 * One-shot seeder for the wide-select fixture, executed THROUGH THE
 * BRIDGE (ephpm_db_execute), which makes it a gate as well as a seeder:
 * if the ephpm_db_* functions are not registered this returns an error
 * body and the lane never starts.
 *
 * Deterministic by construction ("fixed seed" without an RNG): 100 rows,
 * three INT columns (a=3i, b=7i, c=11i) and four TEXT columns of fixed
 * content and width. The checksum every wide fixture is gated on is
 *   SUM(a+b+c) = (3+7+11) * sum(1..100) = 21 * 5050 = 106050.
 *
 * Seeding through the bridge and then reading the same table over the
 * MySQL wire (fixtures/sqlite/wide.php) also proves both paths hit the
 * SAME backend instance — a mislabelled lane pointing at a different
 * database fails the cross-path gate instead of producing a confident
 * wrong table.
 */

header('Content-Type: application/json');

if (!function_exists('ephpm_db_query') || !function_exists('ephpm_db_execute')) {
    http_response_code(500);
    echo json_encode([
        'status' => 'error',
        'message' => 'ephpm_db_* functions are not registered (image older than v0.6.3, or no [db.sqlite])',
    ]);
    return;
}

try {
    ephpm_db_execute('DROP TABLE IF EXISTS wide');
    ephpm_db_execute(
        'CREATE TABLE wide ('
        . 'id INTEGER PRIMARY KEY, '
        . 'a INTEGER, b INTEGER, c INTEGER, '
        . 'd TEXT, e TEXT, f TEXT, g TEXT)'
    );
    for ($i = 1; $i <= 100; $i++) {
        ephpm_db_execute(
            'INSERT INTO wide (id, a, b, c, d, e, f, g) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
            [
                $i,
                $i * 3,
                $i * 7,
                $i * 11,
                sprintf('colD-%04d-%s', $i, str_repeat('d', 24)),
                sprintf('colE-%04d-%s', $i, str_repeat('e', 24)),
                sprintf('colF-%04d-%s', $i, str_repeat('f', 24)),
                sprintf('colG-%04d-%s', $i, str_repeat('g', 24)),
            ]
        );
    }

    $rows = ephpm_db_query('SELECT COUNT(*) AS n, SUM(a + b + c) AS s FROM wide');
    echo json_encode([
        'status' => 'ok',
        'rows'   => (int) $rows[0]['n'],
        'sum'    => (int) $rows[0]['s'],
    ]);
} catch (Exception $e) {
    http_response_code(500);
    echo json_encode(['status' => 'error', 'message' => $e->getMessage(), 'code' => $e->getCode()]);
}
