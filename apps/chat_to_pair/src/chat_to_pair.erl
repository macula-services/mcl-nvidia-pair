%%% @doc Forwards a realm-authorized chat request to a local NVIDIA PAIR
%%% cluster's own Ollama/OpenAI-compatible proxy over plain loopback
%%% HTTP.
%%%
%%% Deliberately narrow: this module implements exactly one operation
%%% (chat completion in, response out) and constructs the outbound
%%% request itself -- it never forwards an arbitrary path or method
%%% from a realm caller. PAIR's own cluster-internal proxy has no route
%%% filtering (any pinned LAN peer can reach /api/pull, /api/delete,
%%% engine-control, etc. -- see plans/DESIGN_FEASIBILITY_ASSESSMENT.md);
%%% that surface is never exposed here because this module never
%%% relays a caller-supplied path at all.
%%%
%%% Talks to PAIR over PLAIN loopback HTTP, the same "any agent, zero
%%% code changes" interface PAIR guarantees for every consumer -- no
%%% pairing, no mTLS, no PAIR-side changes. This only works because the
%%% bridge runs co-located with a PAIR cluster member: PAIR's own
%%% plaintext ingress refuses non-loopback callers by design.
%%%
%%% Config (app env, all under `chat_to_pair'):
%%%   pair_base_url -- default "http://127.0.0.1:11434"
%%%   pair_timeout_ms -- default 120000 (PAIR's own architecture doc
%%%     documents WAN-tolerant timeouts on its side; this just needs to
%%%     outlast a real cluster-routed generation, not a single machine)
-module(chat_to_pair).

-export([chat/2, chat/3, probe/0]).

-define(DEFAULT_BASE_URL, "http://127.0.0.1:11434").
-define(DEFAULT_TIMEOUT_MS, 120000).

-spec chat(binary(), list()) -> {ok, map()} | {error, term()}.
chat(Model, Messages) ->
    chat(Model, Messages, #{}).

-spec chat(binary(), list(), map()) -> {ok, map()} | {error, term()}.
chat(Model, Messages, Opts) when is_binary(Model), is_list(Messages) ->
    ensure_http_apps(),
    Body = jsx:encode(request_body(Model, Messages, Opts)),
    Url = base_url() ++ "/v1/chat/completions",
    Headers = [{"content-type", "application/json"}],
    case httpc:request(post, {Url, Headers, "application/json", Body},
                       [{timeout, timeout_ms()}], []) of
        {ok, {{_, 200, _}, _RespHeaders, RespBody}} ->
            parse_response(Model, list_to_binary(RespBody));
        {ok, {{_, Status, _}, _RespHeaders, RespBody}} ->
            {error, {pair_error, Status, list_to_binary(RespBody)}};
        {error, Reason} ->
            {error, {pair_unreachable, Reason}}
    end;
chat(_Model, _Messages, _Opts) ->
    {error, missing_model_or_messages}.

%% @doc Real reachability probe for mcl_nvidia_pair_service:health/0
%% -- not a stub. A GET against PAIR's own /v1/models is cheap (no
%% inference, no engine dispatch) and answers the only question this
%% needs to: is the configured PAIR backend actually there.
-spec probe() -> ok | {error, term()}.
probe() ->
    ensure_http_apps(),
    Url = base_url() ++ "/v1/models",
    case httpc:request(get, {Url, []}, [{timeout, timeout_ms()}], []) of
        {ok, {{_, 200, _}, _RespHeaders, _RespBody}} -> ok;
        {ok, {{_, Status, _}, _RespHeaders, _RespBody}} -> {error, {pair_error, Status}};
        {error, Reason} -> {error, {pair_unreachable, Reason}}
    end.

%%% Internal

base_url() ->
    application:get_env(chat_to_pair, pair_base_url, ?DEFAULT_BASE_URL).

timeout_ms() ->
    application:get_env(chat_to_pair, pair_timeout_ms, ?DEFAULT_TIMEOUT_MS).

ensure_http_apps() ->
    {ok, _} = application:ensure_all_started(inets),
    {ok, _} = application:ensure_all_started(ssl),
    ok.

request_body(Model, Messages, Opts) ->
    with_opts(#{<<"model">> => Model, <<"messages">> => Messages}, Opts).

with_opts(Base, Opts) ->
    lists:foldl(fun(Key, Acc) -> with_opt(Key, Opts, Acc) end, Base,
               [temperature, max_tokens]).

with_opt(Key, Opts, Acc) ->
    case maps:get(Key, Opts, undefined) of
        undefined -> Acc;
        Value     -> Acc#{atom_to_binary(Key, utf8) => Value}
    end.

%% PAIR's proxy is OpenAI-compatible: `choices[0].message.content'.
%% `model' in the response is PAIR's own (may differ from the request
%% if PAIR resolved an alias); RequestedModel is kept alongside it so a
%% caller can tell the two apart.
parse_response(RequestedModel, RespBody) ->
    try
        Decoded = jsx:decode(RespBody, [return_maps]),
        #{<<"choices">> := [#{<<"message">> := Message} = Choice | _]} = Decoded,
        Content = maps:get(<<"content">>, Message, <<>>),
        {ok, #{
            message          => Message,
            content          => Content,
            requested_model  => RequestedModel,
            model            => response_model(Decoded, RequestedModel),
            finish_reason    => maps:get(<<"finish_reason">>, Choice, undefined),
            usage            => maps:get(<<"usage">>, Decoded, undefined)
        }}
    catch
        _:_ -> {error, {invalid_pair_response, RespBody}}
    end.

response_model(#{<<"model">> := M}, _RequestedModel) when is_binary(M) -> M;
response_model(_Decoded, RequestedModel) -> RequestedModel.
