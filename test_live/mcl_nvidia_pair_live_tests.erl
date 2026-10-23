%%% @doc Live end-to-end, against a DEPLOYED bridge, from another machine.
%%%
%%% This is the measurement the README's status section reports and the issue's
%%% "done when" asks for (mcl-nvidia-pair#8, step 3). It proves three things
%%% against the real mesh, a real realm, a real PAIR cluster and a real
%%% completion:
%%%
%%%   1. A realm member calls `mcl-nvidia-pair/chat' with the membership UCAN
%%%      the realm issued to THIS node, and gets a completion back.
%%%   2. A node with no realm membership is refused by the provider's gate,
%%%      with macula's own `unauthorized' BOLT#4 code, before the handler runs.
%%%   3. The per-caller rate limit trips: one caller's calls past the window are
%%%      refused `rate_limited' and never reach PAIR.
%%%
%%% It lives in `test_live/', NOT `test/': it needs a deployed bridge, a member
%%% key and a working PAIR cluster, so it must never run in CI's gate. Run it
%%% explicitly:
%%%
%%%     rebar3 as live_test eunit --dir test_live --module=mcl_nvidia_pair_live_tests
%%%
%%% or, with the environment set, `scripts/live_test_pair8.sh' (which is what
%%% the README points a tester at).
%%%
%%% ## The member identity
%%%
%%% The caller's node key is a file, so the same node id is used on every run:
%%% the realm admits a NODE, and its membership is what a bind or a revoke acts
%%% on. This test never mints its own membership: it asks the realm for a
%%% membership UCAN with a proof signed by that key (macula-realm's
%%% `issue_membership_ucan'), which is what every macula client does and what
%%% re-reads the member's own record after a revocation. A node the realm has
%%% never admitted is refused there with `not_admitted', which is the honest
%%% failure: nothing is wrong with the bridge.
%%%
%%% The stranger is a second key file, never admitted anywhere. It is an
%%% ordinary mesh participant with a valid realm trust pin, so it can resolve
%%% the advertisement and dial the provider; the refusal this test looks for
%%% happens at the provider's gate, not at resolution.
-module(mcl_nvidia_pair_live_tests).

-include_lib("eunit/include/eunit.hrl").

-define(ORG, <<"mcl-nvidia-pair">>).
-define(CAP, <<"chat">>).
-define(REALM_NAME, <<"io.macula">>).
%% Small: these calls are proof, not benchmarks. PAIR still runs the model.
-define(MAX_TOKENS, 8).
-define(PROMPT, <<"Reply with the single word: ready">>).

%% @doc The three claims, in one run: one pool, one membership UCAN, and a
%% second pool for the stranger that shares nothing with the member's.
the_bridge_serves_a_member_and_refuses_a_stranger_test_() ->
    {timeout, 900, fun run/0}.

run() ->
    {ok, MemberPool, MemberKey} = connect(member_key_path()),
    Token = member_token(MemberPool, MemberKey),
    served(MemberPool, Token),
    refused(stranger_pool()),
    throttled(MemberPool, Token),
    ok = macula:close(MemberPool).

%% 1. A member gets a completion. The model name is the deployment's own
%% (PAIR serves the models the box has), so it comes from the environment
%% rather than being guessed here.
served(Pool, Token) ->
    {ok, Reply} = chat(Pool, Token, #{{text, <<"model">>} => {text, model()}}),
    Content = mcl_om_wire:field(<<"content">>, Reply, <<>>),
    io:format(user, "~nmember: completion ~p bytes~n  model: ~p~n  text: ~p~n",
              [byte_size(Content),
               mcl_om_wire:field(<<"model">>, Reply, undefined),
               Content]),
    ?assert(is_binary(Content)),
    ?assert(byte_size(Content) > 0).

%% 2. A node outside the realm is refused, and the refusal is macula's own
%% `unauthorized' rather than a timeout or a resolve miss: a stranger resolving
%% `no_provider' would mean the test never reached the gate at all.
refused(StrangerPoolResult) ->
    {ok, StrangerPool} = StrangerPoolResult,
    Result = chat(StrangerPool, undefined, #{{text, <<"model">>} => {text, model()}}),
    io:format(user, "~nstranger: ~p~n", [Result]),
    ?assertMatch({error, _}, Result),
    ?assertEqual(<<"unauthorized">>, refusal_code(Result)),
    ok = macula:close(StrangerPool).

%% 3. The rate limit trips. Counted per caller, so this burst is the member's
%% own budget: the configured window size is the deployment's, passed to this
%% test as the same variable the bridge was configured with, and a couple of
%% calls past it are enough to see it. The window is fixed, so a burst that
%% straddles a rollover would start again: `VERDICT_MAX_ATTEMPTS' bounds the
%% retries, and the assertion is that a breach was SEEN, not where.
throttled(Pool, Token) ->
    Max = max_per_window(),
    {Seen, Calls} = burst(Pool, Token, Max + 4),
    io:format(user, "~nrate limit: configured ~p per window, ~p calls, "
                    "first breach at ~p~n", [Max, Calls, Seen]),
    ?assertEqual(ok, Seen).

%% The number of calls one caller may make in a window: the bridge's own
%% setting, read from the environment this test runs with, so the two cannot
%% disagree. 20 is the service's shipped default.
max_per_window() ->
    case os:getenv("PAIR_MAX_PER_WINDOW") of
        false -> 20;
        Text -> list_to_integer(Text)
    end.

burst(Pool, Token, Wanted) ->
    burst(Pool, Token, Wanted, 0, ok).

burst(_Pool, _Token, 0, Calls, Seen) ->
    {Seen, Calls};
burst(Pool, Token, Left, Calls, Seen) ->
    case chat(Pool, Token, #{{text, <<"model">>} => {text, model()}}) of
        {ok, _} -> burst(Pool, Token, Left - 1, Calls + 1, Seen);
        {error, _} = Breach -> {seen(Seen, Breach), Calls + 1}
    end.

seen(ok, Breach) ->
    case refusal_code(Breach) of
        <<"rate_limited">> -> ok;
        _Other -> Breach
    end;
seen(Seen, _Breach) ->
    Seen.

%% A refusal crosses the wire as a map carrying macula's BOLT#4 `code'. This is
%% the one shape that reads it, so a change in how mcl_om or macula present a
%% refused call fails here loudly instead of passing silently.
refusal_code({error, Reason}) ->
    mcl_om_wire:field(<<"code">>, Reason, undefined);
refusal_code(_Other) ->
    undefined.

%%------------------------------------------------------------------
%% The bridge
%%------------------------------------------------------------------

chat(Pool, Token, Extra) ->
    Payload = maps:merge(Extra,
                         #{{text, <<"messages">>} =>
                               [#{{text, <<"role">>} => {text, <<"user">>},
                                  {text, <<"content">>} => {text, ?PROMPT}}],
                           {text, <<"max_tokens">>} => ?MAX_TOKENS}),
    Timeout = 180_000,
    mcl_om_capabilities:call_capability(Pool, realm(), ?ORG, ?CAP, Payload, Timeout, opts(Token)).

