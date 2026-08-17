<?php
// Happy-path fixture A: the dispatch-overhead floor. Identical in spirit to
// the runtimes-bench hello fixture.
header('Content-Type: application/json');
echo json_encode(['ok' => true, 't' => microtime(true)]);
