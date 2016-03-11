# MZ Erlang Metrics

Efficient per-CPU metrics (counters) for Erlang.

## Compile

    rebar get
    rebar compile

## Test

    rebar eunit

## Benchmark

    erl -pa deps/*/ebin ebin -noshell -eval "mzmetrics_benchmarks:bench(1000, 1)." -eval "init:stop()."

# TODO
    Verify unit tests
    Current library supports only creating new counters
