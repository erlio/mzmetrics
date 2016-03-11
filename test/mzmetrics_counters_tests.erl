-module(mzmetrics_counters_tests).

-export([rabbit_main_handler/4, rabbit_sub_handler/4, per_family/1]).

-include("mzmetrics_header.hrl").
-include_lib("eunit/include/eunit.hrl").

-define(NUM_INCRS, 200).
-define(INIT_VALUE, 0).
-define(RABBIT_NAME_PREFIX, ?MODULE_STRING"_").
-define(MY_TAB_NAME, ?MODULE).
-define(NUM_RABBITS, 100).
-define(NUM_PROC_PER_RABBIT, 2).
-define(MAX_CNTR_UPDATE_VAL, 1000).
-define(MAX_RABBIT_NAME_SIZE, 1000).
-define(COUNTER_SIZE, 8).
-define(FAMILY_TO_TEST_RESET, 0).

%% Following three functions are used to generate a random counter
%% and the counter updates that each thread wants to work on
initialize_random_gen() ->
    rand:seed(exs64).

get_random_counter(Family) ->
    rand:uniform(mzmetrics:num_counters(Family)) - 1.

get_random_counter_update_val(Min) ->
    rand:uniform(?MAX_CNTR_UPDATE_VAL) - Min.

cntr_size_per_rabbit(Family) ->
    mzmetrics:num_counters(Family) * ?COUNTER_SIZE.

bin_data_size_per_rabbit(Family) ->
    ?MAX_RABBIT_NAME_SIZE + cntr_size_per_rabbit(Family).

test_update_counter(_, _, 0, Val) ->
    Val;
test_update_counter(Mycounters, Counter, N, Val) ->
    UpdateVal = get_random_counter_update_val(Val),
    mzmetrics:update_resource_counter(Mycounters, Counter, UpdateVal),
    test_update_counter(Mycounters, Counter, N-1, Val+UpdateVal).

test_initial_value(Mycounters, 0) ->
    ?assertEqual(0, mzmetrics:get_resource_counter(Mycounters, 0));
test_initial_value(Mycounters, X) ->
    ?assertEqual(0, mzmetrics:get_resource_counter(Mycounters, X)),
    test_initial_value(Mycounters, X-1).

test_get_all_resources(Family, Mytable, CntrReset) ->
    C = mzmetrics:get_all_resources(Family, CntrReset),
    ?assertEqual(0, byte_size(C) rem bin_data_size_per_rabbit(Family)),
    NumRabbits = byte_size(C) div bin_data_size_per_rabbit(Family),
    ?assert(?NUM_RABBITS =< NumRabbits),
    CntrVal = fun get_counter_val/3,
    extract_rabbit_data(CntrVal, Family, Mytable, ?NUM_RABBITS, C),
    case CntrReset of
        ?CNTR_RESET ->
            InitialCntrVal = fun get_initial_counter_val/3,
            D = mzmetrics:get_all_resources(Family, CntrReset),
            extract_rabbit_data(InitialCntrVal, Family, Mytable, ?NUM_RABBITS, D);
        _ ->
            do_nothing
    end.

get_counter_val(Mytable, RabbitName, Num) ->
    get_ets_counter_val(Mytable, RabbitName, Num).

get_initial_counter_val(_, _, _) ->
    ?INIT_VALUE.

check_counter_vals(CntrVal, Family, Mytable, RabbitName, CounterVals) ->
    check_counter_vals(CntrVal, Family, Mytable, RabbitName, CounterVals, 0).
check_counter_vals(CntrVal, Family, Mytable, RabbitName, CounterVals, Num) ->
    Max = mzmetrics:num_counters(Family),
    case Num of
        Max ->
            ok;
        _ ->
            [H|T] = CounterVals,
            ?assertEqual(CntrVal(Mytable, RabbitName, Num), H),
            check_counter_vals(CntrVal, Family, Mytable, RabbitName, T, Num + 1)
    end.

extract_rabbit_data(CntrVal, Family, Mytable, 1, BinData) ->
    CounterVals = extract_counter_vals(Family, binary:part(BinData, ?MAX_RABBIT_NAME_SIZE, cntr_size_per_rabbit(Family))),
    ?assertEqual(mzmetrics:num_counters(Family), lists:flatlength(CounterVals)),
    [RabbitName|_] = binary:split(BinData, [<<0>>]),
    check_counter_vals(CntrVal, Family, Mytable, binary_to_list(RabbitName), CounterVals),
    delete_ets_counter_val(Mytable, binary_to_list(RabbitName));
extract_rabbit_data(CntrVal, Family, Mytable, N, BinData) ->
    CounterVals = extract_counter_vals(Family, binary:part(BinData, ?MAX_RABBIT_NAME_SIZE, cntr_size_per_rabbit(Family))),
    ?assertEqual(mzmetrics:num_counters(Family), lists:flatlength(CounterVals)),
    BinDataPerRabbit = bin_data_size_per_rabbit(Family),
    case binary:split(BinData, [<<0>>]) of
        [<<?RABBIT_NAME_PREFIX, _/bytes>> = RabbitName|_] ->
            check_counter_vals(CntrVal, Family, Mytable, binary_to_list(RabbitName), CounterVals),
            delete_ets_counter_val(Mytable, binary_to_list(RabbitName)),
            extract_rabbit_data(CntrVal, Family, Mytable, N-1, binary:part(BinData, BinDataPerRabbit, byte_size(BinData) - BinDataPerRabbit));
        [_|_] ->
            %% test isolation leak from other tests
            extract_rabbit_data(CntrVal, Family, Mytable, N, binary:part(BinData, BinDataPerRabbit, byte_size(BinData) - BinDataPerRabbit))
    end.

