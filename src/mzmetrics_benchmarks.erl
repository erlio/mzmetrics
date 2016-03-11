%% $ erl -pa deps/*/ebin ebin -noshell -eval "mzmetrics_benchmarks:bench(1000000, 1)." -eval "init:stop()."
%%

-module(mzmetrics_benchmarks).

-export([bench/2, bench/3, fc/0]).

-define(START, start).
-record('DOWN',
	{ref    :: reference(),
	 type   :: process,
	 object :: pid() | atom(),
	 info   :: noproc | noconnection | {'EXIT', pid(), any()}
	}).

flush() ->
    receive _ -> flush()
    after 0 -> ok
    end.


go(N, Pid, Ref) ->
    A = os:timestamp(),
    Pid ! ?START,
    receive
	#'DOWN'{ref = Ref} ->
	    B = os:timestamp(),
	    flush(),
	    (N * 1000000) div timer:now_diff(B, A)
    end.

run_one_loop(N, LoopFun, State) ->
    {CallerPid, CallerMon} = erlang:spawn_monitor(
                               fun() ->
                                       receive
                                           start ->
                                               LoopFun(N, State)
                                       end
                               end),
    go(N, CallerPid, CallerMon).

gather_results([]) ->
    [];
gather_results([Pid | Pids]) ->
    receive
        {Pid, Result} ->
            [Result | gather_results(Pids)]
    end.

concurrently(C, Fun) ->
    concurrently(C, Fun, []).

concurrently(C, Fun, Acc) when C > 0 ->
    Parent = self(),
    Pid = erlang:spawn(fun() ->
                               Parent ! {self(), Fun()}
                       end),
    concurrently(C - 1, Fun, [Pid | Acc]);
concurrently(0, _Fun, Acc) ->
    gather_results(Acc).

do_bench(N, C, Setup, LoopFun) ->
    do_bench_1(fun() ->
                       State = Setup(),
                       Results = concurrently(
                                   C,
                                   fun() ->
                                           run_one_loop(N, LoopFun, State)
                                   end),
                       lists:sum(Results) div C
               end).

do_bench_1(Fun) ->
    Parent = self(),
    {Pid, Monitor} = spawn_monitor(
                       fun() ->
                               Parent ! {result, self(), Fun()}
                       end),
    receive
        {result, Pid, Result} ->
            Result;
        {'DOWN', Monitor, _, _, Reason} ->
            {error, {benchmark_failed, Reason}}
    end.

-spec fc() -> ok.
fc() ->
    ok.

metrics_update_counter_loop(N, Name) when N > 0 ->
    mzmetrics:incr_resource_counter(Name, 0),
    metrics_update_counter_loop(N - 1, Name);
metrics_update_counter_loop(_, _) ->
    ok.

repeat_loop(Name, N, C, 1, Acc) ->
    Fun = atom_to_fun(Name),
    [Fun(N, C) | Acc];
repeat_loop(Name, N, C, R, Acc) ->
    Fun = atom_to_fun(Name),
    repeat_loop(Name, N, C, R-1, [Fun(N, C) | Acc]).

metrics_update_counter(N, C) ->
    do_bench(
      N,
      C,
      fun() ->
              mzmetrics:alloc_resource(0, "myrandomstring", 8)
      end,
      fun metrics_update_counter_loop/2).

-define(BENCH(Name, N, C, R),
        io:format("~p(~p, ~p) -> ~p/sec~n", [Name, N, C, lists:sum(repeat_loop(Name, N, C, R, [])) div R])).

exometer_counter_update(N, C) ->
    do_bench(
      N,
      C,
      fun() ->
              Name = [make_ref()],
              exometer:new(Name, counter),
              Name
      end,
      fun exometer_update_loop/2).

exometer_update_loop(N, Name) when N > 0 ->
    exometer:update(Name, 1),
    exometer_update_loop(N - 1, Name);
exometer_update_loop(_, _) ->
    ok.

exometer_fast_counter_update(N, C) ->
    do_bench(
      N,
      C,
      fun() ->
              Name = [make_ref()],
              exometer:new(Name, fast_counter, [{function, {?MODULE, fc}}]),
              Name
      end,
      fun exometer_update_loop/2).

ets_update_counter_loop(N, Name) when N > 0 ->
    ets:update_counter(exometer_util:table(), Name, {6, 1}),
    ets_update_counter_loop(N - 1, Name);
ets_update_counter_loop(_, _) ->
    ok.

ets_update_counter(N, C) ->
    do_bench(
      N,
      C,
      fun() ->
              Name = [make_ref()],
              exometer:new(Name, counter),
              Name
      end,
      fun ets_update_counter_loop/2).

folsom_update_counter_loop(N, Name) when N > 0 ->
    folsom_metrics:notify({Name, {inc, 1}}),
    folsom_update_counter_loop(N - 1, Name);
folsom_update_counter_loop(_, _) ->
    ok.

folsom_update_counter(N, C) ->
    do_bench(
      N,
      C,
      fun() ->
              Name = [make_ref()],
              folsom_metrics:new_counter(Name),
              Name
      end,
      fun folsom_update_counter_loop/2).

atom_to_fun(metrics_update_counter) ->
    fun metrics_update_counter/2;
atom_to_fun(ets_update_counter) ->
    fun ets_update_counter/2;
atom_to_fun(folsom_update_counter) ->
    fun folsom_update_counter/2;
atom_to_fun(exometer_fast_counter_update) ->
    fun exometer_fast_counter_update/2;
atom_to_fun(exometer_counter_update) ->
    fun exometer_counter_update/2.

-spec bench(non_neg_integer(), non_neg_integer()) -> ok.
bench(N, C) -> bench(N, C, 1).

-spec bench(non_neg_integer(), non_neg_integer(), non_neg_integer()) -> ok.
bench(N, C, R) ->
    application:ensure_all_started(mzmetrics),
    application:ensure_all_started(exometer_core),
    application:ensure_all_started(folsom),
    [exometer:delete(M) || {M, _} <- exometer:find_entries(['_'])],

    io:format("# Counter updates per process: ~p~n", [N]),
    io:format("# Processes: ~p~n", [C]),
    io:format("# Repeats: ~p~n", [R]),
    io:format("# Schedulers: ~p~n", [erlang:system_info(schedulers)]),
    io:format("~nbenchmark_name(Iterations, Concurrency) -> avg ops/sec:~n"),

    io:format("~n-- Benchmark data for counters --~n"),
    ?BENCH(metrics_update_counter, N, C, R),
    ?BENCH(ets_update_counter, N, C, R),
    ?BENCH(exometer_counter_update, N, C, R),
    ?BENCH(exometer_fast_counter_update, N, C, R),
    ?BENCH(folsom_update_counter, N, C, R),
    ok.

