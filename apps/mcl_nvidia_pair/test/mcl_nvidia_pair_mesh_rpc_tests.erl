%% @doc The chat handler: what a realm caller's payload becomes, and what goes
%% back on the wire.
%%
%% `chat_to_pair' is mocked here; its own suite covers the HTTP side. What
%% this suite pins down is the translation both ways: a macula 12 payload
%% (atom or text keys, `{text, Bin}' values, the platform's `caller') into one
%% forwarded chat, and the result into a reply whose text is tagged, since a
%% bare binary reaches every non-BEAM caller as hex bytes.
-module(mcl_nvidia_pair_mesh_rpc_tests).

-include_lib("eunit/include/eunit.hrl").

-define(CALLER, <<7:256>>).

setup() ->
    application:set_env(throttle_pair_callers, max_per_window, 2),
    application:set_env(throttle_pair_callers, window_seconds, 3600),
    {ok, Throttle} = throttle_pair_callers:start_link(),
    ok = meck:new(chat_to_pair, [non_strict]),
    Throttle.

cleanup(Throttle) ->
    meck:unload(chat_to_pair),
    unlink(Throttle),
    exit(Throttle, shutdown),
    application:unset_env(throttle_pair_callers, max_per_window),
    application:unset_env(throttle_pair_callers, window_seconds).

payload(Extra) ->
    maps:merge(#{caller => ?CALLER,
                 model => {text, <<"llama3">>},
                 messages => [#{role => {text, <<"user">>},
                                content => {text, <<"hi">>}}]},
               Extra).

handler_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun forwards_one_chat_with_plain_terms/1,
      fun replies_with_tagged_text/1,
      fun refuses_a_payload_without_model_or_messages/1,
      fun refuses_a_map_without_a_caller/1,
      fun rate_limits_per_caller/1,
      fun a_pair_failure_is_a_flat_reason/1]}.

forwards_one_chat_with_plain_terms(_) ->
    ok = meck:expect(chat_to_pair, chat, fun(_, _, _) -> {ok, #{content => <<"yo">>}} end),
    _ = mcl_nvidia_pair_mesh_rpc:handle_request(payload(#{temperature => 0.5}), undefined),
    ?_assertEqual([{chat_to_pair, chat,
                    [<<"llama3">>,
                     [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
                     #{temperature => 0.5}]}],
                  [MFA || {_Pid, MFA, _Result} <- meck:history(chat_to_pair)]).

replies_with_tagged_text(_) ->
    ok = meck:expect(chat_to_pair, chat,
                     fun(_, _, _) ->
                         {ok, #{content => <<"yo">>, model => <<"llama3">>,
                                requested_model => <<"llama3">>,
                                message => #{<<"role">> => <<"assistant">>,
                                             <<"content">> => <<"yo">>},
                                finish_reason => <<"stop">>,
                                usage => #{<<"total_tokens">> => 12}}}
                     end),
    {reply, Reply, undefined} = mcl_nvidia_pair_mesh_rpc:handle_request(payload(#{}), undefined),
    [?_assertEqual({text, <<"yo">>}, maps:get(content, Reply)),
     ?_assertEqual({text, <<"assistant">>}, maps:get(<<"role">>, maps:get(message, Reply))),
     ?_assertEqual(12, maps:get(<<"total_tokens">>, maps:get(usage, Reply))),
     ?_assertEqual([], bare_binaries(Reply))].

refuses_a_payload_without_model_or_messages(_) ->
    [?_assertEqual({error, missing_model_or_messages, undefined},
                   mcl_nvidia_pair_mesh_rpc:handle_request(#{caller => ?CALLER}, undefined)),
     ?_assertEqual({error, missing_model_or_messages, undefined},
                   mcl_nvidia_pair_mesh_rpc:handle_request({text, <<"hello">>}, undefined))].

%% The platform merges the wire-authenticated `caller' into a map payload; a
%% map without one did not arrive over a station link, and cannot be counted
%% against anyone's quota.
refuses_a_map_without_a_caller(_) ->
    ?_assertEqual({error, missing_caller, undefined},
                  mcl_nvidia_pair_mesh_rpc:handle_request(maps:remove(caller, payload(#{})),
                                                          undefined)).

rate_limits_per_caller(_) ->
    ok = meck:expect(chat_to_pair, chat, fun(_, _, _) -> {ok, #{content => <<"yo">>}} end),
    Call = fun() -> mcl_nvidia_pair_mesh_rpc:handle_request(payload(#{}), undefined) end,
    _ = Call(),
    _ = Call(),
    ?_assertEqual({error, rate_limited, undefined}, Call()).

%% A reason crosses the wire, so it is an atom a non-BEAM caller can read,
%% not an Erlang tuple; PAIR's own status and body are logged here instead.
a_pair_failure_is_a_flat_reason(_) ->
    ok = meck:expect(chat_to_pair, chat,
                     fun(_, _, _) -> {error, {pair_error, 500, <<"boom">>}} end),
    ?_assertEqual({error, pair_error, undefined},
                  mcl_nvidia_pair_mesh_rpc:handle_request(payload(#{}), undefined)).

bare_binaries(Map) when is_map(Map) ->
    lists:append([bare_binaries(V) || V <- maps:values(Map)]);
bare_binaries(List) when is_list(List) ->
    lists:append([bare_binaries(V) || V <- List]);
bare_binaries(Bin) when is_binary(Bin) ->
    [Bin];
bare_binaries(_Other) ->
    [].
