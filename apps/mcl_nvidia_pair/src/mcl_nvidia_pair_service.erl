%% @doc The mcl_om service contract: what this service is and may do.
%%
%% SIX CALLBACKS, ALL REQUIRED. mcl_om resolves them BY NAME at startup, on a
%% live node, so a service that forgets one dies with `undef' where nobody is
%% watching. The `-behaviour' attribute below is what turns that into a compile
%% error instead, and the generated test suite guards the attribute itself.
%%
%% ONE CAPABILITY, `Org/chat', and never open. It forwards a realm member's
%% chat request to the PAIR cluster this node sits beside (see
%% `mcl_nvidia_pair_mesh_rpc'). Serving it is authorised by the realm's D25
%% grant for this node, which /health reports; identity_spec/0 claims nothing,
%% because nothing consults it. Tests pin both lists, so changing either is a
%% deliberate act rather than a comment someone forgot.
-module(mcl_nvidia_pair_service).

-behaviour(mcl_om_service).

-export([info/0, start/1, stop/1, health/0, capabilities/0, identity_spec/0]).

info() ->
    #{name => <<"mcl-nvidia-pair">>,
      version => <<"0.1.0">>,
      description => <<"Realm-scoped bridge from a Macula realm to a local NVIDIA PAIR cluster">>}.

start(_Opts) -> mcl_nvidia_pair_sup:start_link().

stop(_State) -> ok.

%% Green once the supervision tree is up. Replace this with a real probe of
%% whatever this service needs in order to do its job. A dark mesh is usually NOT
%% a health failure: decide that deliberately rather than by default.
%% Whether the configured PAIR backend answers, not whether this process is
%% alive. mcl_om adds the D25 grant for `Org/chat' to this on /health.
%% Not configured to serve is reported, not hidden: a bridge nobody can reach
%% is not healthy just because PAIR answers.
health() ->
    health_of(capabilities(), chat_to_pair:probe()).

health_of([], _Probe)            -> {degraded, not_configured_to_serve};
health_of(_Caps, ok)              -> ok;
health_of(_Caps, {error, Reason}) -> {degraded, Reason}.

%% WHAT THIS SERVICE ANNOUNCES IT CAN DO. Other services find this one by these
%% names, so each entry is a promise that something answers.
%% `Org/chat', gated on realm membership: macula admits a call only with a
%% member UCAN signed by the realm's key, named here by that key's id. The id
%% is derived from the `realm_key' mcl_om already pins for this realm, so the
%% gate and the trust anchor cannot name two different realms. With no realm
%% key there is nothing to gate on, and nothing is announced: this procedure
%% forwards onto someone's own hardware and is never served open. Nor without
%% a real org: the wire name is `Org/chat', the realm's grant names the org, and
%% mcl_om's `_' placeholder is not one.
capabilities() ->
    chat_capability(application:get_env(mcl_om, realm_key),
                    real_org(application:get_env(mcl_om, org))).

real_org({ok, Org}) when is_binary(Org) ->
    match =:= re:run(Org, <<"^[a-z0-9][a-z0-9._-]*$">>, [{capture, none}]);
real_org(_Unset) ->
    false.

chat_capability({ok, KeyHex}, true) when is_binary(KeyHex), KeyHex =/= <<>> ->
    [#{name => <<"chat">>,
       version => 1,
       handler => {mcl_nvidia_pair_mesh_rpc, []},
       auth => {realm_member_required, realm_key_id(KeyHex), required_can()}}];
chat_capability(_KeyUnset, _OrgNotReal) ->
    [].

realm_key_id(KeyHex) ->
    {ok, Profile} = macula_crypto_profile:configured(),
    macula_node_keys:key_id(binary:decode_hex(KeyHex), Profile).

%% The tier a member token must carry. `member/email-verified' is what
%% macula-realm grants by default, closer to its human-confirmed citizen tier
%% than to a bare device key: this bridge forwards onto household hardware.
required_can() ->
    application:get_env(mcl_nvidia_pair, required_can, <<"member/email-verified">>).

%% THE AUTHORITY THIS SERVICE ASKS THE REALM FOR, and deliberately nothing more.
%% Ask for exactly the topics you publish and subscribe to. Popped, an attacker
%% gains precisely this and no more, which is the whole point of listing it.
%%
%% The scope is claimed now because it is the namespace every later resource
%% hangs under, and a scope costs nothing while a rename costs every deployed
%% peer.
identity_spec() ->
    #{scope => <<"mcl-nvidia-pair">>,
      actions => [],
      resources => [],
      ttl_days => 30}.
