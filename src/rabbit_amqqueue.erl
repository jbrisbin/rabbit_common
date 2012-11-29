%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2012 VMware, Inc.  All rights reserved.
%%

-module(rabbit_amqqueue).

-export([recover/0, stop/0, start/1, declare/5,
         delete_immediately/1, delete/3, purge/1]).
-export([pseudo_queue/2]).
-export([lookup/1, not_found_or_absent/1, with/2, with/3, with_or_die/2,
         assert_equivalence/5,
         check_exclusive_access/2, with_exclusive_access_or_die/3,
         stat/1, deliver/2, deliver_flow/2, requeue/3, ack/3, reject/4]).
-export([list/0, list/1, info_keys/0, info/1, info/2, info_all/1, info_all/2]).
-export([force_event_refresh/0, wake_up/1]).
-export([consumers/1, consumers_all/1, consumer_info_keys/0]).
-export([basic_get/3, basic_consume/7, basic_cancel/4]).
-export([notify_sent/2, notify_sent_queue_down/1, unblock/2, flush_all/2]).
-export([notify_down_all/2, limit_all/3]).
-export([on_node_down/1]).
-export([update/2, store_queue/1, policy_changed/2]).
-export([start_mirroring/1, stop_mirroring/1]).

%% internal
-export([internal_declare/2, internal_delete/2, run_backing_queue/3,
         set_ram_duration_target/2, set_maximum_since_use/2]).

-include("rabbit.hrl").
-include_lib("stdlib/include/qlc.hrl").

-define(INTEGER_ARG_TYPES, [byte, short, signedint, long]).

-define(MORE_CONSUMER_CREDIT_AFTER, 50).

-define(FAILOVER_WAIT_MILLIS, 100).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-export_type([name/0, qmsg/0, routing_result/0]).

-type(name() :: rabbit_types:r('queue')).
-type(qpids() :: [pid()]).
-type(qlen() :: rabbit_types:ok(non_neg_integer())).
-type(qfun(A) :: fun ((rabbit_types:amqqueue()) -> A | no_return())).
-type(qmsg() :: {name(), pid(), msg_id(), boolean(), rabbit_types:message()}).
-type(msg_id() :: non_neg_integer()).
-type(ok_or_errors() ::
        'ok' | {'error', [{'error' | 'exit' | 'throw', any()}]}).
-type(routing_result() :: 'routed' | 'unroutable').
-type(queue_or_absent() :: rabbit_types:amqqueue() |
                           {'absent', rabbit_types:amqqueue()}).
-type(not_found_or_absent() :: 'not_found' |
                               {'absent', rabbit_types:amqqueue()}).
-spec(recover/0 :: () -> [rabbit_types:amqqueue()]).
-spec(stop/0 :: () -> 'ok').
-spec(start/1 :: ([rabbit_types:amqqueue()]) -> 'ok').
-spec(declare/5 ::
        (name(), boolean(), boolean(),
         rabbit_framing:amqp_table(), rabbit_types:maybe(pid()))
        -> {'new' | 'existing' | 'absent', rabbit_types:amqqueue()} |
           rabbit_types:channel_exit()).
-spec(internal_declare/2 ::
        (rabbit_types:amqqueue(), boolean())
        -> queue_or_absent() | rabbit_misc:thunk(queue_or_absent())).
-spec(update/2 ::
        (name(),
         fun((rabbit_types:amqqueue()) -> rabbit_types:amqqueue())) -> 'ok').
-spec(lookup/1 ::
        (name()) -> rabbit_types:ok(rabbit_types:amqqueue()) |
                    rabbit_types:error('not_found');
        ([name()]) -> [rabbit_types:amqqueue()]).
-spec(not_found_or_absent/1 :: (name()) -> not_found_or_absent()).
-spec(with/2 :: (name(), qfun(A)) ->
                     A | rabbit_types:error(not_found_or_absent())).
-spec(with/3 :: (name(), qfun(A), fun((not_found_or_absent()) -> B)) -> A | B).
-spec(with_or_die/2 ::
        (name(), qfun(A)) -> A | rabbit_types:channel_exit()).