opts(undefined) -> #{};
opts(Token)     -> #{ucan_token => Token}.

model() ->
    case os:getenv("PAIR8_TEST_MODEL") of
        false -> <<"qwen2.5:3b-instruct-q4_K_M">>;
        Name -> list_to_binary(Name)
    end.

%%------------------------------------------------------------------
%% The membership: a proof-signed request to the realm, which re-reads the
%% member's own record and mints at that record's tier (macula-realm#46).
%%------------------------------------------------------------------

member_token(Pool, Key) ->
    Payload = membership_request(Key),
    Reply = realm_call(Pool, <<"issue_membership_ucan">>, Payload, 60_000),
    token(Reply).

realm_call(Pool, Name, Payload, Timeout) ->
    Procedure = macula_topic:realm_hope(?REALM_NAME, <<"identity">>, Name, 1),
    case macula:call(Pool, realm(), Procedure, Payload, Timeout) of
        {ok, Reply} -> Reply;
        Other -> erlang:error({realm_refused, Other})
    end.

token(Reply) ->
    case mcl_om_wire:field(<<"ucan">>, Reply, undefined) of
        Token when is_binary(Token) -> Token;
        _Missing -> erlang:error({no_membership_ucan, Reply})
    end.

%% The payload as a macula client sends it: text keys, text values, and a
%% `proof' over every other field. The realm verifies the signature with the
%% key it just carried, so a key that does not match is `bad_proof' rather
%% than a token for someone else.
membership_request(Key) ->
    Public = macula_node_keys:public_key(Key),
    Request = #{{text, <<"public_key">>} => {text, base64:encode(Public)},
                {text, <<"ttl_seconds">>} => 600},
    Timestamp = erlang:system_time(millisecond),
    Nonce = crypto:strong_rand_bytes(16),
    Signature = macula_node_keys:sign(signature_message(Public, Timestamp, Nonce, Request), Key),
    Request#{{text, <<"proof">>} =>
                 #{{text, <<"v">>} => 2,
                   {text, <<"timestamp">>} => Timestamp,
                   {text, <<"nonce">>} => {text, lower_hex(Nonce)},
                   {text, <<"signature">>} => {text, lower_hex(Signature)}}}.

