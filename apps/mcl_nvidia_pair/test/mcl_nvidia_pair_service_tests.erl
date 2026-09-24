%% @doc The service contract, asserted locally.
%%
%% mcl_om resolves its six callbacks BY NAME at startup, on a live node, so a
%% service that forgets one dies with `undef' where nobody is watching. The
%% primary defence is the `-behaviour(mcl_om_service)' attribute on the
%% service module, which turns a missing callback into a compile error under
%% warnings_as_errors.
%%
%% What this suite adds is everything the compiler cannot see: that the attribute
%% has not been quietly dropped, that the values inside those callbacks are the
%% shapes mcl_om will destructure, and that the names and version this service
%% reports are the ones it actually has. Nothing local boots mcl_om, so
%% asserting the shape by hand is the closest available thing to a rehearsal.
-module(mcl_nvidia_pair_service_tests).

-include_lib("eunit/include/eunit.hrl").

-define(APP, mcl_nvidia_pair).
-define(SERVICE, mcl_nvidia_pair_service).

%% Belt and braces with the behaviour attribute, and it survives the attribute
%% being removed. If mcl_om ever adds a SEVENTH required callback this test
%% keeps passing and the deploy still breaks, which is the honest limit of a
%% local assertion about a remote contract.
exports_every_required_callback_test() ->
    _ = code:ensure_loaded(?SERVICE),
    Required = [{info, 0}, {start, 1}, {stop, 1},
                {health, 0}, {capabilities, 0}, {identity_spec, 0}],
    Missing = [F || {N, A} = F <- Required,
                    not erlang:function_exported(?SERVICE, N, A)],
    ?assertEqual([], Missing).

info_carries_the_three_keys_test() ->
    #{name := Name, version := Vsn, description := Desc} = ?SERVICE:info(),
    ?assert(is_binary(Name)),
    ?assert(is_binary(Vsn)),
    ?assert(is_binary(Desc)),
    ?assertEqual(<<"mcl-nvidia-pair">>, Name).

%% THE TWO NAMES MUST AGREE. The OTP application is snake_case because it is an
%% Erlang atom; the repository, the container image and the name this service
%% answers to on the mesh are kebab-case. They describe one service, so a
%% scaffold generated with a mismatched pair is caught here on the first eunit
%% run rather than by a puzzled reader months later.
mesh_name_matches_the_application_test() ->
    #{name := Wire} = ?SERVICE:info(),
    Snake = atom_to_binary(?APP, utf8),
    ?assertEqual(binary:replace(Snake, <<"_">>, <<"-">>, [global]), Wire).

%% The version in info/0 is what a peer reads off /health, so it disagreeing with
%% the application it describes is a lie that nothing else would catch.
info_version_matches_the_application_test() ->
    _ = application:load(?APP),
    {ok, Vsn} = application:get_key(?APP, vsn),
    #{version := Reported} = ?SERVICE:info(),
    ?assertEqual(list_to_binary(Vsn), Reported).

%% Health is whether the configured PAIR backend answers, not whether this
%% process is alive: a bridge to nothing is not healthy.
health_follows_the_pair_probe_test_() ->
    {foreach,
     fun() ->
         _ = realm_key_configured(),
         ok = meck:new(chat_to_pair, [passthrough])
     end,
     fun(_) -> meck:unload(chat_to_pair), unconfigure(undefined) end,
     [fun() ->
          ok = meck:expect(chat_to_pair, probe, fun() -> ok end),
          ?assertEqual(ok, ?SERVICE:health())
      end,
      fun() ->
          ok = meck:expect(chat_to_pair, probe, fun() -> {error, {pair_unreachable, econnrefused}} end),
          ?assertEqual({degraded, {pair_unreachable, econnrefused}}, ?SERVICE:health())
      end]}.

%% One procedure, `Org/chat', and never open: macula admits a call only with a
%% member UCAN the realm signed. The realm is named by its signing key's id,
%% derived from the same `realm_key' mcl_om already pins, so the two cannot
%% name different realms.
announces_chat_gated_on_realm_membership_test_() ->
    {setup, fun realm_key_configured/0, fun unconfigure/1,
     fun(KeyId) ->
        [?_assertEqual([#{name => <<"chat">>,
                          version => 1,
                          handler => {mcl_nvidia_pair_mesh_rpc, []},
                          auth => {realm_member_required, KeyId, <<"member/email-verified">>}}],
                       ?SERVICE:capabilities())]
     end}.

