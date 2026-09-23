-module(throttle_pair_callers_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    throttle_pair_callers_sup:start_link().

stop(_State) ->
    ok.