extract_counter_vals(Family, BinData) ->
    extract_counter_vals(Family, BinData, 0, []).
extract_counter_vals(Family, BinData, Offset, Acc) ->
    CntrSize = cntr_size_per_rabbit(Family),
    case Offset of
        CntrSize ->
            Acc;
        _ ->
            <<X:64/little-unsigned-integer>> = binary:part(BinData, Offset, ?COUNTER_SIZE),
            extract_counter_vals(Family, BinData, Offset + ?COUNTER_SIZE, Acc ++ [X])
    end.

delete_ets_counter_val(Mytable, RabbitName) ->
    true=ets:delete(Mytable, RabbitName).

get_ets_counter_val(Mytable, RabbitName, Counter) ->
    ets:lookup_element(Mytable, RabbitName, 2+Counter).

incr_ets_counter_val(Mytable, RabbitName, Counter, Val) ->
    ets:update_counter(Mytable, RabbitName, {2+Counter, Val}).

create_my_list(0, Acc) ->
    Acc;
create_my_list(Num, Acc) ->
    create_my_list(Num - 1, [0|Acc]).

init_counters_in_pdict(Family, Mytable, RabbitName) ->
    X = create_my_list(mzmetrics:num_counters(Family), []),
    ets:insert(Mytable, list_to_tuple([RabbitName | X])).

%% This is the function that is spawned by rabbit_main_handler
-spec rabbit_sub_handler(Family::metrics:metric_type(), Pid::pid(),
                          Mytable::ets:tid(), RabbitName::binary()) -> any().
rabbit_sub_handler(Family, Pid, Mytable, RabbitName) ->
    Mycounters = mzmetrics:alloc_resource(Family, RabbitName, mzmetrics:num_counters(Family)),
    initialize_random_gen(),
    Counter = get_random_counter(Family),
    UpdateVal=test_update_counter(Mycounters, Counter, ?NUM_INCRS, 0),
    incr_ets_counter_val(Mytable, RabbitName, Counter, UpdateVal),
    Pid ! {self(), ok}.

%% This function initializes rabbit specific data and spawns
%% children to act upon this rabbit's counters
-spec rabbit_main_handler(Family::metrics:metric_type(), Pid::pid(),
                          X::non_neg_integer(), Mytable::ets:tid()) -> any().
rabbit_main_handler(Family, Pid, X, Mytable) ->
    initialize_random_gen(),
    RabbitName = ?RABBIT_NAME_PREFIX ++ integer_to_list(X),
    Mycounters = mzmetrics:alloc_resource(Family, RabbitName, mzmetrics:num_counters(Family)),
    init_counters_in_pdict(Family, Mytable, RabbitName),
    test_initial_value(Mycounters, mzmetrics:num_counters(Family) - 1),
    [spawn(?MODULE, rabbit_sub_handler, [Family, self(), Mytable, RabbitName])
        || _ <- lists:seq(1,?NUM_PROC_PER_RABBIT)],
    wait_for_children(?NUM_PROC_PER_RABBIT, []),
    Pid ! {self(), ok}.

%% Wait for all the children to reach the next barrier point
wait_for_children(0, Acc) ->
    Acc;
wait_for_children(N, Acc) ->
    receive
        {Pid, ok} ->
            wait_for_children(N-1, Acc ++ [Pid]);
        _Unexpected ->
            error(unexpected)
    end.

-spec per_family(Family::non_neg_integer()) -> any().
per_family(Family) ->
    undefined=ets:info(?MY_TAB_NAME),
    Mytable=ets:new(?MY_TAB_NAME, [set,public]),
    Pid = self(),
    [spawn(?MODULE, rabbit_main_handler, [Family, Pid, I, Mytable])
    || I <- lists:seq(1,?NUM_RABBITS)],
    wait_for_children(?NUM_RABBITS, []),
    ?assertEqual(?NUM_RABBITS, ets:info(Mytable, size)),
    case Family of
        ?FAMILY_TO_TEST_RESET ->
            CntrReset = ?CNTR_RESET;
        _ ->
            CntrReset = ?CNTR_DONT_RESET
    end,
    test_get_all_resources(Family, Mytable, CntrReset),
    ?assertEqual(0, ets:info(Mytable, size)),
    ets:delete(Mytable).

%% In summary, the main test creates an ets table to share with all
%% the children and this ets table is used to track the counter updates
%% that each child does. Once all the children have executed, we get all
%% the counters and then verify them against the values in ets table.
-spec incr_get_test_() -> any().
incr_get_test_() ->
    [
     {"Some simple test",
      fun() ->
              initialize_random_gen(),
              [per_family(Family) || Family <- lists:seq(0,1)]
      end
     }
    ].