%% `member/email-verified' is what macula-realm puts in a member token by
%% default; a deployment that wants another tier says so explicitly.
required_can_is_configurable_test_() ->
    {setup,
     fun() ->
         KeyId = realm_key_configured(),
         application:set_env(mcl_nvidia_pair, required_can, <<"member/device">>),
         KeyId
     end,
     fun(K) -> application:unset_env(mcl_nvidia_pair, required_can), unconfigure(K) end,
     fun(KeyId) ->
        [?_assertMatch([#{auth := {realm_member_required, KeyId, <<"member/device">>}}],
                       ?SERVICE:capabilities())]
     end}.

%% With no realm key there is nothing to gate on, and the answer is to serve
%% nobody, never to fall back to an open procedure.
announces_nothing_without_a_realm_key_test() ->
    application:set_env(mcl_om, org, <<"mcl-nvidia-pair">>),
    application:unset_env(mcl_om, realm_key),
    ?assertEqual([], ?SERVICE:capabilities()),
    application:unset_env(mcl_om, org).

%% The wire name is `Org/chat' and the realm's grant names the org, so an
%% unset org (mcl_om's `_' placeholder) or a malformed one announces nothing.
announces_nothing_without_a_real_org_test_() ->
    {setup, fun realm_key_configured/0, fun unconfigure/1,
     fun(_KeyId) ->
        [fun() ->
             application:set_env(mcl_om, org, Org),
             ?assertEqual([], ?SERVICE:capabilities())
         end || Org <- [<<"_">>, <<"Not An Org">>, <<>>]]
     end}.

%% Not configured to serve is not healthy: a bridge nobody can reach reports
%% it on /health rather than going quietly dark.
unconfigured_is_degraded_test() ->
    ok = meck:new(chat_to_pair, [passthrough]),
    ok = meck:expect(chat_to_pair, probe, fun() -> ok end),
    application:unset_env(mcl_om, realm_key),
    Health = ?SERVICE:health(),
    meck:unload(chat_to_pair),
    ?assertEqual({degraded, not_configured_to_serve}, Health).

realm_key_configured() ->
    application:load(macula),
    application:set_env(macula, crypto_profile, pq_hybrid),
    {ok, Key} = macula_node_keys:generate(realm, pq_hybrid),
    Public = macula_node_keys:public_key(Key),
    application:set_env(mcl_om, realm_key, binary:encode_hex(Public, lowercase)),
    application:set_env(mcl_om, org, <<"mcl-nvidia-pair">>),
    macula_node_keys:key_id(Public, pq_hybrid).

unconfigure(_KeyId) ->
    application:unset_env(mcl_om, realm_key),
    application:unset_env(mcl_om, org).

identity_spec_has_the_shape_mcl_om_expects_test() ->
    #{scope := Scope, actions := Actions,
      resources := Resources, ttl_days := Ttl} = ?SERVICE:identity_spec(),
    ?assert(is_binary(Scope)),
    ?assert(is_list(Actions)),
    ?assert(is_list(Resources)),
    ?assert(is_integer(Ttl) andalso Ttl > 0).

%% Serving `Org/chat' is authorised by the realm's D25 grant for this node,
%% which /health reports under `provider_grants'; identity_spec/0's actions and
%% resources are not consulted by mcl_om. So it claims nothing, as mcl-echo's
%% does, rather than listing an authority nothing checks.
identity_spec_claims_nothing_test() ->
    #{actions := Actions, resources := Resources} = ?SERVICE:identity_spec(),
    ?assertEqual([], Actions),
    ?assertEqual([], Resources).

%% The supervisor starts and stops cleanly on its own, without mcl_om. It has
%% no children as generated; this asserts the tree is startable, not that it does
%% any work.
supervisor_starts_and_stops_test() ->
    {ok, Pid} = mcl_nvidia_pair_sup:start_link(),
    ?assert(is_process_alive(Pid)),
    ?assertEqual([], supervisor:which_children(Pid)),
    unlink(Pid),
    exit(Pid, shutdown).

%%==============================================================================
%% The runtime is pinned in two places, and neither is the one you are running
%%==============================================================================

