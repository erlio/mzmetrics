-module(mzmetrics_app).

-behaviour(application).

-type start_args() :: any().
-type app_state() :: any().

%% Application callbacks
-export([start/2, stop/1]).

%% ===================================================================
%% Application callbacks
%% ===================================================================
-spec start(application:start_type(), start_args()) ->
                   mzmetrics_sup:start_link().
start(_StartType, _StartArgs) ->
    mzmetrics_sup:start_link().

-spec stop(app_state()) -> application:stop().
stop(_State) ->
    ok.
