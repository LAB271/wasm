#!/usr/bin/env bats

# Test that Python workloads produce valid JSON output when run directly

@test "cpu_bound.py handle() returns valid JSON" {
  result=$(python3 -c "
import sys; sys.path.insert(0, '$BATS_TEST_DIRNAME/../workloads')
from cpu_bound import handle
import json
out = json.loads(handle('/'))
assert 'fib_30' in out
assert 'timings' in out
assert out['fib_30'] == 832040
print('ok')
")
  [ "$result" = "ok" ]
}

@test "json_transform.py handle() returns valid JSON" {
  result=$(python3 -c "
import sys; sys.path.insert(0, '$BATS_TEST_DIRNAME/../workloads')
from json_transform import handle
import json
out = json.loads(handle('/'))
assert 'input_size' in out
assert 'output_size' in out
assert 'timings' in out
assert out['items_in'] == 50
assert out['items_out'] == 25  # half are active
print('ok')
")
  [ "$result" = "ok" ]
}

@test "db_query.py handle() returns error for None row" {
  result=$(python3 -c "
import sys; sys.path.insert(0, '$BATS_TEST_DIRNAME/../workloads')
from db_query import handle
import json
out = json.loads(handle('/', None))
assert out == {'error': 'not found'}
print('ok')
")
  [ "$result" = "ok" ]
}

@test "db_query.py handle() formats a row correctly" {
  result=$(python3 -c "
import sys; sys.path.insert(0, '$BATS_TEST_DIRNAME/../workloads')
from db_query import handle
import json
out = json.loads(handle('/db?id=1', [1, 'Item 1', 42, 0.5]))
assert out['id'] == 1
assert out['name'] == 'Item 1'
assert out['value'] == 42
assert out['computed'] == 105.0
print('ok')
")
  [ "$result" = "ok" ]
}

@test "mixed.py handle() returns valid JSON without DB row" {
  result=$(python3 -c "
import sys; sys.path.insert(0, '$BATS_TEST_DIRNAME/../workloads')
from mixed import handle
import json
out = json.loads(handle('/'))
assert 'fib_25' in out
assert 'json_items' in out
assert out['db'] is None
assert 'timings' in out
print('ok')
")
  [ "$result" = "ok" ]
}

@test "mixed.py handle() includes DB info when row provided" {
  result=$(python3 -c "
import sys; sys.path.insert(0, '$BATS_TEST_DIRNAME/../workloads')
from mixed import handle
import json
out = json.loads(handle('/db?id=1', [1, 'Item 1', 42, 0.3]))
assert out['db'] is not None
assert out['db']['id'] == 1
print('ok')
")
  [ "$result" = "ok" ]
}