-spec(assert_equivalence/5 ::
        (rabbit_types:amqqueue(), boolean(), boolean(),
         rabbit_framing:amqp_table(), rabbit_types:maybe(pid()))
        -> 'ok' | rabbit_types:channel_exit() |
           rabbit_types:connection_exit()).
-spec(check_exclusive_access/2 ::
        (rabbit_types:amqqueue(), pid())
        -> 'ok' | rabbit_types:channel_exit()).
-spec(with_exclusive_access_or_die/3 ::
        (name(), pid(), qfun(A)) -> A | rabbit_types:channel_exit()).
-spec(list/0 :: () -> [rabbit_types:amqqueue()]).
-spec(list/1 :: (rabbit_types:vhost()) -> [rabbit_types:amqqueue()]).
-spec(info_keys/0 :: () -> rabbit_types:info_keys()).
-spec(info/1 :: (rabbit_types:amqqueue()) -> rabbit_types:infos()).
-spec(info/2 ::
        (rabbit_types:amqqueue(), rabbit_types:info_keys())
        -> rabbit_types:infos()).
-spec(info_all/1 :: (rabbit_types:vhost()) -> [rabbit_types:infos()]).
-spec(info_all/2 :: (rabbit_types:vhost(), rabbit_types:info_keys())
                    -> [rabbit_types:infos()]).
-spec(force_event_refresh/0 :: () -> 'ok').
-spec(wake_up/1 :: (rabbit_types:amqqueue()) -> 'ok').
-spec(consumers/1 ::
        (rabbit_types:amqqueue())
        -> [{pid(), rabbit_types:ctag(), boolean()}]).
-spec(consumer_info_keys/0 :: () -> rabbit_types:info_keys()).
-spec(consumers_all/1 ::
        (rabbit_types:vhost())
        -> [{name(), pid(), rabbit_types:ctag(), boolean()}]).
-spec(stat/1 ::
        (rabbit_types:amqqueue())
        -> {'ok', non_neg_integer(), non_neg_integer()}).
-spec(delete_immediately/1 :: (qpids()) -> 'ok').
-spec(delete/3 ::
        (rabbit_types:amqqueue(), 'false', 'false')
        -> qlen();
        (rabbit_types:amqqueue(), 'true' , 'false')
        -> qlen() | rabbit_types:error('in_use');
        (rabbit_types:amqqueue(), 'false', 'true' )
        -> qlen() | rabbit_types:error('not_empty');
        (rabbit_types:amqqueue(), 'true' , 'true' )
        -> qlen() |
           rabbit_types:error('in_use') |
           rabbit_types:error('not_empty')).
-spec(purge/1 :: (rabbit_types:amqqueue()) -> qlen()).
-spec(deliver/2 :: ([rabbit_types:amqqueue()], rabbit_types:delivery()) ->
                        {routing_result(), qpids()}).
-spec(deliver_flow/2 :: ([rabbit_types:amqqueue()], rabbit_types:delivery()) ->
                             {routing_result(), qpids()}).
-spec(requeue/3 :: (pid(), [msg_id()],  pid()) -> 'ok').
-spec(ack/3 :: (pid(), [msg_id()], pid()) -> 'ok').
-spec(reject/4 :: (pid(), [msg_id()], boolean(), pid()) -> 'ok').
-spec(notify_down_all/2 :: (qpids(), pid()) -> ok_or_errors()).
-spec(limit_all/3 :: (qpids(), pid(), rabbit_limiter:token()) ->
                          ok_or_errors()).
-spec(basic_get/3 :: (rabbit_types:amqqueue(), pid(), boolean()) ->
                          {'ok', non_neg_integer(), qmsg()} | 'empty').
-spec(basic_consume/7 ::
        (rabbit_types:amqqueue(), boolean(), pid(),
         rabbit_limiter:token(), rabbit_types:ctag(), boolean(), any())
        -> rabbit_types:ok_or_error('exclusive_consume_unavailable')).
-spec(basic_cancel/4 ::
        (rabbit_types:amqqueue(), pid(), rabbit_types:ctag(), any()) -> 'ok').
