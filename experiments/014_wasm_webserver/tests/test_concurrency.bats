#!/usr/bin/env bats
# The concurrency model is the sharpest difference between this experiment's two
# legs, and it was previously only inferable by reading the source. These tests
# assert it in both directions, so a change in either is caught rather than
# silently altering what the experiment demonstrates.
#
#   Leg A — the guest owns the socket. It runs `for stream in
#           listener.incoming() { handle_connection(..) }` with no spawn, no
#           thread, no async, because a wasm32-wasip1 guest cannot spawn. One
#           connection at a time; the next client waits.
#
#   Leg B — Spin owns the socket. The guest is `fn handle_request(req) ->
#           Response` and cannot express concurrency at all. Spin serves
#           overlapping requests. Concurrency is a HOST property you rent, not
#           a GUEST property you write.
#
# The probe is client-side only (tests/concurrency_probe.py) — see its docstring.
# It distinguishes "blocked behind another client" from "server is down" by
# releasing the first client and requiring an answer, so a dead server fails
# rather than masquerading as sequential.

DIR="$BATS_TEST_DIRNAME/.."
PROBE="$BATS_TEST_DIRNAME/concurrency_probe.py"
LEG_A_PORT=18421
LEG_B_PORT=18422

setup_file() {
    command -v wasmtime >/dev/null || skip "wasmtime not installed"
    command -v python3 >/dev/null || skip "python3 not installed"
}

teardown() {
    pkill -f leg_a_tcp.wasm 2>/dev/null || true
    pkill -f "spin up" 2>/dev/null || true
    sleep 0.3
}

port_free() {
    ! lsof -i :"$1" -sTCP:LISTEN >/dev/null 2>&1
}

@test "leg A (guest owns the socket) handles connections SEQUENTIALLY" {
    local wasm="$DIR/leg_a_tcp/target/wasm32-wasip2/release/leg_a_tcp.wasm"
    [ -f "$wasm" ] || skip "leg A not built — run 'make build-a'"
    port_free "$LEG_A_PORT" || skip "port $LEG_A_PORT in use"

    PORT=$LEG_A_PORT wasmtime run --wasi inherit-network \
        --dir "$DIR/data"::/ --env CSV_PATH=/records.csv --env PORT=$LEG_A_PORT \
        "$wasm" >/tmp/bats-leg-a.log 2>&1 &
    sleep 4

    run python3 "$PROBE" "$LEG_A_PORT"
    echo "$output"
    [ "$status" -eq 0 ]
    # Not merely "no response" — the probe proves the server was alive and
    # answered as soon as the blocking client was released.
    [[ "$output" == *"SEQUENTIAL"* ]]
}

@test "leg B (Spin owns the socket) handles connections CONCURRENTLY" {
    command -v spin >/dev/null || skip "spin not installed"
    [ -f "$DIR/leg_b_serverless/spin.toml" ] || skip "leg B not present"
    port_free "$LEG_B_PORT" || skip "port $LEG_B_PORT in use"

    ( cd "$DIR/leg_b_serverless" && spin up --from spin.toml \
        --listen 127.0.0.1:$LEG_B_PORT >/tmp/bats-leg-b.log 2>&1 & )
    sleep 8

    run python3 "$PROBE" "$LEG_B_PORT"
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" == *"CONCURRENT"* ]]
}

@test "the probe fails loudly rather than reporting SEQUENTIAL for a dead server" {
    # Guards the test above: silence must not be mistaken for serialisation.
    port_free 18423 || skip "port 18423 in use"
    run python3 "$PROBE" 18423
    [ "$status" -eq 2 ]
    [[ "$output" == *"UNREACHABLE"* ]]
}
