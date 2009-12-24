%%% 
%%% Copyright (c) 2007, 2008, 2009 JackNyfe, Inc. <info@jacknyfe.com>
%%% All rights reserved.
%%%
%%% Redistribution and use in source and binary forms, with or without
%%% modification, are permitted provided that the following conditions
%%% are met:
%%% 1. Redistributions of source code must retain the above copyright
%%%    notice, this list of conditions and the following disclaimer.
%%% 2. Redistributions in binary form must reproduce the above copyright
%%%    notice, this list of conditions and the following disclaimer in the
%%%    documentation and/or other materials provided with the distribution.
%%%
%%% THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
%%% ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
%%% IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
%%% ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
%%% FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
%%% DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
%%% OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
%%% HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
%%% LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
%%% OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
%%% SUCH DAMAGE.
%%% 
%%% This module uses memcached protocol to interface memcached daemon:
%%% http://code.sixapart.com/svn/memcached/trunk/server/doc/protocol.txt
%%%
%%% EXPORTS:
%%%     mcd:start_link()
%%%     mcd:start_link([Address])
%%%     mcd:start_link([Address, Port])
%%%
%%%  Simple API:
%%% 	mcd:get(Key)
%%% 	mcd:get(ServerRef, Key)
%%% 	mcd:set(Key, Data)
%%% 	mcd:set(ServerRef, Key, Data)
%%%
%%%  Generic API:
%%% 	mcd:do(ServerRef, SimpleRequest)
%%% 	mcd:do(ServerRef, KeyRequest, Key)
%%% 	mcd:do(ServerRef, KeyDataRequest, Key, Data)
%%%	Type
%%%             ServerRef = as defined in gen_server(3)
%%%		SimpleRequest = version | flush_all | {flush_all, Expiration}
%%%		KeyRequest = get | delete | {delete, Time}
%%%		KeyDataRequest = Command | {Command, Flags, Expiration}
%%%		Command = set | add | replace
%%%
%%% Client may also use gen_server IPC primitives to request this module to
%%% perform storage and retrieval. Primitives are described in gen_server(3),
%%% that is, gen_server:call, gen_server:cast and others, using ServerRef
%%% returned by start_link(). Example: gen_server:cast(Server, Query).
%%%
%%% Recognized queries:
%%%   {Command, Key, Data}
%%%   {Command, Key, Data, Flags, Expiration}
%%%   {get, Key}
%%%   {delete, Key}
%%%   {delete, Key, Time}
%%%   {incr, Key, Value}	% not implemented yet
%%%   {decr, Key, Value}	% not implemented yet
%%%   {version}
%%%   {flush_all}
%%%   {flush_all, Expiration}
%%% Return values:
%%%   {ok, Data}
%%%   {error, Reason}
%%% Where:
%%%   Command: set | add | replace
%%%   Key: term()
%%%   Data: term()
%%%   Flags: int()>=0
%%%   Expiration: int()>=0
%%%   Value: int()>=0
%%%   Time: int()>=0
%%%   Reason: notfound | overload | noconn | flushed
%%% 
-module(mcd).
-behavior(gen_server).

