-module(chat_to_pair_app).
-behaviour(application).

-export([start/2, stop/1]).

start(_StartType, _StartArgs) ->
    chat_to_pair_sup:start_link().

stop(_State) ->
    ok.
