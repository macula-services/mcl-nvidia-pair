-module(chat_to_pair_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    %% chat_to_pair.erl is stateless -- no children. The dispatch lives
    %% in mcl_nvidia_pair_mesh_rpc, which calls chat_to_pair:chat/3
    %% directly.
    {ok, {#{strategy => one_for_one, intensity => 10, period => 10}, []}}.