-export([start_link/0, start_link/1, start_link/2]).
-export([do/2, do/3, do/4]).
-export([ldo/1, ldo/2, ldo/3, ldo/5]).	%% do('localmcd', ...)
-export([get/1, get/2, set/2, set/3, set/5, async_set/3, async_set/5]).
-export([monitor/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Public API
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%
%% Start an anymous gen_server attached to a specified real memcached server.
%% Assumes localhost:11211 if no server address is given.
%%
start_link() -> start_link([]).
start_link([]) -> start_link(["127.0.0.1"]);
start_link([Address]) -> start_link([Address, 11211]);
start_link([Address, Port]) ->
	gen_server:start_link(?MODULE, [Address, Port], []).

%%
%% Start a named gen_server attached to a specified real memcached server.
%% Assumes localhost:11211 if no server address is given.
%%
start_link(Name, []) -> start_link(Name, ["127.0.0.1"]);
start_link(Name, [Address]) -> start_link(Name, [Address, 11211]);
start_link(Name, [Address, Port]) when is_atom(Name) ->
	gen_server:start_link({local, Name}, ?MODULE, [Address, Port], []).

%%
%% Call the specified memcached client gen_server with a request to ask
%% something from the associated real memcached process.
%%
%% The do/{2,3,4} is lighter than direct gen_server:call() to memcached
%% gen_server, since it spends some CPU in the requestor processes instead.
%%
%% See the file banner for possible requests.
%%
do(ServerRef, SimpleRequest) when is_atom(SimpleRequest) ->
	do_forwarder(call, ServerRef, {SimpleRequest});
do(ServerRef, SimpleRequest) when is_tuple(SimpleRequest) ->
	do_forwarder(call, ServerRef, SimpleRequest).

do(ServerRef, KeyRequest, Key) when is_atom(KeyRequest) ->
	do_forwarder(call, ServerRef, {KeyRequest, Key});
do(ServerRef, {KeyRequest}, Key) ->
	do_forwarder(call, ServerRef, {KeyRequest, Key}).

do(ServerRef, KeyDataReq, Key, Data) when is_atom(KeyDataReq) ->
	do_forwarder(call, ServerRef, {KeyDataReq, Key, Data});
do(ServerRef, {Cmd}, Key, Data) ->
	do_forwarder(call, ServerRef, {Cmd, Key, Data});
do(ServerRef, {Cmd, Flag, Expires}, Key, Data) ->
	do_forwarder(call, ServerRef, {Cmd, Key, Data, Flag, Expires}).

-define(LOCALMCDNAME, localmcd).
%%
%% The "ldo" is a "local do()". In our setup we assume that there is at least
%% one shared memcached running on the local host, named 'localmcd' (started by
%% an application supervisor process).
%% This call helps to avoid writing the mcd:do(localmcd, ...) code,
%% where using 'localmcd' string is prone to spelling errors.
%%
ldo(A) -> do(?LOCALMCDNAME, A).
ldo(A, B) -> do(?LOCALMCDNAME, A, B).
ldo(A, B, C) -> do(?LOCALMCDNAME, A, B, C).
ldo(set, Key, Data, Flag, Expires) ->
        do(?LOCALMCDNAME, {set, Flag, Expires}, Key, Data).

%% These helper functions provide more self-evident API.
get(Key) -> do(?LOCALMCDNAME, get, Key).
get(ServerRef, Key) -> do(ServerRef, get, Key).

set(Key, Data) -> do(?LOCALMCDNAME, set, Key, Data).
set(ServerRef, Key, Data) -> do(ServerRef, set, Key, Data).
set(ServerRef, Key, Data, Flags, Expiration) when is_integer(Flags), is_integer(Expiration), Flags >= 0, Flags < 65536, Expiration >= 0 -> do(ServerRef, {set, Flags, Expiration}, Key, Data).

async_set(ServerRef, Key, Data) ->
	do_forwarder(cast, ServerRef, {set, Key, Data}),
	Data.
async_set(ServerRef, Key, Data, Flags, Expiration) when is_integer(Flags), is_integer(Expiration), Flags >= 0, Flags < 65536, Expiration >= 0 ->
	do_forwarder(cast, ServerRef, {{set, Flags, Expiration}, Key, Data}),
	Data.

%%
%% Enroll a specified monitoring process (MonitorPid) to receive
%% notifications about memcached state transitions and other anomalies.
%% This call sets or replaces the previous set of items to monitor for.
%%
%% @spec monitor(ServerRef, MonitorPid, MonitorItems)
%% Type MonitorPid = pid() | atom()
%%      MonitorItems = [MonitorItem]
%%      MonitorItem = state | overload
%%
monitor(ServerRef, MonitorPid, MonitorItems) when is_list(MonitorItems) ->
	gen_server:call(ServerRef, {set_monitor, MonitorPid, MonitorItems});
monitor(ServerRef, MonitorPid, MonitorItem) when is_atom(MonitorItem) ->
	monitor(ServerRef, MonitorPid, [MonitorItem]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% gen_server callbacks
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state, { address, port = 11211, socket = nosocket,
	reqQ,			% queue to match responses with requests
	cont = nocont,		% current expectation continuation
	requests = 0,		% client requests initiated
	replies = 0,		% server replies received
	anomalies = {0, 0, 0},	% {queue overloads, reconnects, unused}
	status = disabled,	% connection status:
				%   disabled | ready
				%   | {connecting, Since, {Pid,MRef}}
				%   | {testing, Since}	% testing protocol
				%   | {wait, Since}	% wait between connects
	monitored_by = []	% monitoring processes to receive anomalies
	}).


init([Address, Port]) ->
	{ ok, reconnect(#state{
			address = Address,
			port = Port,
			reqQ = ets:new(memcached_queue, [set, private])
		})
	}.

handle_call(info, _From, State) ->
	#state{requests = QIN, replies = QOUT, anomalies = {QOV, REC, _},
		status = Status} = State,
	{reply,
		[{requests, QIN}, {replies, QOUT}, {overloads, QOV},
		{reconnects, REC}, {status, Status}],
	State};

