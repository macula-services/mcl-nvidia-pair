%%% @doc Per-caller fixed-window rate limit on mcl-nvidia-pair/chat.
%%%
%%% The minimum viable version of backpressure that did not exist
%%% anywhere in this whole ecosystem before this module: neither PAIR
%%% nor Macula's own RPC path has any inbound throttle. In-memory,
%%% single-node, no cross-bridge coordination -- correct for the MVP
%%% deployment shape (one bridge per PAIR cluster), not a distributed
%%% rate limiter.
%%%
%%% Keyed by the wire-authenticated `caller' macula_station_link
%%% merges into every inbound call's payload before a handler ever
%%% runs -- see mcl_nvidia_pair_mesh_rpc's own moduledoc for why
%%% that field, and no other, is the correct key.
%%%
%%% Fixed window, not a token bucket: each (Caller, WindowIndex) pair
%%% is its own ETS row, so there is no read-then-write window-rollover
%%% branch to get wrong -- `ets:update_counter/4' with a default
%%% initial value makes "first call in a window" and "Nth call in a
%%% window" the same atomic operation. A rejected call still counts
%%% against the window (fail-closed): retrying a rejected call must
%%% not be a way to spend more than the configured budget.
-module(throttle_pair_callers).
-behaviour(gen_server).

-export([start_link/0, allow/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, throttle_pair_callers_windows).

%% Requests a single caller may make within one window. Deliberately
%% conservative for a v0 default: this bridge forwards onto real
%% household hardware, not a horizontally-scaled backend.
-define(DEFAULT_MAX_PER_WINDOW, 20).
-define(DEFAULT_WINDOW_SECONDS, 60).

%% How often stale windows are swept from the table. Independent of
%% the rate-limit window itself so a very short configured window
%% (tests) doesn't force a very short sweep interval.
-define(SWEEP_INTERVAL_MS, 60_000).

-spec allow(term()) -> ok | {error, rate_limited}.
allow(undefined) ->
    {error, rate_limited};
allow(Caller) ->
    Window = window_index(),
    Max = max_per_window(),
    Key = {Caller, Window},
    Count = ets:update_counter(?TABLE, Key, {2, 1}, {Key, 0}),
    verdict(Count, Max).

verdict(Count, Max) when Count =< Max -> ok;
verdict(_Count, _Max)                 -> {error, rate_limited}.

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) ->
    ?TABLE = ets:new(?TABLE, [set, public, named_table, {write_concurrency, true}]),
    schedule_sweep(),
    {ok, #{}}.

handle_call(_, _From, S) -> {reply, {error, unknown_call}, S}.
handle_cast(_, S)        -> {noreply, S}.

handle_info(sweep, S) ->
    sweep(),
    schedule_sweep(),
    {noreply, S};
handle_info(_, S) ->
    {noreply, S}.

terminate(_, _) -> ok.

%%% Internal

window_index() ->
    erlang:system_time(second) div window_seconds().

window_seconds() ->
    application:get_env(throttle_pair_callers, window_seconds, ?DEFAULT_WINDOW_SECONDS).

max_per_window() ->
    application:get_env(throttle_pair_callers, max_per_window, ?DEFAULT_MAX_PER_WINDOW).

schedule_sweep() ->
    erlang:send_after(?SWEEP_INTERVAL_MS, self(), sweep).

%% Drops every row from a window that has already fully closed (the
%% current window and the one immediately before it are kept -- a
%% caller's window can still be "the previous one" for a moment after
%% rollover, since window_index/0 is read independently by every
%% caller rather than driven by this sweep).
sweep() ->
    Current = window_index(),
    MatchSpec = [{{{'_', '$1'}, '_'}, [{'<', '$1', Current - 1}], [true]}],
    ets:select_delete(?TABLE, MatchSpec).
