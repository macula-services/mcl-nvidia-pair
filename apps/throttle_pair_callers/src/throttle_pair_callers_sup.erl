-module(throttle_pair_callers_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        #{id => throttle_pair_callers,
          start => {throttle_pair_callers, start_link, []},
          restart => permanent, shutdown => 5000,
          type => worker, modules => [throttle_pair_callers]}
    ],
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, Children}}.
