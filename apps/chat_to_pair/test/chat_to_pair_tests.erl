-module(chat_to_pair_tests).

-include_lib("eunit/include/eunit.hrl").

setup() ->
    meck:new(httpc, [unstick, passthrough]),
    ok.

teardown(_) ->
    meck:unload(httpc).

chat_to_pair_test_() ->
    {foreach, fun setup/0, fun teardown/1,
     [fun missing_model_or_messages_never_calls_pair/0,
      fun a_successful_reply_is_parsed_from_pair_s_openai_shape/0,
      fun the_request_carries_model_and_messages/0,
      fun optional_opts_are_forwarded_when_present/0,
      fun a_non_200_from_pair_is_a_pair_error/0,
      fun an_unreachable_pair_is_reported_as_such/0,
      fun an_unparseable_body_is_an_invalid_response/0,
      fun probe_succeeds_on_a_200_from_v1_models/0,
      fun probe_reports_pair_unreachable/0]}.

missing_model_or_messages_never_calls_pair() ->
    meck:expect(httpc, request, fun(_, _, _, _) -> error(should_not_be_called) end),
    ?assertEqual({error, missing_model_or_messages}, chat_to_pair:chat(undefined, [])).

a_successful_reply_is_parsed_from_pair_s_openai_shape() ->
    mock_reply(200, jsx:encode(#{
        <<"choices">> => [#{
            <<"message">> => #{<<"role">> => <<"assistant">>, <<"content">> => <<"pong">>},
            <<"finish_reason">> => <<"stop">>
        }],
        <<"model">> => <<"openai/gpt-oss-20b">>,
        <<"usage">> => #{<<"prompt_tokens">> => 5, <<"completion_tokens">> => 1}
    })),
    {ok, Result} = chat_to_pair:chat(<<"openai/gpt-oss-20b">>,
                                     [#{<<"role">> => <<"user">>, <<"content">> => <<"ping">>}]),
    ?assertEqual(<<"pong">>, maps:get(content, Result)),
    ?assertEqual(<<"openai/gpt-oss-20b">>, maps:get(model, Result)),
    ?assertEqual(<<"openai/gpt-oss-20b">>, maps:get(requested_model, Result)),
    ?assertEqual(<<"stop">>, maps:get(finish_reason, Result)),
    ?assertEqual(#{<<"prompt_tokens">> => 5, <<"completion_tokens">> => 1}, maps:get(usage, Result)).

the_request_carries_model_and_messages() ->
    mock_reply(200, jsx:encode(#{<<"choices">> => [#{<<"message">> => #{<<"content">> => <<"ok">>}}]})),
    Messages = [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>}],
    {ok, _} = chat_to_pair:chat(<<"m1">>, Messages),
    [{_, {httpc, request, [post, {_Url, _Headers, _CT, Body}, _, _]}, _}] =
        meck:history(httpc),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(<<"m1">>, maps:get(<<"model">>, Decoded)),
    ?assertEqual(Messages, maps:get(<<"messages">>, Decoded)).

optional_opts_are_forwarded_when_present() ->
    mock_reply(200, jsx:encode(#{<<"choices">> => [#{<<"message">> => #{<<"content">> => <<"ok">>}}]})),
    {ok, _} = chat_to_pair:chat(<<"m1">>, [], #{temperature => 0.2, max_tokens => 64}),
    [{_, {httpc, request, [post, {_Url, _Headers, _CT, Body}, _, _]}, _}] =
        meck:history(httpc),
    Decoded = jsx:decode(Body, [return_maps]),
    ?assertEqual(0.2, maps:get(<<"temperature">>, Decoded)),
    ?assertEqual(64, maps:get(<<"max_tokens">>, Decoded)).

a_non_200_from_pair_is_a_pair_error() ->
    mock_reply(503, <<"{\"error\":\"no local backend\"}">>),
    ?assertEqual({error, {pair_error, 503, <<"{\"error\":\"no local backend\"}">>}},
                 chat_to_pair:chat(<<"m1">>, [])).

an_unreachable_pair_is_reported_as_such() ->
    meck:expect(httpc, request, fun(_, _, _, _) -> {error, econnrefused} end),
    ?assertEqual({error, {pair_unreachable, econnrefused}}, chat_to_pair:chat(<<"m1">>, [])).

an_unparseable_body_is_an_invalid_response() ->
    mock_reply(200, <<"not json">>),
    ?assertMatch({error, {invalid_pair_response, _}}, chat_to_pair:chat(<<"m1">>, [])).

probe_succeeds_on_a_200_from_v1_models() ->
    meck:expect(httpc, request, fun(get, {Url, _}, _, _) ->
        ?assert(lists:suffix("/v1/models", Url)),
        {ok, {{"HTTP/1.1", 200, "OK"}, [], "{}"}}
    end),
    ?assertEqual(ok, chat_to_pair:probe()).

probe_reports_pair_unreachable() ->
    meck:expect(httpc, request, fun(get, _, _, _) -> {error, timeout} end),
    ?assertEqual({error, {pair_unreachable, timeout}}, chat_to_pair:probe()).

%%% Helpers

mock_reply(Status, Body) ->
    meck:expect(httpc, request, fun(post, _Req, _HttpOpts, _Opts) ->
        {ok, {{"HTTP/1.1", Status, reason(Status)}, [], binary_to_list(Body)}}
    end).

reason(200) -> "OK";
reason(_)   -> "Error".