%% ⚠ THIS GUARD EXISTS BECAUSE A SIBLING SERVICE DID NOT HAVE IT, AND IT COST
%% THREE COMMITS AND AN IMAGE THAT SHIPPED ANYWAY.
%%
%% Its `Containerfile' said 27 while development ran on 28. So `rebar3 eunit'
%% passing locally meant "passing on 28" and nothing more, CI failed on a crash
%% that does not occur on 28 at all, and because the image build is a separate
%% workflow the image went to the fleet regardless.
%%
%% The release is pinned in TWO files, and the version actually running is a
%% third thing that agrees with neither by default. **A comment in each file
%% saying they must match is not a mechanism**, and both files carried one.
%%
%% ⚠⚠ IT FAILS RATHER THAN WARNS WHEN YOUR VM DIFFERS, AND THAT IS DELIBERATE.
%% Developing on a release you do not ship makes a green suite mean less than it
%% appears to. If you want to work on another release, move both pins and find
%% out what breaks, which is the whole point of having them.
%%
%% ⚠ TO THE PATCH, AND NOTHING FLOATS. This compared majors only, so when Docker
%% Hub moved the floating `erlang:28-alpine' on 2026-09-22 a service generated
%% from this template shipped OTP 28.5 and its guard stayed green. It compares
%% the full release now: the builder's (which must also carry a digest, so a
%% re-pushed tag cannot change what builds), lint's image and the release its
%% toolchain step insists on, .tool-versions, and this VM.
the_runtime_agrees_between_the_image_the_ci_and_this_vm_test() ->
    %% The team images' tags name a date, not a release, so the builder and
    %% lint each assert the release in a check step; this compares those, the
    %% .tool-versions pin and this VM, to the patch.
    Check = "\\{<<\"([0-9]+\\.[0-9]+\\.[0-9]+)\">>, true\\} -> halt\\(0\\);",
    Image = pinned("Containerfile", Check),
    CiCheck = pinned(".github/workflows/lint.yml", Check),
    Tools = pinned(".tool-versions", "^erlang ([0-9]+\\.[0-9]+\\.[0-9]+)$"),
    %% Sorted and deduplicated, so a failure prints every version rather than
    %% the first pair that happened to be compared.
    ?assertEqual([Image], lists:usort([Image, CiCheck, Tools, running_otp()])).

%% Build, CI and runtime are the team pair, named by dated tag AND digest, so a
%% re-pushed tag cannot change what builds or what runs.
images_are_the_digest_pinned_team_pair_test() ->
    Digest = ":[0-9]{8}-[0-9]{4}@sha256:[0-9a-f]{64}",
    ?assertMatch(<<_/binary>>,
                 pinned("Containerfile",
                        "^FROM (ghcr\\.io/macula-io/macula-ci-otp)" ++ Digest ++ " AS builder$")),
    ?assertMatch(<<_/binary>>,
                 pinned("Containerfile",
                        "^FROM (ghcr\\.io/macula-io/macula-pq-runtime)" ++ Digest ++ "$")),
    ?assertMatch(<<_/binary>>,
                 pinned(".github/workflows/lint.yml",
                        "^\\s+image: (ghcr\\.io/macula-io/macula-ci-otp)" ++ Digest ++ "$")).

%% The full release, 28.4.3 and not 28: `otp_release' names only the major.
running_otp() ->
    {ok, Version} = file:read_file(filename:join([code:root_dir(), "releases",
                                                  erlang:system_info(otp_release),
                                                  "OTP_VERSION"])),
    string:trim(Version).

pinned(Relative, Pattern) ->
    {ok, Text} = file:read_file(alongside(Relative)),
    {match, [Version]} = re:run(Text, Pattern,
                                [multiline, {capture, all_but_first, binary}]),
    Version.

%% Relative to the beam rather than the working directory, because eunit runs
%% from wherever the developer happens to be standing.
alongside(Name) -> climb(filename:dirname(code:which(?MODULE)), Name, 8).

climb(_Dir, Name, 0) -> Name;
climb(Dir, Name, Left) ->
    Candidate = filename:join(Dir, Name),
    found(filelib:is_regular(Candidate), Candidate, Dir, Name, Left).

found(true, Candidate, _Dir, _Name, _Left) -> Candidate;
found(false, _Candidate, Dir, Name, Left) ->
    climb(filename:dirname(Dir), Name, Left - 1).

%% The org is the service's own, named after the repository, and fixed in
%% config rather than taken from the deploy environment.
the_org_is_fixed_in_config_test() ->
    {ok, Text} = file:read_file(alongside("config/sys.config.src")),
    ?assertMatch({match, _}, re:run(Text, <<"\\{org, +<<\"mcl-nvidia-pair\">>\\}">>)),
    ?assertEqual(nomatch, binary:match(Text, <<"MCL_ORG">>)).

%%==============================================================================
%% The boot claim names the service and its box
%%==============================================================================

%% Every node that claims on the realm shows its service and host on the
%% Providers desk: mcl_om 0.27 reads MCL_SERVICE_NAME and MCL_BOX. The service
%% name is ours; the box is the deploying host's to say.
the_claim_names_the_service_and_its_box_test() ->
    {ok, Text} = file:read_file(alongside("deploy/docker-compose.yml")),
    ?assertMatch({match, _}, re:run(Text, <<"- MCL_SERVICE_NAME=mcl-nvidia-pair\\n">>)),
    ?assertMatch({match, _}, re:run(Text, <<"- MCL_BOX=\\$\\{MCL_BOX:-\\}\\n">>)).

%% ⚠ NOT IN sys.config. mcl_om prefers its app env to the OS variables, so a
%% `service_name' or `box' line there, even an empty one, would hide the two
%% variables above (until mcl_om 0.27.1 treats empty as unset).
the_claim_labels_are_not_shadowed_by_app_env_test() ->
    {ok, Text} = file:read_file(alongside("config/sys.config.src")),
    ?assertEqual(nomatch, re:run(Text, <<"^\\s*\\{(service_name|box),">>, [multiline])).

