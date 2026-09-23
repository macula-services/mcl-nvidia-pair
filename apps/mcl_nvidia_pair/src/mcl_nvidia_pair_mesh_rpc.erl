%% @doc The per-call handler for `mcl-nvidia-pair/chat'.
%%
%% Advertised through the standard `mcl_om_capabilities' path as `Org/chat',
%% gated by `{realm_member_required, RealmKeyId, RequiredCan}' (see
%% `mcl_nvidia_pair_service:capabilities/0'): macula checks a realm-issued
%% member UCAN before a call ever reaches `handle_request/2', so no token is
%% parsed or verified here.
%%
%% One operation end to end: a chat completion in, a response out. The
%% outbound request is built by `chat_to_pair', never relayed from a caller's
%% path, so PAIR's own cluster-internal admin surface is never reachable from
%% the realm.
%%
%% THE PLATFORM GIVES THIS PROCEDURE NO BACKPRESSURE. `macula_station_link'
%% has no inbound rate limit at any layer, and this forwards onto someone's
%% own household hardware, so every call is counted per caller by
%% `throttle_pair_callers' before it reaches PAIR.
-module(mcl_nvidia_pair_mesh_rpc).
-behaviour(macula_response).

-export([init/1, handle_request/2]).

%% @doc `macula_response' callback. No per-call state: the limiter keeps its
%% own table, since `macula_response' runs each call in a fresh process.
init([]) -> {ok, undefined}.

%% @doc `macula_response' callback: forward one chat to PAIR, reply with the
%% result, text tagged.
-spec handle_request(term(), undefined) ->
    {reply, map(), undefined} | {error, atom(), undefined}.
handle_request(Payload, State) when is_map(Payload) ->
    answer(serve(wire_in(Payload)), State);
handle_request(_NotAMap, State) ->
    answer({error, missing_model_or_messages}, State).

answer({ok, Result}, State)     -> {reply, to_wire(Result), State};
answer({error, Reason}, State) -> {error, flat_reason(Reason), State}.

%% Every payload is folded to one shape before a clause looks at it: macula's
%% frame decoder atomizes keys it already knows and wraps text values as
%% `{text, Bin}'.
serve(#{<<"model">> := Model, <<"messages">> := Messages} = P)
  when is_binary(Model), is_list(Messages) ->
    %% `caller' is merged into a map payload by `macula_station_link' before
    %% this handler runs: wire-authenticated, and it overwrites anything the
    %% caller put under the same key. It is the only correct key for a
    %% per-caller quota.
    dispatch(maps:get(<<"caller">>, P, undefined), Model, Messages, P);
serve(_P) ->
    {error, missing_model_or_messages}.

dispatch(undefined, _Model, _Messages, _P) ->
    {error, missing_caller};
dispatch(Caller, Model, Messages, P) ->
    forward(throttle_pair_callers:allow(Caller), Model, Messages, P).

forward(ok, Model, Messages, P)   -> chat_to_pair:chat(Model, Messages, chat_opts(P));
forward({error, _} = Denied, _, _, _) -> Denied.

chat_opts(P) ->
    maps:from_list([{Key, V} || Key <- [temperature, max_tokens],
                                V <- [maps:get(atom_to_binary(Key), P, undefined)],
                                V =/= undefined]).

%% A reason crosses the wire, so it is one atom a caller in any language can
%% read. The detail behind it stays in this node's log.
flat_reason(Reason) when is_atom(Reason) ->
    Reason;
flat_reason(Reason) when is_tuple(Reason), is_atom(element(1, Reason)) ->
    logger:warning("mcl_nvidia_pair_mesh_rpc: chat failed: ~p", [Reason]),
    element(1, Reason);
flat_reason(Reason) ->
    logger:warning("mcl_nvidia_pair_mesh_rpc: chat failed: ~p", [Reason]),
    chat_failed.

%%% Wire in: one shape, binary keys, plain values.

wire_in(Map) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) -> Acc#{wire_key(K) => wire_in(V)} end, #{}, Map);
wire_in(List) when is_list(List) ->
    [wire_in(V) || V <- List];
wire_in(Value) ->
    mcl_om_wire:unwrap(Value).

wire_key({text, Bin}) when is_binary(Bin) -> Bin;
wire_key(Atom) when is_atom(Atom)          -> atom_to_binary(Atom);
wire_key(Other)                            -> Other.

%%% Wire out: every binary in a chat reply is text (content, role, model
%%% names), and a bare binary reaches a non-BEAM caller as hex bytes. Fields
%%% PAIR left out are dropped rather than sent as the atom `undefined'.

to_wire(Map) when is_map(Map) ->
    maps:from_list([{K, to_wire(V)} || {K, V} <- maps:to_list(Map), V =/= undefined]);
to_wire(List) when is_list(List) ->
    [to_wire(V) || V <- List];
to_wire(Bin) when is_binary(Bin) ->
    {text, Bin};
to_wire(Other) ->
    Other.