-spec(notify_sent/2 :: (pid(), pid()) -> 'ok').
-spec(notify_sent_queue_down/1 :: (pid()) -> 'ok').
-spec(unblock/2 :: (pid(), pid()) -> 'ok').
-spec(flush_all/2 :: (qpids(), pid()) -> 'ok').
-spec(internal_delete/2 ::
        (name(), pid()) -> rabbit_types:ok_or_error('not_found') |
                           rabbit_types:connection_exit() |
                           fun (() -> rabbit_types:ok_or_error('not_found') |
                                      rabbit_types:connection_exit())).
-spec(run_backing_queue/3 ::
        (pid(), atom(),
         (fun ((atom(), A) -> {[rabbit_types:msg_id()], A}))) -> 'ok').
-spec(set_ram_duration_target/2 :: (pid(), number() | 'infinity') -> 'ok').
-spec(set_maximum_since_use/2 :: (pid(), non_neg_integer()) -> 'ok').
-spec(on_node_down/1 :: (node()) -> 'ok').
-spec(pseudo_queue/2 :: (name(), pid()) -> rabbit_types:amqqueue()).
-spec(store_queue/1 :: (rabbit_types:amqqueue()) -> 'ok').
-spec(policy_changed/2 ::
        (rabbit_types:amqqueue(), rabbit_types:amqqueue()) -> 'ok').
-spec(start_mirroring/1 :: (pid()) -> 'ok').
-spec(stop_mirroring/1 :: (pid()) -> 'ok').

-endif.

%%----------------------------------------------------------------------------

-define(CONSUMER_INFO_KEYS,
        [queue_name, channel_pid, consumer_tag, ack_required]).

