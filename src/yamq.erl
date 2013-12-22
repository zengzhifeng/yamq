%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% @doc
%%%
%%% @end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%_* Module declaration ===============================================
-module(yamq).
-behaviour(gen_server).

%%%_* Exports ==========================================================
%% api
-export([ start_link/1
        , stop/0
        , enqueue/2
        , enqueue/3
        ]).

%% gen_server
-export([ init/1
        , terminate/2
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , code_change/3
        ]).

%%%_* Includes =========================================================
-include_lib("stdlib2/include/prelude.hrl").

%%%_* Code =============================================================
%%%_ * Types -----------------------------------------------------------
-record(s, { store = throw('store')
           , func  = throw('func')
           , spids = throw('spids')
           , wpids = throw('wpids')
           , wfree = throw('wfree')
           , heads = throw('heads')
           }).

%%%_ * API -------------------------------------------------------------
start_link(Args) ->
  gen_server:start_link({local, ?MODULE}, ?MODULE, Args, []).

stop() ->
  gen_server:call(?MODULE, stop, infinity).

%% @doc enqueue X with priority P
enqueue(X, P) ->
  enqueue(X, P, 0).

%% @doc enqueue X with priority P and due in D ms
enqueue(X, P, 0)
  when P>=1, P=<8 ->
  gen_server:call(?MODULE, {enqueue, X, P, 0}, infinity);
enqueue(X, P, D)
  when (P>=1 andalso P=<8),
       (is_integer(D) andalso D>0) ->
  DMS = (s2_time:stamp() div 1000) + D,
  gen_server:call(?MODULE, {enqueue, X, P, DMS}, infinity).

%%%_ * gen_server callbacks --------------------------------------------
init(Args) ->
  process_flag(trap_exit, true),
  {ok, Func}    = s2_lists:assoc(Args, 'func'),
  {ok, Store}   = s2_lists:assoc(Args, 'store'),
  {ok, Workers} = s2_lists:assoc(Args, 'workers'),
  _     = q_init(),
  Heads = q_load(Store),
  {ok, #s{ store    = Store
         , func     = Func
         , wpids    = []
         , spids    = []
         , wfree    = Workers
         , heads    = Heads
         }, wait(Workers, Heads)}.