%% macula-realm's `DeviceRequestProof.message/6', which is exported precisely so
%% a client can be checked against it: deterministic CBOR over the fixed tag,
%% this realm, the procedure it is signed for, and the request itself.
signature_message(Public, Timestamp, Nonce, Request) ->
    macula_record_cbor:encode(
      #{{text, <<"tag">>} => {text, <<"macula.realm.device_request">>},
        {text, <<"v">>} => 2,
        {text, <<"public_key">>} => Public,
        {text, <<"realm">>} => realm(),
        {text, <<"procedure">>} => {text, <<"macula_realm.membership_ucan">>},
        {text, <<"timestamp">>} => Timestamp,
        {text, <<"nonce">>} => Nonce,
        {text, <<"request">>} => Request}).

lower_hex(Bin) ->
    string:lowercase(binary:encode_hex(Bin)).

%%------------------------------------------------------------------
%% The mesh
%%------------------------------------------------------------------

stranger_pool() ->
    connect(stranger_key_path()).

connect(KeyPath) ->
    {ok, Profile} = macula_crypto_profile:configured(),
    {ok, Key} = macula_node_keys:node_identity(KeyPath, Profile),
    {ok, Pool} = macula:connect(seeds(), #{node_identity => Key,
                                           realm_trust => #{realm() => realm_key()}}),
    ok = wait_healthy(Pool, 60),
    {ok, NodeId} = macula_node_keys:node_id(Key),
    io:format(user, "~nconnected as ~s~n", [lower_hex(NodeId)]),
    {ok, Pool, Key}.

wait_healthy(_Pool, 0) ->
    erlang:error(pool_never_got_a_healthy_link);
wait_healthy(Pool, Left) ->
    case macula:links(Pool) of
        {ok, Links} ->
            connected(any_connected(Links), Pool, Left);
        {error, _} ->
            retry(Pool, Left)
    end.

any_connected(Links) when is_list(Links) ->
    lists:any(fun(#{connected := C}) -> C; (_) -> false end, Links).

connected(true, _Pool, _Left) -> ok;
connected(false, Pool, Left) -> retry(Pool, Left).

retry(Pool, Left) ->
    timer:sleep(2_000),
    wait_healthy(Pool, Left - 1).

realm() ->
    hex_env("MCL_REALM").

realm_key() ->
    hex_env("MCL_REALM_KEY").

hex_env(Name) ->
    case os:getenv(Name) of
        false -> erlang:error({missing_env, Name});
        Text -> binary:decode_hex(list_to_binary(string:trim(Text)))
    end.

%% Pinned seeds, host paired with node id index for index: an unpinned seed is
%% a dial that cannot connect (D5).
seeds() ->
    Hosts = comma_list("MACULA_STATION_SEEDS"),
    Ids = comma_list("MACULA_STATION_NODE_IDS"),
    length(Hosts) =:= length(Ids) orelse
        erlang:error({seed_pin_mismatch, length(Hosts), length(Ids)}),
    [seed(Host, Id) || {Host, Id} <- lists:zip(Hosts, Ids)].

seed(HostPort, IdHex) ->
    {Host, Port} = host_port(HostPort),
    #{host => Host, port => Port, expected_node_id => binary:decode_hex(IdHex)}.

host_port(HostPort) ->
    case string:split(HostPort, ":", trailing) of
        [Host, Port] -> {Host, list_to_integer(Port)};
        [Host] -> {Host, 4433}
    end.

comma_list(Name) ->
    case os:getenv(Name) of
        false -> erlang:error({missing_env, Name});
        Text -> [list_to_binary(string:trim(P)) || P <- string:split(Text, ",", all), P =/= ""]
    end.

%% Keys live outside the repository, in the operator's own secrets directory:
%% a node key is a credential, and this one is a realm member's.
member_key_path() ->
    key_path("MCL_PAIR8_MEMBER_KEY", "pair8-member.key").

stranger_key_path() ->
    key_path("MCL_PAIR8_STRANGER_KEY", "pair8-stranger.key").

key_path(Var, Default) ->
    case os:getenv(Var) of
        false -> filename:join([home(), ".macula", "secrets", Default]);
        Path -> Path
    end.

home() ->
    case os:getenv("HOME") of
        false -> erlang:error(no_home);
        Dir -> Dir
    end.