recover() ->
    %% Clear out remnants of old incarnation, in case we restarted
    %% faster than other nodes handled DOWN messages from us.
    on_node_down(node()),
    DurableQueues = find_durable_queues(),
    {ok, BQ} = application:get_env(rabbit, backing_queue_module),
    ok = BQ:start([QName || #amqqueue{name = QName} <- DurableQueues]),
    {ok,_} = supervisor:start_child(
               rabbit_sup,
               {rabbit_amqqueue_sup,
                {rabbit_amqqueue_sup, start_link, []},
                transient, infinity, supervisor, [rabbit_amqqueue_sup]}),
    recover_durable_queues(DurableQueues).

stop() ->
    ok = supervisor:terminate_child(rabbit_sup, rabbit_amqqueue_sup),
    ok = supervisor:delete_child(rabbit_sup, rabbit_amqqueue_sup),
    {ok, BQ} = application:get_env(rabbit, backing_queue_module),
    ok = BQ:stop().

start(Qs) ->
    %% At this point all recovered queues and their bindings are
    %% visible to routing, so now it is safe for them to complete
    %% their initialisation (which may involve interacting with other
    %% queues).
    [Pid ! {self(), go} || #amqqueue{pid = Pid} <- Qs],
    ok.

find_durable_queues() ->
    Node = node(),
    %% TODO: use dirty ops instead
    rabbit_misc:execute_mnesia_transaction(
      fun () ->
              qlc:e(qlc:q([Q || Q = #amqqueue{pid = Pid}
                                    <- mnesia:table(rabbit_durable_queue),
                                node(Pid) == Node]))
      end).

recover_durable_queues(DurableQueues) ->
    Qs = [start_queue_process(node(), Q) || Q <- DurableQueues],
    [Q || Q = #amqqueue{pid = Pid} <- Qs,
          gen_server2:call(Pid, {init, self()}, infinity) == {new, Q}].

declare(QueueName, Durable, AutoDelete, Args, Owner) ->
    ok = check_declare_arguments(QueueName, Args),
    Q0 = rabbit_policy:set(#amqqueue{name            = QueueName,
                                     durable         = Durable,
                                     auto_delete     = AutoDelete,
                                     arguments       = Args,
                                     exclusive_owner = Owner,
                                     pid             = none,
                                     slave_pids      = [],
                                     sync_slave_pids = [],
                                     gm_pids         = []}),
    {Node, _MNodes} = rabbit_mirror_queue_misc:suggested_queue_nodes(Q0),
    Q1 = start_queue_process(Node, Q0),
    gen_server2:call(Q1#amqqueue.pid, {init, new}, infinity).

internal_declare(Q, true) ->
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () -> ok = store_queue(Q), rabbit_misc:const(Q) end);
internal_declare(Q = #amqqueue{name = QueueName}, false) ->
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () ->
              case mnesia:wread({rabbit_queue, QueueName}) of
                  [] ->
                      case not_found_or_absent(QueueName) of
                          not_found        -> Q1 = rabbit_policy:set(Q),
                                              ok = store_queue(Q1),
                                              B = add_default_binding(Q1),
                                              fun () -> B(), Q1 end;
                          {absent, _Q} = R -> rabbit_misc:const(R)
                      end;
                  [ExistingQ = #amqqueue{pid = QPid}] ->
                      case rabbit_misc:is_process_alive(QPid) of
                          true  -> rabbit_misc:const(ExistingQ);
                          false -> TailFun = internal_delete(QueueName, QPid),
                                   fun () -> TailFun(), ExistingQ end
                      end
              end
      end).

update(Name, Fun) ->
    case mnesia:wread({rabbit_queue, Name}) of
        [Q = #amqqueue{durable = Durable}] ->
            Q1 = Fun(Q),
            ok = mnesia:write(rabbit_queue, Q1, write),
            case Durable of
                true -> ok = mnesia:write(rabbit_durable_queue, Q1, write);
                _    -> ok
            end;
        [] ->
            ok
    end.

store_queue(Q = #amqqueue{durable = true}) ->
    ok = mnesia:write(rabbit_durable_queue, Q#amqqueue{slave_pids = []}, write),
    ok = mnesia:write(rabbit_queue, Q, write),
    ok;
store_queue(Q = #amqqueue{durable = false}) ->
    ok = mnesia:write(rabbit_queue, Q, write),
    ok.

policy_changed(Q1, Q2) ->
    rabbit_mirror_queue_misc:update_mirrors(Q1, Q2).

start_queue_process(Node, Q) ->
    {ok, Pid} = rabbit_amqqueue_sup:start_child(Node, [Q]),
    Q#amqqueue{pid = Pid}.

add_default_binding(#amqqueue{name = QueueName}) ->
    ExchangeName = rabbit_misc:r(QueueName, exchange, <<>>),
    RoutingKey = QueueName#resource.name,
    rabbit_binding:add(#binding{source      = ExchangeName,
                                destination = QueueName,
                                key         = RoutingKey,
                                args        = []}).

lookup(Names) when is_list(Names) ->
    %% Normally we'd call mnesia:dirty_read/1 here, but that is quite
    %% expensive for reasons explained in rabbit_misc:dirty_read/1.
    lists:append([ets:lookup(rabbit_queue, Name) || Name <- Names]);
lookup(Name) ->
    rabbit_misc:dirty_read({rabbit_queue, Name}).

not_found_or_absent(Name) ->
    %% NB: we assume that the caller has already performed a lookup on
    %% rabbit_queue and not found anything
    case mnesia:read({rabbit_durable_queue, Name}) of
        []  -> not_found;
        [Q] -> {absent, Q} %% Q exists on stopped node
    end.

not_found_or_absent_dirty(Name) ->
    %% We should read from both tables inside a tx, to get a
    %% consistent view. But the chances of an inconsistency are small,
    %% and only affect the error kind.
    case rabbit_misc:dirty_read({rabbit_durable_queue, Name}) of
        {error, not_found} -> not_found;
        {ok, Q}            -> {absent, Q}
    end.

with(Name, F, E) ->
    case lookup(Name) of
        {ok, Q = #amqqueue{pid = QPid}} ->
            %% We check is_process_alive(QPid) in case we receive a
            %% nodedown (for example) in F() that has nothing to do
            %% with the QPid.
            rabbit_misc:with_exit_handler(
              fun () ->
                      case rabbit_misc:is_process_alive(QPid) of
                          true  -> E(not_found_or_absent_dirty(Name));
                          false -> timer:sleep(25),
                                   with(Name, F, E)
                      end
              end, fun () -> F(Q) end);
        {error, not_found} ->
            E(not_found_or_absent_dirty(Name))
    end.

with(Name, F) -> with(Name, F, fun (E) -> {error, E} end).

with_or_die(Name, F) ->
    with(Name, F, fun (not_found)   -> rabbit_misc:not_found(Name);
                      ({absent, Q}) -> rabbit_misc:absent(Q)
                  end).

assert_equivalence(#amqqueue{durable     = Durable,
                             auto_delete = AutoDelete} = Q,
                   Durable, AutoDelete, RequiredArgs, Owner) ->
    assert_args_equivalence(Q, RequiredArgs),
    check_exclusive_access(Q, Owner, strict);
assert_equivalence(#amqqueue{name = QueueName},
                   _Durable, _AutoDelete, _RequiredArgs, _Owner) ->
    rabbit_misc:protocol_error(
      precondition_failed, "parameters for ~s not equivalent",
      [rabbit_misc:rs(QueueName)]).

check_exclusive_access(Q, Owner) -> check_exclusive_access(Q, Owner, lax).

check_exclusive_access(#amqqueue{exclusive_owner = Owner}, Owner, _MatchType) ->
    ok;
check_exclusive_access(#amqqueue{exclusive_owner = none}, _ReaderPid, lax) ->
    ok;
check_exclusive_access(#amqqueue{name = QueueName}, _ReaderPid, _MatchType) ->
    rabbit_misc:protocol_error(
      resource_locked,
      "cannot obtain exclusive access to locked ~s",
      [rabbit_misc:rs(QueueName)]).

with_exclusive_access_or_die(Name, ReaderPid, F) ->
    with_or_die(Name,
                fun (Q) -> check_exclusive_access(Q, ReaderPid), F(Q) end).

assert_args_equivalence(#amqqueue{name = QueueName, arguments = Args},
                        RequiredArgs) ->
    rabbit_misc:assert_args_equivalence(
      Args, RequiredArgs, QueueName, [<<"x-expires">>, <<"x-message-ttl">>]).

check_declare_arguments(QueueName, Args) ->
    Checks = [{<<"x-expires">>,                 fun check_expires_arg/2},
              {<<"x-message-ttl">>,             fun check_message_ttl_arg/2},
              {<<"x-dead-letter-exchange">>,    fun check_string_arg/2},
              {<<"x-dead-letter-routing-key">>, fun check_dlxrk_arg/2}],
    [case rabbit_misc:table_lookup(Args, Key) of
         undefined -> ok;
         TypeVal   -> case Fun(TypeVal, Args) of
                          ok             -> ok;
                          {error, Error} -> rabbit_misc:protocol_error(
                                              precondition_failed,
                                              "invalid arg '~s' for ~s: ~255p",
                                              [Key, rabbit_misc:rs(QueueName),
                                               Error])
                      end
     end || {Key, Fun} <- Checks],
    ok.

check_string_arg({longstr, _}, _Args) ->
    ok;
check_string_arg({Type, _}, _) ->
    {error, {unacceptable_type, Type}}.

check_int_arg({Type, _}, _) ->
    case lists:member(Type, ?INTEGER_ARG_TYPES) of
        true  -> ok;
        false -> {error, {unacceptable_type, Type}}
    end.

check_expires_arg({Type, Val}, Args) ->
    case check_int_arg({Type, Val}, Args) of
        ok when Val == 0 -> {error, {value_zero, Val}};
        ok               -> rabbit_misc:check_expiry(Val);
        Error            -> Error
    end.

check_message_ttl_arg({Type, Val}, Args) ->
    case check_int_arg({Type, Val}, Args) of
        ok    -> rabbit_misc:check_expiry(Val);
        Error -> Error
    end.

check_dlxrk_arg({longstr, _}, Args) ->
    case rabbit_misc:table_lookup(Args, <<"x-dead-letter-exchange">>) of
        undefined -> {error, routing_key_but_no_dlx_defined};
        _         -> ok
    end;
check_dlxrk_arg({Type, _}, _Args) ->
    {error, {unacceptable_type, Type}}.

list() ->
    mnesia:dirty_match_object(rabbit_queue, #amqqueue{_ = '_'}).

list(VHostPath) ->
    mnesia:dirty_match_object(
      rabbit_queue,
      #amqqueue{name = rabbit_misc:r(VHostPath, queue), _ = '_'}).

info_keys() -> rabbit_amqqueue_process:info_keys().

map(VHostPath, F) -> rabbit_misc:filter_exit_map(F, list(VHostPath)).

info(#amqqueue{ pid = QPid }) ->
    delegate_call(QPid, info).

info(#amqqueue{ pid = QPid }, Items) ->
    case delegate_call(QPid, {info, Items}) of
        {ok, Res}      -> Res;
        {error, Error} -> throw(Error)
    end.

info_all(VHostPath) -> map(VHostPath, fun (Q) -> info(Q) end).

info_all(VHostPath, Items) -> map(VHostPath, fun (Q) -> info(Q, Items) end).

%% We need to account for the idea that queues may be mid-promotion
%% during force_event_refresh (since it's likely we're doing this in
%% the first place since a node failed). Therefore we keep poking at
%% the list of queues until we were able to talk to a live process or
%% the queue no longer exists.
force_event_refresh() ->
    force_event_refresh([Q#amqqueue.name || Q <- list()]).

force_event_refresh(QNames) ->
    Qs = [Q || Q <- list(), lists:member(Q#amqqueue.name, QNames)],
    {_, Bad} = rabbit_misc:multi_call(
                 [Q#amqqueue.pid || Q <- Qs], force_event_refresh),
    FailedPids = [Pid || {Pid, _Reason} <- Bad],
    Failed = [Name || #amqqueue{name = Name, pid = Pid} <- Qs,
                      lists:member(Pid, FailedPids)],
    case Failed of
        [] -> ok;
        _  -> timer:sleep(?FAILOVER_WAIT_MILLIS),
              force_event_refresh(Failed)
    end.

wake_up(#amqqueue{pid = QPid}) -> gen_server2:cast(QPid, wake_up).

consumers(#amqqueue{ pid = QPid }) ->
    delegate_call(QPid, consumers).

consumer_info_keys() -> ?CONSUMER_INFO_KEYS.

consumers_all(VHostPath) ->
    ConsumerInfoKeys=consumer_info_keys(),
    lists:append(
      map(VHostPath,
          fun (Q) ->
              [lists:zip(ConsumerInfoKeys,
                         [Q#amqqueue.name, ChPid, ConsumerTag, AckRequired]) ||
                         {ChPid, ConsumerTag, AckRequired} <- consumers(Q)]
          end)).

stat(#amqqueue{pid = QPid}) ->
    delegate_call(QPid, stat).

delete_immediately(QPids) ->
    [gen_server2:cast(QPid, delete_immediately) || QPid <- QPids],
    ok.

delete(#amqqueue{ pid = QPid }, IfUnused, IfEmpty) ->
    delegate_call(QPid, {delete, IfUnused, IfEmpty}).

purge(#amqqueue{ pid = QPid }) -> delegate_call(QPid, purge).

deliver(Qs, Delivery) -> deliver(Qs, Delivery, noflow).

deliver_flow(Qs, Delivery) -> deliver(Qs, Delivery, flow).

requeue(QPid, MsgIds, ChPid) ->
    delegate_call(QPid, {requeue, MsgIds, ChPid}).

ack(QPid, MsgIds, ChPid) ->
    delegate_cast(QPid, {ack, MsgIds, ChPid}).

reject(QPid, MsgIds, Requeue, ChPid) ->
    delegate_cast(QPid, {reject, MsgIds, Requeue, ChPid}).

notify_down_all(QPids, ChPid) ->
    safe_delegate_call_ok(
      fun (QPid) -> gen_server2:call(QPid, {notify_down, ChPid}, infinity) end,
      QPids).

limit_all(QPids, ChPid, Limiter) ->
    delegate:invoke_no_result(
      QPids, fun (QPid) -> gen_server2:cast(QPid, {limit, ChPid, Limiter}) end).

basic_get(#amqqueue{pid = QPid}, ChPid, NoAck) ->
    delegate_call(QPid, {basic_get, ChPid, NoAck}).

basic_consume(#amqqueue{pid = QPid}, NoAck, ChPid, Limiter,
              ConsumerTag, ExclusiveConsume, OkMsg) ->
    delegate_call(QPid, {basic_consume, NoAck, ChPid,
                         Limiter, ConsumerTag, ExclusiveConsume, OkMsg}).

basic_cancel(#amqqueue{pid = QPid}, ChPid, ConsumerTag, OkMsg) ->
    delegate_call(QPid, {basic_cancel, ChPid, ConsumerTag, OkMsg}).

notify_sent(QPid, ChPid) ->
    Key = {consumer_credit_to, QPid},
    put(Key, case get(Key) of
                 1         -> gen_server2:cast(
                                QPid, {notify_sent, ChPid,
                                       ?MORE_CONSUMER_CREDIT_AFTER}),
                              ?MORE_CONSUMER_CREDIT_AFTER;
                 undefined -> erlang:monitor(process, QPid),
                              ?MORE_CONSUMER_CREDIT_AFTER - 1;
                 C         -> C - 1
             end),
    ok.

notify_sent_queue_down(QPid) ->
    erase({consumer_credit_to, QPid}),
    ok.

unblock(QPid, ChPid) ->
    delegate_cast(QPid, {unblock, ChPid}).

flush_all(QPids, ChPid) ->
    delegate:invoke_no_result(
      QPids, fun (QPid) -> gen_server2:cast(QPid, {flush, ChPid}) end).

internal_delete1(QueueName) ->
    ok = mnesia:delete({rabbit_queue, QueueName}),
    %% this 'guarded' delete prevents unnecessary writes to the mnesia
    %% disk log
    case mnesia:wread({rabbit_durable_queue, QueueName}) of
        []  -> ok;
        [_] -> ok = mnesia:delete({rabbit_durable_queue, QueueName})
    end,
    %% we want to execute some things, as decided by rabbit_exchange,
    %% after the transaction.
    rabbit_binding:remove_for_destination(QueueName).

internal_delete(QueueName, QPid) ->
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () ->
              case mnesia:wread({rabbit_queue, QueueName}) of
                  []  -> rabbit_misc:const({error, not_found});
                  [_] -> Deletions = internal_delete1(QueueName),
                         T = rabbit_binding:process_deletions(Deletions),
                         fun() ->
                                 ok = T(),
                                 ok = rabbit_event:notify(queue_deleted,
                                                          [{pid,  QPid},
                                                           {name, QueueName}])
                         end
              end
      end).

run_backing_queue(QPid, Mod, Fun) ->
    gen_server2:cast(QPid, {run_backing_queue, Mod, Fun}).

set_ram_duration_target(QPid, Duration) ->
    gen_server2:cast(QPid, {set_ram_duration_target, Duration}).

set_maximum_since_use(QPid, Age) ->
    gen_server2:cast(QPid, {set_maximum_since_use, Age}).

start_mirroring(QPid) -> ok = delegate_call(QPid, start_mirroring).
stop_mirroring(QPid) -> ok = delegate_call(QPid, stop_mirroring).

on_node_down(Node) ->
    rabbit_misc:execute_mnesia_tx_with_tail(
      fun () -> QsDels =
                    qlc:e(qlc:q([{{QName, Pid}, delete_queue(QName)} ||
                                    #amqqueue{name = QName, pid = Pid,
                                              slave_pids = []}
                                        <- mnesia:table(rabbit_queue),
                                    node(Pid) == Node andalso
                                    not rabbit_misc:is_process_alive(Pid)])),
                {Qs, Dels} = lists:unzip(QsDels),
                T = rabbit_binding:process_deletions(
                      lists:foldl(fun rabbit_binding:combine_deletions/2,
                                  rabbit_binding:new_deletions(), Dels)),
                fun () ->
                        T(),
                        lists:foreach(
                          fun({QName, QPid}) ->
                                  ok = rabbit_event:notify(queue_deleted,
                                                           [{pid,  QPid},
                                                            {name, QName}])
                          end, Qs)
                end
      end).

delete_queue(QueueName) ->
    ok = mnesia:delete({rabbit_queue, QueueName}),
    rabbit_binding:remove_transient_for_destination(QueueName).

pseudo_queue(QueueName, Pid) ->
    #amqqueue{name         = QueueName,
              durable      = false,
              auto_delete  = false,
              arguments    = [],
              pid          = Pid,
              slave_pids   = []}.

deliver([], #delivery{mandatory = false}, _Flow) ->
    %% /dev/null optimisation
    {routed, []};

deliver(Qs, Delivery = #delivery{mandatory = false}, Flow) ->
    %% optimisation: when Mandatory = false, rabbit_amqqueue:deliver
    %% will deliver the message to the queue process asynchronously,
    %% and return true, which means all the QPids will always be
    %% returned. It is therefore safe to use a fire-and-forget cast
    %% here and return the QPids - the semantics is preserved. This
    %% scales much better than the case below.
    {MPids, SPids} = qpids(Qs),
    QPids = MPids ++ SPids,
    case Flow of
        flow   -> [credit_flow:send(QPid) || QPid <- QPids];
        noflow -> ok
    end,

    %% We let slaves know that they were being addressed as slaves at
    %% the time - if they receive such a message from the channel
    %% after they have become master they should mark the message as
    %% 'delivered' since they do not know what the master may have
    %% done with it.
    MMsg = {deliver, Delivery, false, Flow},
    SMsg = {deliver, Delivery, true,  Flow},
    delegate:invoke_no_result(MPids,
                              fun (QPid) -> gen_server2:cast(QPid, MMsg) end),
    delegate:invoke_no_result(SPids,
                              fun (QPid) -> gen_server2:cast(QPid, SMsg) end),
    {routed, QPids};

deliver(Qs, Delivery, _Flow) ->
    {MPids, SPids} = qpids(Qs),
    %% see comment above
    MMsg = {deliver, Delivery, false},
    SMsg = {deliver, Delivery, true},
    {MRouted, _} = delegate:invoke(
                     MPids, fun (QPid) ->
                                    ok = gen_server2:call(QPid, MMsg, infinity)
                            end),
    {SRouted, _} = delegate:invoke(
                     SPids, fun (QPid) ->
                                    ok = gen_server2:call(QPid, SMsg, infinity)
                            end),
    case MRouted ++ SRouted of
        [] -> {unroutable, []};
        R  -> {routed,     [QPid || {QPid, ok} <- R]}
    end.

qpids(Qs) ->
    {MPids, SPids} = lists:foldl(fun (#amqqueue{pid = QPid, slave_pids = SPids},
                                      {MPidAcc, SPidAcc}) ->
                                         {[QPid | MPidAcc], [SPids | SPidAcc]}
                                 end, {[], []}, Qs),
    {MPids, lists:append(SPids)}.

safe_delegate_call_ok(F, Pids) ->
    {_, Bads} = delegate:invoke(Pids, fun (Pid) ->
                                              rabbit_misc:with_exit_handler(
                                                fun () -> ok end,
                                                fun () -> F(Pid) end)
                                      end),
    case lists:filter(
           fun ({_Pid, {exit, {R, _}, _}}) -> rabbit_misc:is_abnormal_exit(R);
               ({_Pid, _})                 -> false
           end, Bads) of
        []    -> ok;
        Bads1 -> {error, Bads1}
    end.

delegate_call(Pid, Msg) ->
    delegate:invoke(Pid, fun (P) -> gen_server2:call(P, Msg, infinity) end).

delegate_cast(Pid, Msg) ->
    delegate:invoke_no_result(Pid, fun (P) -> gen_server2:cast(P, Msg) end).