handle_call({set_monitor, MonitorPid, Items}, _From, #state{monitored_by=CurMons} = State) ->
	MonRef = erlang:monitor(process, MonitorPid),
	NewMons = addMonitorPidItems(demonitorPid(CurMons, MonitorPid),
			MonitorPid, MonRef, Items),
	MonitoredItemsForPid = collectMonitoredItems(NewMons, MonitorPid),
	case MonitoredItemsForPid of
		[] -> erlang:demonitor(MonRef);
		_ -> ok
	end,
	{reply, MonitoredItemsForPid, State#state{monitored_by = NewMons}};

handle_call(Query, From, State) -> {noreply, scheduleQuery(State, Query, From)}.

handle_cast({connected, Pid, nosocket},
		#state{socket = nosocket,
			status = {connecting, _, {Pid,_}}} = State) ->
	{Since, ReconnectDelay} = compute_next_reconnect_delay(State),
	erlang:start_timer(ReconnectDelay, self(), { may, reconnect }),
	{noreply, State#state { status = {wait, Since} }};
handle_cast({connected, Pid, NewSocket},
		#state{socket = nosocket,
			status = {connecting, _, {Pid,_}}} = State) ->

	{Since, ReconnectDelay} = compute_next_reconnect_delay(State),

	ReqId = State#state.requests,

	% We ask for version information, which will set our status to ready
	{Socket, NewStatus} = case constructAndSendQuery(anon, {version},
				NewSocket, State#state.reqQ, ReqId) of
		ok -> {NewSocket, {testing, Since}};
		{ error, _ } ->
			gen_tcp:close(NewSocket),
			erlang:start_timer(ReconnectDelay, self(),
				{ may, reconnect }),
			{nosocket, {wait, Since}}
	end,

	% Remember this socket in a new state.
	{noreply, State#state { socket = Socket,
		status = NewStatus,
		requests = ReqId + 1,
		replies = ReqId
		}};

handle_cast({connected, _, nosocket}, State) -> {noreply, State};
handle_cast({connected, _, Socket}, State) ->
	gen_tcp:close(Socket),
	{noreply, State};
handle_cast(Query, State) -> {noreply, scheduleQuery(State, Query, anon)}.

handle_info({timeout, _, {may, reconnect}}, State) -> {noreply, reconnect(State)};
handle_info({tcp_closed, Socket}, #state{socket = Socket} = State) ->
	{noreply, reconnect(State#state{socket = nosocket})};
handle_info({tcp, Socket, Data}, #state{socket = Socket} = State) ->
	{noreply, handleMemcachedServerResponse(Data, State)};
handle_info({'DOWN', MonRef, process, Pid, _Info}, #state{status={connecting,_,{Pid,MonRef}}}=State) ->
	error_logger:info_msg("Memcached connector died (~p),"
			" simulating nosock~n", [_Info]),
	handle_cast({connected, Pid, nosocket}, State);
handle_info({'DOWN', MonRef, process, Pid, _Info}, #state{monitored_by=Mons}=State) ->
	{noreply, State#state{
		monitored_by = removeMonitorPidAndMonRef(Mons, Pid, MonRef)
		} };
handle_info(_Info, State) -> {noreply, State}.

code_change(_OldVsn, State, _Extra) -> {ok, State}.
terminate(_Reason, _State) -> ok.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Internal functions
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% Remove the specified pid from the lists of nodes monitoring this gen_server.
demonitorPid(Monitors, MonitorPid) ->
	[{Item, NewPids}
		|| {Item, PidRefs} <- Monitors,
		   NewPids <- [[PM || {P, MonRef} = PM <- PidRefs,
				erlang:demonitor(MonRef) == true,
				P /= MonitorPid]],
		   NewPids /= []
	].

removeMonitorPidAndMonRef(Monitors, Pid, MonRef) ->
	[{Item, NewPids}
		|| {Item, PidRefs} <- Monitors,
		   NewPids <- [[PM || {P, MR} = PM <- PidRefs,
				P /= Pid, MR /= MonRef]],
		   NewPids /= []
	].

% Add the specified pid to the lists of nodes monitoring this gen_server.
addMonitorPidItems(Monitors, MonitorPid, MonRef, Items) ->
	lists:foldl(fun(Item, M) ->
		addMonitorPidItem(M, MonitorPid, MonRef, Item)
	end, Monitors, Items).

addMonitorPidItem(Monitors, Pid, MonRef, I) when I == state; I == overload ->
	NewMons = [{Item, NewPids}
		|| {Item, Pids} <- Monitors,
		   NewPids <- [case Item of
				I -> [{Pid, MonRef} | Pids];
				_ -> Pids
				end]
	],
	case lists:keysearch(I, 1, NewMons) of
		false -> [{I, [{Pid, MonRef}]}|NewMons];
		{value, _} -> NewMons
	end;
addMonitorPidItem(Monitors, _Pid, _MonRef, _Item) -> Monitors.

reportEvent(#state{monitored_by = Mons} = State, Event, Info) ->
	[P ! {memcached, self(), Event, Info}
		|| {Item, Pids} <- Mons, Item == Event, {P, _} <- Pids],
	State.

% Figure out what items this pid monitors.
collectMonitoredItems(Monitors, MonitorPid) ->
	[Item || {Item, Pids} <- Monitors,
		lists:keysearch(MonitorPid, 1, Pids) /= false].

% @spec utime(now()) -> int()
utime({Mega, Secs, _}) -> 1000000 * Mega + Secs.

incrAnomaly({QOverloads, Reconnects, Unused}, overloads) ->
	{QOverloads + 1, Reconnects, Unused};
incrAnomaly({QOverloads, Reconnects, Unused}, reconnects) ->
	{QOverloads, Reconnects + 1, Unused};
incrAnomaly(Anomaly, FieldName) ->
	error_logger:error_msg("Anomaly ~p couldn't be increased in ~p~n",
		[FieldName, Anomaly]),
	Anomaly.

%% Destroy the existing connection and create a new one based on State params
%% @spec reconnect(record(state)) -> record(state)
reconnect(#state{status = {connecting, _, {_Pid,_MRef}}} = State) ->
	% Let the reconnect process continue.
	State;
reconnect(#state{address = Address, port = Port, socket = OldSock} = State) ->
	% Close the old socket, if available
	case OldSock of
		nosocket -> ok;
		_ -> gen_tcp:close(OldSock)
	end,

        % XXX: report an error and terminate if we can't connect for too
        % long?

	Self = self(),
	{Pid,MRef} = spawn_monitor(fun() ->
			reconnector_process(Self, Address, Port) end),

	% We want to reconnect but we can't do it immediately, since
	% the tcp connection could be failing right after connection.
	% So let it cook for a period of time before the next retry.
	{Since, _ReconnectDelay} = compute_next_reconnect_delay(State),

	% Remove everything from the queue and report errors to requesters.
	flushRequestsQueue(State#state.reqQ),

	NewAnomalies = case is_atom(State#state.status) of
		false -> State#state.anomalies;
		true -> 
			reportEvent(State, state, down),
			incrAnomaly(State#state.anomalies, reconnects)
	end,

	State#state { socket = nosocket,
		cont = nocont,
		status = {connecting, Since, {Pid, MRef}},
		replies = State#state.requests,	% Reply wait queue flushed
		anomalies = NewAnomalies }.

compute_next_reconnect_delay(#state{status = Status}) ->
	ComputeReconnectDelay = fun(Since) ->
		% Wait increasingly longer,
		% but no longer than 5 minutes.
		case (utime(now()) - utime(Since)) of
			N when N > 300 -> 300 * 1000;
			N -> N * 1000
		end
	end,
	case Status of
		{connecting, Since, _} -> {Since, ComputeReconnectDelay(Since)};
		{testing, Since} -> {Since, ComputeReconnectDelay(Since)};
		{wait, Since} -> {Since, ComputeReconnectDelay(Since)};
		_ -> {now(), 1000}
	end.

reconnector_process(MCDServerPid, Address, Port) ->
	error_logger:info_msg("Creating interface ~p to memcached on ~p:~p~n",
          [MCDServerPid, Address,Port]),

	Socket = case gen_tcp:connect(Address, Port,
			[binary, {packet, line}], 5000) of
		{ ok, Sock } ->
			gen_tcp:controlling_process(Sock, MCDServerPid),
			Sock;
		{ error, _Reason } -> nosocket
	end,
	gen_server:cast(MCDServerPid, {connected, self(), Socket}).


% Remove all the requests from the queue, and report errors to originators.
flushRequestsQueue([]) -> ok;
flushRequestsQueue([{_ReqId, From, _, _}|Objects]) ->
	replyBack(From, {error, flushed}),
	flushRequestsQueue(Objects);
flushRequestsQueue(Tab) ->
	flushRequestsQueue(ets:tab2list(Tab)),
	ets:delete_all_objects(Tab).

%%
%% Send a query to the memcached server and add it to our local table
%% to capture corresponding server response.
%% This asynchronous process provides necessary pipelining for remote or
%% lagging memcached processes.
%%

scheduleQuery(#state{requests = QIN, replies = QOUT, reqQ = Tab, socket = Socket, status = ready} = State, Query, From) when QIN - QOUT < 1024 ->
	case constructAndSendQuery(From, Query, Socket, Tab, QIN) of
		ok -> State#state{requests = QIN + 1};
		{error, _Reason} -> reconnect(State)
	end;
scheduleQuery(State, _Query, From) ->
	#state{requests = REQ, replies = REPL, anomalies = An, status = Status} = State,
	if
		REQ - REPL >= 1024 ->
			replyBack(From, {error, overload}),
			reportEvent(State, overload, []),
			State#state{anomalies = incrAnomaly(An, overloads)};
		Status =/= ready ->
			replyBack(From, {error, noconn}),
			State
	end.

constructAndSendQuery(From, {'$constructed_query', _KeyMD5, {OTARequest, ReqType, ExpectationFlags}}, Socket, Tab, ReqId) ->
	ets:insert(Tab, {ReqId, From, ReqType, ExpectationFlags}),
	gen_tcp:send(Socket, OTARequest);
constructAndSendQuery(From, Query, Socket, Tab, ReqId) ->
	{_MD5Key, OTARequest, ReqType} = constructMemcachedQuery(Query),
	ets:insert(Tab, {ReqId, From, ReqType, []}),
	gen_tcp:send(Socket, OTARequest).

%%
%% Format the request and call the server synchronously
%% or cast a message asynchronously, without waiting for the result.
%%
do_forwarder(Method, ServerRef, Req) ->
	{KeyMD5, IOL, T} = constructMemcachedQuery(Req),
	Q = iolist_to_binary(IOL),
	case gen_server:Method(ServerRef,
			{'$constructed_query', KeyMD5, {Q, T, [raw_blob]}}) of

		% Return the actual Data piece which got stored on the
		% server. Since returning Data happens inside the single
		% process, this has no copying overhead and is nicer than
		% returning {ok, stored} to successful set/add/replace commands.
		{ok, stored} when T == rtCmd -> {ok, element(3, Req)};

		% Memcached returns a blob which needs to be converted
		% into to an Erlang term. It's better to do it in the requester
		% process space to avoid inter-process copying of potentially
		% complex data structures.
		{ok, {'$value_blob', B}} -> {ok, binary_to_term(B)};

		Response -> Response
	end.

%% Convert arbitrary Erlang term into memcached key
%% @spec md5(term()) -> binary()
%% @spec b64(binary()) -> binary()
md5(Key) -> erlang:md5(term_to_binary(Key)).
b64(Key) -> base64:encode(Key).

%% Translate a query tuple into memcached protocol string and the
%% atom suggesting a procedure for parsing memcached server response.
%%
%% @spec constructMemcachedQuery(term()) -> {md5(), iolist(), ResponseKind}
%% Type ResponseKind = atom()
%%
constructMemcachedQuery({version}) -> {<<>>, [<<"version\r\n">>], rtVer};
constructMemcachedQuery({set, Key, Data}) ->
	constructMemcachedQueryCmd("set", Key, Data);
constructMemcachedQuery({set, Key, Data, Flags, Expiration}) ->
	constructMemcachedQueryCmd("set", Key, Data, Flags, Expiration);
constructMemcachedQuery({add, Key, Data}) ->
	constructMemcachedQueryCmd("add", Key, Data);
constructMemcachedQuery({add, Key, Data, Flags, Expiration}) ->
	constructMemcachedQueryCmd("add", Key, Data, Flags, Expiration);
constructMemcachedQuery({replace, Key, Data}) ->
	constructMemcachedQueryCmd("replace", Key, Data);
constructMemcachedQuery({replace, Key, Data, Flags, Expiration}) ->
	constructMemcachedQueryCmd("replace", Key, Data, Flags, Expiration);
constructMemcachedQuery({get, Key}) ->
	MD5Key = md5(Key),
	{MD5Key, ["get ", b64(MD5Key), "\r\n"], rtGet};
constructMemcachedQuery({delete, Key, Time}) when is_integer(Time), Time > 0 ->
	MD5Key = md5(Key),
	{MD5Key, ["delete ", b64(MD5Key), " ", integer_to_list(Time), "\r\n"], rtDel};
constructMemcachedQuery({delete, Key}) ->
	MD5Key = md5(Key),
	{MD5Key, ["delete ", b64(MD5Key), "\r\n"], rtDel};
constructMemcachedQuery({incr, Key, Value})
		when is_integer(Value), Value >= 0 ->
	MD5Key = md5(Key),
	{MD5Key, ["incr ", b64(MD5Key), " ", integer_to_list(Value), "\r\n"], rtInt};
constructMemcachedQuery({decr, Key, Value})
		when is_integer(Value), Value >= 0 ->
	MD5Key = md5(Key),
	{MD5Key, ["decr ", b64(MD5Key), " ", integer_to_list(Value), "\r\n"], rtInt};
constructMemcachedQuery({flush_all, Expiration})
		when is_integer(Expiration), Expiration >= 0 ->
	{<<>>, ["flush_all ", integer_to_list(Expiration), "\r\n"], rtFlush};
constructMemcachedQuery({flush_all}) -> {<<>>, ["flush_all\r\n"], rtFlush}.

%% The "set", "add" and "replace" queries do get optional
%% "flag" and "expiration time" attributes. So these commands fall into
%% their own category of commands (say, ternary command). These commads'
%% construction is handled by this function.
%%
%% @spec constructMemcachedQuery(term()) -> {md5(), iolist(), ResponseKind}
%% Type ResponseKind = atom()
%%
constructMemcachedQueryCmd(Cmd, Key, Data) ->
	constructMemcachedQueryCmd(Cmd, Key, Data, 0, 0).
constructMemcachedQueryCmd(Cmd, Key, Data, Flags, Exptime)
	when is_list(Cmd), is_integer(Flags), is_integer(Exptime),
	Flags >= 0, Flags < 65536, Exptime >= 0 ->
	BinData = term_to_binary(Data),
	MD5Key = md5(Key),
	{MD5Key, [Cmd, " ", b64(MD5Key), " ", integer_to_list(Flags), " ",
		integer_to_list(Exptime), " ",
		integer_to_list(size(BinData)),
		"\r\n", BinData, "\r\n"], rtCmd}.

handleMemcachedServerResponse(Data,
	#state{requests = QIN, replies = QOUT, reqQ = Tab, cont = Cont} = State
    ) when QIN =/= QOUT ->
	{From, Continuation} = case Cont of
	  nocont ->
		Expectation = genResponseExpectation(ets:lookup(Tab, QOUT)),
		ets:delete(Tab, QOUT),
		Expectation;
	  ExistingExpectation -> ExistingExpectation
	end,
	% How this works: we have a continuation (closure) which
	% knows what this request expects. If continuation wants
	% additional data, it'll ask. If continuation is finished,
	% it'll report that fact.
	case Continuation(Data) of
		{more, NewCont} ->
			State#state{cont = {From, NewCont}};
		Result ->
			replyBack(From, Result),
			State#state{replies = QOUT + 1, cont = nocont,
				status = case State#state.status of
					ready -> ready;
					_ -> reportEvent(State, state, up),
						ready
				end
			}
	end.

%%
%% An expectation is a tuple describing how to parse server response and
%% where to forward it.
%%
%% @spec genResponseExpectation([ExpectationDescriptor]) -> Expectation
%% Type ExpectationDescriptor = {RequestId, From, ReqType, [ExpectationFlag]}
%%	ExpectationFlag = raw_blob
%% 	Expectation = {From, fun()}
%%      ReqType = atom()
%%      From = anon | {pid(), Tag}
%%
genResponseExpectation([{_RequestId, From, ReqType, ExpectationFlags}]) ->
	{ From, expectationByRequestType(ReqType, ExpectationFlags) }.

%% Generate a server response expectation closure, according to the
%% request type.
%% The request type actually maps to the server response structure.
%% @spec expectationByRequestType(atom()) -> fun()
expectationByRequestType(rtVer, _) ->
	mkExpectKeyValue("VERSION");
expectationByRequestType(rtGet, ExpFlags) ->
	mkAny([mkExpectEND({error, notfound}), mkExpectValue(ExpFlags)]);
expectationByRequestType(rtDel, _) ->
	mkAny([mkExpectResp(<<"DELETED\r\n">>, {ok, deleted}),
		mkExpectResp(<<"NOT_FOUND\r\n">>, {error, notfound})]);
expectationByRequestType(rtCmd, _) ->
	mkAny([mkExpectResp(<<"STORED\r\n">>, {ok, stored}),
		mkExpectResp(<<"NOT_STORED\r\n">>, {error, notstored})]);
expectationByRequestType(rtFlush, _) -> mkExpectResp(<<"OK\r\n">>, {ok, flushed}).

replyBack(anon, _) -> true;
replyBack(From, Result) -> gen_server:reply(From, Result).

%% A combinator over potential response handler closure
mkAny(RespFuns) -> fun (Data) -> mkAnyF(RespFuns, Data, unexpected) end.
mkAnyF([], _Data, Error) -> { error, Error };
mkAnyF([RespFun|Rs], Data, _Error) ->
	case RespFun(Data) of
		{ error, notfound } -> {error, notfound};
		{ error, Reason } -> mkAnyF(Rs, Data, Reason);
		Other -> Other
	end.

%% Creates a closure which expects a particular reply in response
mkExpectResp(Bin, Response) -> fun
	(Data) when Bin == Data -> Response;
	(_Data) -> {error, unexpected}
    end.

mkExpectEND(Result) -> mkExpectResp(<<"END\r\n">>, Result).

mkExpectValue(ExpFlags) -> fun (Data) ->
	Tokens = string:tokens(erlang:binary_to_list(Data), [$ , $\r, $\n]),
	case Tokens of
		["VALUE", _Key, _Flags, BytesString] ->
			Bytes = list_to_integer(BytesString),
			{ more, mkExpectData(Bytes, ExpFlags) };
		_ -> {error, unexpected}
	end end.

mkExpectKeyValue(Key) when is_list(Key) -> fun (Data) ->
	Tokens = string:tokens(erlang:binary_to_list(Data), [$ , $\r, $\n]),
	case Tokens of
		[Key, Value] -> {ok, Value};
		_ -> {error, unexpected}
	end end.

mkExpectData(Bytes, ExpFlags) when is_integer(Bytes), Bytes >= 0 ->
	mkExpectData([], Bytes, Bytes+2, ExpFlags).
mkExpectData(AlreadyHave, Bytes, ToGo, ExpFlags) ->
  fun(Data) ->
	DataSize = iolist_size(Data),
	if
		DataSize == ToGo ->
			I = lists:reverse(AlreadyHave, [Data]),
			B = iolist_to_binary(I),
			V = case proplists:get_value(raw_blob, ExpFlags) of
				true -> {'$value_blob', B};
				_ -> binary_to_term(B)
			end,
			{ more, mkExpectEND({ ok, V })};
		DataSize < ToGo -> { more, mkExpectData([Data | AlreadyHave],
				Bytes, ToGo - DataSize, ExpFlags) }
	end
  end.
