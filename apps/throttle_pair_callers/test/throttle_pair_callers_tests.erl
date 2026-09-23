-module(throttle_pair_callers_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    application:set_env(throttle_pair_callers, max_per_window, 3),
    application:set_env(throttle_pair_callers, window_seconds, 60),
    {ok, Pid} = throttle_pair_callers:start_link(),
    Pid.

teardown(Pid) ->
    application:unset_env(throttle_pair_callers, max_per_window),
    application:unset_env(throttle_pair_callers, window_seconds),
    %% gen_server:stop/1, not exit(Pid, shutdown): start_link/0 links
    %% the calling (eunit fixture-runner) process, and a raw exit
    %% signal propagates back through that link and kills the runner
    %% too once it isn't trapping exits -- taking every later test in
    %% this foreach group down with it. stop/1 shuts the server down
    %% synchronously without that problem.
    ok = gen_server:stop(Pid).

throttle_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun allows_up_to_the_configured_limit/0,
      fun rejects_once_the_limit_is_exceeded/0,
      fun a_rejected_call_still_counts_against_the_window/0,
      fun different_callers_have_independent_budgets/0,
      fun a_caller_with_no_identity_is_never_allowed/0]}.

allows_up_to_the_configured_limit() ->
    Caller = <<"caller-a">>,
    ?assertEqual(ok, throttle_pair_callers:allow(Caller)),
    ?assertEqual(ok, throttle_pair_callers:allow(Caller)),
    ?assertEqual(ok, throttle_pair_callers:allow(Caller)).

rejects_once_the_limit_is_exceeded() ->
    Caller = <<"caller-b">>,
    ok = throttle_pair_callers:allow(Caller),
    ok = throttle_pair_callers:allow(Caller),
    ok = throttle_pair_callers:allow(Caller),
    ?assertEqual({error, rate_limited}, throttle_pair_callers:allow(Caller)).

a_rejected_call_still_counts_against_the_window() ->
    Caller = <<"caller-c">>,
    ok = throttle_pair_callers:allow(Caller),
    ok = throttle_pair_callers:allow(Caller),
    ok = throttle_pair_callers:allow(Caller),
    %% Two rejected calls, neither of which should ever flip back to ok
    %% within the same window -- a fail-closed limiter never lets a
    %% retry buy more budget.
    ?assertEqual({error, rate_limited}, throttle_pair_callers:allow(Caller)),
    ?assertEqual({error, rate_limited}, throttle_pair_callers:allow(Caller)).

different_callers_have_independent_budgets() ->
    CallerA = <<"caller-d">>,
    CallerB = <<"caller-e">>,
    ok = throttle_pair_callers:allow(CallerA),
    ok = throttle_pair_callers:allow(CallerA),
    ok = throttle_pair_callers:allow(CallerA),
    ?assertEqual({error, rate_limited}, throttle_pair_callers:allow(CallerA)),
    %% CallerB's budget is untouched by CallerA's exhaustion.
    ?assertEqual(ok, throttle_pair_callers:allow(CallerB)).

a_caller_with_no_identity_is_never_allowed() ->
    %% `undefined' is what mcl_nvidia_pair_mesh_rpc passes when a
    %% call somehow reaches the handler with no wire-authenticated
    %% caller -- refuse outright rather than let every unidentified
    %% caller share one budget (or worse, bypass throttling entirely).
    ?assertEqual({error, rate_limited}, throttle_pair_callers:allow(undefined)).