terminate(_Rsn, S) ->
  lists:foreach(fun(Pid) ->
                    receive {'EXIT', Pid, _Rsn} -> ok end
                end,
                S#s.wpids ++ [Pid || {Pid,_} <- S#s.spids]).

handle_call({enqueue, X, P, D}, From, #s{store=Store} = S) ->
  %% k needs to be:
  %% * unique
  %% * monotonically increasing
  K     = s2_time:stamp(),
  Pid   = spawn_link(fun() -> ok = Store:put({K,P,D}, X) end),
  SPids = [{Pid,{K,P,D,From}}|S#s.spids],
  {noreply, S#s{spids=SPids}, wait(S#s.wfree, S#s.heads)};
handle_call(stop, _From, S) ->
  {stop, normal, ok, S}.

handle_cast(Msg, S) ->
  {stop, {bad_cast, Msg}, S}.

handle_info({'EXIT', Pid, normal}, S) ->
  case lists:keytake(Pid, 1, S#s.spids) of
    {value, {Pid, {K,P,D,From}}, SPids} ->
      Heads = q_insert(K,P,D,S#s.heads),
      gen_server:reply(From, ok),
      {noreply, S#s{spids = SPids,
                    heads = Heads}, wait(S#s.wfree, Heads)};
    false ->
      ?hence(lists:member(Pid, S#s.wpids)),
      case q_next(S#s.heads) of
        {ok, {{K,P,D}, Heads}} ->
          NPid = w_spawn(S#s.store, S#s.func, {K,P,D}),
          {noreply, S#s{wpids = [NPid|S#s.wpids--[Pid]],
                        heads = Heads}, wait(S#s.wfree, Heads)};
        {error, empty} ->
          WFree = S#s.wfree+1,
          {noreply, S#s{wfree = WFree,
                        wpids = S#s.wpids--[Pid]
                       }, wait(WFree, S#s.heads)}
      end
  end;
handle_info({'EXIT', Pid, Rsn}, S) ->
  case lists:keytake(Pid, 1, S#s.spids) of
    {value, {Pid, {_K,_P,_D,From}}, SPids} ->
      ?warning("writer died: ~p", [Rsn]),
      gen_server:reply(From, {error, Rsn}),
      {stop, {store_failed, Rsn}, S#s{spids=SPids}};
    false ->
      ?hence(lists:member(Pid, S#s.wpids)),
      ?warning("worker died: ~p", [Rsn]),
      {stop, {worker_failed, Rsn}, S#s{wpids=S#s.wpids--[Pid]}}
  end;
handle_info(timeout, S) ->
  ?hence(S#s.wfree > 0),
  case q_next(S#s.heads) of
    {ok, {{K,P,D},Heads}} ->
      Pid   = w_spawn(S#s.store, S#s.func, {K,P,D}),
      WFree = S#s.wfree - 1,
      WPids = [Pid|S#s.wpids],
      {noreply, S#s{wfree = WFree,
                    wpids = WPids,
                    heads = Heads}, wait(WFree, Heads)};
    {error, empty} ->
      %% hmm..
      {noreply, S, wait(S#s.wfree, S#s.heads)}
  end;
handle_info(Msg, S) ->
  ?warning("~p", [Msg]),
  {noreply, S, wait(S#s.wfree, S#s.heads)}.

code_change(_OldVsn, S, _Extra) ->
  {ok, S}.

%%%_ * Internals gen_server util ---------------------------------------
wait(0,      _Heads       ) -> infinity;
wait(_WFree, []           ) -> infinity;
wait(_WFree, [{_QS,DS}|Hs]) ->
  case lists:foldl(fun({_Q, D},Acc) when D < Acc -> D;
                      ({_Q,_D},Acc)              -> Acc
                   end, DS, Hs) of
    0   -> 0;
    Min -> lists:max([0, (Min - s2_time:stamp() div 1000)+1])
  end.

%%%_ * Internals queue -------------------------------------------------
-define(QS, ['q1', 'q2', 'q3', 'q4', 'q5', 'q6', 'q7', 'q8']).

q_init() ->
  lists:foreach(fun(Q) ->
                    Q = ets:new(Q, [ordered_set, private, named_table])
                end, ?QS).

q_load(Store) ->
  {ok, Keys} = Store:list(),
  lists:foldl(fun({K,P,D}, Heads) ->
                  q_insert(K,P,D,Heads)
              end, [], Keys).

q_insert(K,P,D,Heads0) ->
  Q    = q_p2q(P),
  true = ets:insert_new(Q, {{D, K}, []}),
  case lists:keytake(Q, 1, Heads0) of
    {value, {Q,DP}, _Heads} when DP =< D -> Heads0;
    {value, {Q,DP},  Heads} when DP >= D -> [{Q,D}|Heads];
    false                                -> [{Q,D}|Heads0]
  end.

q_next(Heads) ->
  S = s2_time:stamp() div 1000,
  case lists:filter(fun({_Q,D}) -> D =< S end, Heads) of
    []    -> {error, empty};
    Ready -> q_take_next(q_pick(Ready), Heads)
  end.

q_pick(Ready) ->
  [{Q,_}|_] = lists:sort(Ready),
  Q.

q_take_next(Q, Heads0) ->
  {D,K} = ets:first(Q),
  true  = ets:delete(Q, {D,K}),
  Heads = lists:keydelete(Q, 1, Heads0),
  case ets:first(Q) of
    '$end_of_table' -> {ok, {{K,q_q2p(Q),D}, Heads}};
    {ND,_NK}        -> {ok, {{K,q_q2p(Q),D}, [{Q,ND}|Heads]}}
  end.

%% queue to priority
q_q2p('q1') -> 1;
q_q2p('q2') -> 2;
q_q2p('q3') -> 3;
q_q2p('q4') -> 4;
q_q2p('q5') -> 5;
q_q2p('q6') -> 6;
q_q2p('q7') -> 7;
q_q2p('q8') -> 8.

%% priority to queue
q_p2q(1) -> 'q1';
q_p2q(2) -> 'q2';
q_p2q(3) -> 'q3';
q_p2q(4) -> 'q4';
q_p2q(5) -> 'q5';
q_p2q(6) -> 'q6';
q_p2q(7) -> 'q7';
q_p2q(8) -> 'q8'.

%%%_ * Internals workers -----------------------------------------------
w_spawn(Store, Fun, {K,P,D}) ->
  erlang:spawn_link(
    fun() ->
        {ok, X} = Store:get({K,P,D}),
        ok      = Fun(X),
        ok      = Store:delete({K,P,D})
    end).

%%%_* Tests ============================================================
-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

basic_test() ->
  Daddy = self(),
  yamq_test:run(
    fun(Msg) -> Daddy ! Msg, ok end,
    fun() ->
        lists:foreach(fun(N) ->
                          ok = yamq:enqueue({basic, N}, N)
                      end, lists:seq(1, 8)),
        'receive'([{basic, N} || N <- lists:seq(1,8)])
    end).

delay1_test() ->
  Daddy = self(),
  yamq_test:run(
    fun(Msg) -> Daddy ! Msg, ok end,
    fun() ->
        ok = yamq:enqueue({delay, 1}, 1, 2000),
        ok = yamq:enqueue({delay, 2}, 1, 1000),
        ok = yamq:enqueue({delay, 3}, 1, 3000),
        ok = yamq:enqueue({delay, 4}, 2, 500),
        ok = yamq:enqueue({delay, 5}, 2, 4000),
        receive_in_order([{delay, N} || N <- [4,2,1,3,5]])
    end).

delay2_test() ->
  Daddy = self(),
  yamq_test:run(
    fun(Msg) -> Daddy ! Msg, ok end,
    fun() ->
        ok = yamq:enqueue({delay2, 1}, 1, 3000),
        receive _ -> exit(fail) after 2500 -> ok end,
        receive {delay2,1} -> ok after 1000 -> exit(fail) end
    end).

priority_test() ->
  Daddy = self(),
  yamq_test:run(
    fun(Msg) -> timer:sleep(400), Daddy ! Msg,ok end,
    fun() ->
        yamq:enqueue({priority_test, 1}, 1),
        timer:sleep(100),
        lists:foreach(fun(P) ->
                          yamq:enqueue({priority_test,P},P)
                      end, lists:reverse(lists:seq(2,8))),
        receive_in_order([{priority_test, N} || N <- lists:seq(1,8)])
    end,
    [{workers, 1}]).

stop_wait_for_workers_test() ->
  Daddy = self(),
  yamq_test:run(
    fun(Msg) -> timer:sleep(1000), Daddy ! Msg, ok end,
    fun() ->
        yamq:enqueue({stop_wait_for_workers_test, 1}, 1),
        timer:sleep(100),
        yamq:stop(),
        receive_in_order([{stop_wait_for_workers_test, 1}])
    end).

cover_test() ->
  yamq_test:run(
    fun(_) -> ok end,
    fun() ->
        yamq ! foo,
        yamq ! timeout,
        ok = sys:suspend(yamq),
        ok = sys:change_code(yamq, yamq, 0, []),
        ok = sys:resume(yamq),
        timer:sleep(100)
    end).

queue_test_() ->
  Daddy = self(),
  F = fun() ->
          yamq_test:run(
            fun(X) -> Daddy ! X, ok end,
            fun() ->
                L = lists:foldl(
                      fun(N, Acc) ->
                          P  = random:uniform(8),
                          D  = random:uniform(5000),
                          ok = yamq:enqueue({queue_test, N},P,D),
                          [{queue_test, N}|Acc]
                      end, [], lists:seq(1, 1000)),
                'receive'(L)
            end, [{'workers', 8}])
      end,
  {timeout, 30, F}.

init_test() ->
  {ok, _} = yamq_dets_store:start_link("x.dets"),
  lists:foreach(fun(N) ->
                    K  = s2_time:stamp(),
                    P  = random:uniform(8),
                    D  = random:uniform(1000),
                    ok = yamq_dets_store:put({K,P,D}, N)
                end, lists:seq(1, 100)),
  {ok, _} = yamq:start_link([{workers, 1},
                             {func, fun(_) -> ok end},
                             {store, yamq_dets_store}]),
  ok = yamq:stop(),
  ok = yamq_dets_store:stop().

crash_test() ->
  erlang:process_flag(trap_exit, true),
  {ok, Pid1} = yamq_dets_store:start_link("x.dets"),
  {ok, Pid2} = yamq:start_link([{workers, 4},
                                {func, fun(Msg) -> exit(Msg) end},
                                {store, yamq_dets_store}]),
  ok = yamq:enqueue(oh_no, 1),
  receive {'EXIT', Pid2, {worker_failed, oh_no}} -> ok end,
  ok = yamq_dets_store:stop(),
  receive {'EXIT', Pid1, normal} -> ok end,
  erlang:process_flag(trap_exit, false),
  ok.

store_fail_test() ->
  erlang:process_flag(trap_exit, true),
  {ok, _}    = yamq_dets_store:start_link("x.dets"),
  {ok, Pid}  = yamq:start_link([{workers, 4},
                                {func, fun(_) -> ok end},
                                {store, yamq_dets_store}]),
  ok         = yamq_dets_store:stop(),
  {error, _} = yamq:enqueue(store_fail_test, 1),
  receive {'EXIT', Pid, {store_failed, _}} -> ok end,
  erlang:process_flag(trap_exit, false),
  ok.

'receive'([]) -> ok;
'receive'(L) ->
  receive X ->
      ?hence(lists:member(X, L)),
      'receive'(L -- [X])
  end.

receive_in_order(L) ->
  lists:foreach(fun(X) -> X = receive Y -> Y end end, L).

-endif.

%%%_* Emacs ============================================================
%%% Local Variables:
%%% allout-layout: t
%%% erlang-indent-level: 2
%%% End:
