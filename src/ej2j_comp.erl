%% Oleg Smirnov <oleg.smirnov@gmail.com>
%% @doc XMPP Component

-module(ej2j_comp).

-behaviour(gen_server).

-export([start_link/0, stop/0, start_client/3]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2,
	 code_change/3]).

-include_lib("exmpp/include/exmpp_client.hrl").
-include_lib("exmpp/include/exmpp_xml.hrl").
-include_lib("exmpp/include/exmpp_nss.hrl").
-include_lib("exmpp/include/exmpp_jid.hrl").

-include("ej2j.hrl").

-record(state, {session, db}).

%% Public API

-spec start_link() -> {ok, pid()}.
start_link() ->
    gen_server:start_link({local,?MODULE}, ?MODULE, [], []).

-spec stop() -> ok.
stop() ->
    gen_server:call(?MODULE, stop).

-spec start_client(tuple(), list(), list()) -> ok.
start_client(OwnerJID, ForeignJID, Password) ->
    gen_server:call(?MODULE, {start_client, OwnerJID, ForeignJID, Password}).

get_routes(FromJID, ToJID) ->
    gen_server:call(?MODULE, {get_routes, FromJID, ToJID}).

%% gen_server callbacks

-spec init([]) -> {ok, #state{}}.
init([]) ->
    process_flag(trap_exit, true),
    Session = ej2j_helper:component(),
    {ok, #state{session = Session, db = ej2j_route:init()}}.

-spec handle_call(any(), any(), #state{}) -> {reply, any(), #state{}} | {stop, any(), any(), #state{}}.
handle_call(stop, _From, State) ->
    exmpp_component:stop(State#state.session),
    {stop, normal, ok, State};

handle_call({start_client, FromJID, ForeignJID, Password}, _From, #state{db=DB, session=ServerS} = State) ->
    try
	{ToJID, ClientS} = client_spawn(ForeignJID, Password),
	NewDB = ej2j_route:add(DB, {FromJID, ToJID, ClientS, ServerS}),
	{reply, ClientS, State#state{db = NewDB}}
    catch
	_Class:_Error -> {reply, false, State}
    end;

handle_call({get_routes, FromJID, ToJID}, _From, #state{db=DB} = State) ->
    Routes = ej2j_route:get(DB, FromJID, ToJID),
    {reply, Routes, State};

handle_call(_Msg, _From, State) ->
    {reply, unexpected, State}.

-spec handle_info(any(), #state{}) -> {noreply, #state{}}.
handle_info(#received_packet{} = Packet, #state{session=S} = State) ->
    spawn_link(fun() -> process_received_packet(S, Packet) end),
    {noreply, State};

handle_info(#received_packet{packet_type=Type, raw_packet=Packet}, State) ->
    error_logger:warning_msg("Unknown packet received(~p): ~p~n", [Type, Packet]),
    {noreply, State};

handle_info({'EXIT', Pid, _}, #state{db=DB} = State) ->
    NewDB = ej2j_route:del(DB, Pid),
    {noreply, State#state{db = NewDB}};

handle_info(_Msg, State) ->
    {noreply, State}.

-spec handle_cast(any(), #state{}) -> {noreply, #state{}}.
handle_cast(_Msg, State) ->
    {noreply, State}.

-spec terminate(any(), #state{}) -> any().
terminate(_Reason, _State) ->
    ok.

-spec code_change(any(), any(), any()) -> {ok, any()}.
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% Process received packet

-spec process_received_packet(any(), #received_packet{}) -> ok.
process_received_packet(Session, #received_packet{packet_type = 'iq'} = Packet) ->
    #received_packet{type_attr=Type, raw_packet = IQ} = Packet,
    NS = exmpp_xml:get_ns_as_atom(exmpp_iq:get_payload(IQ)),
    process_iq(Session, Type, NS, IQ);

process_received_packet(Session, #received_packet{packet_type = 'presence'} = Packet) ->
    #received_packet{raw_packet = Presence} = Packet,
    process_presence(Session, Presence);

process_received_packet(Session, #received_packet{packet_type = 'message'} = Packet) ->
    #received_packet{raw_packet = Message} = Packet,
    process_message(Session, Message).

%% Process stanza

-spec process_iq(pid(), any(), atom(), #xmlel{}) -> ok.
process_iq(Session, "get", ?NS_DISCO_INFO, IQ) ->
    Result = exmpp_iq:result(IQ, ej2j_helper:disco_info()),
    send_packet(Session, Result);

process_iq(Session, "get", ?NS_DISCO_ITEMS, IQ) ->
    Result = exmpp_iq:result(IQ, exmpp_xml:element(?NS_DISCO_ITEMS, 'query', [], [])),
    send_packet(Session, Result);

process_iq(_Session, _Type, ?NS_ROSTER, IQ) ->
    Roster = exmpp_xml:get_element_by_ns(IQ, 'jabber:iq:roster'),
    Items = exmpp_xml:get_elements(Roster, 'item'),
    ModItems = lists:map(fun(X) -> Jid = exmpp_jid:parse(exmpp_xml:get_attribute(X, <<"jid">>, "")), 
               exmpp_xml:element(?NS_ROSTER, 'item', [
               exmpp_xml:attribute(<<"jid">>,
                    case string:chr(exmpp_jid:prep_to_list(Jid), $%) of
                       0 ->
                         binary:list_to_bin(exmpp_jid:node_as_list(Jid) ++ "%" ++ exmpp_jid:domain_as_list(Jid) ++ "@" ++ 
                            ej2j:get_app_env(component, ?COMPONENT));
                       _Else ->
                         exmpp_xml:get_attribute(X, <<"jid">>, "")
                    end
               ),
               exmpp_xml:attribute(<<"subscription">>,exmpp_xml:get_attribute(X, <<"subscription">>, ""))],[])
               end, Items),
    NewRoster = exmpp_xml:set_children(Roster, ModItems),
    send_packet(_Session, exmpp_iq:result(IQ, NewRoster));

process_iq(Session, "get", ?NS_INBAND_REGISTER, IQ) ->
    Result = exmpp_iq:result(IQ, ej2j_helper:inband_register()),
    send_packet(Session, Result);

process_iq(Session, "set", ?NS_INBAND_REGISTER, IQ) ->
    SenderJID = exmpp_jid:parse(exmpp_stanza:get_sender(IQ)),
    try
	Form = ej2j_helper:form_parse(exmpp_xml:get_element(exmpp_iq:get_payload(IQ), ?NS_DATA_FORMS, 'x')),
	JID = ej2j_helper:form_field(Form, <<"jid">>),
	Password = ej2j_helper:form_field(Form, <<"password">>),
	UserSession = start_client(SenderJID, JID, Password),
        exmpp_session:login(UserSession),
        Status = exmpp_presence:set_status(exmpp_presence:available(), undefined),
        Roster = exmpp_client_roster:get_roster(),
        send_packet(Session, exmpp_iq:result(IQ)),
    catch
        _Class:_Error ->
	    send_packet(Session, exmpp_iq:error(IQ, forbidden))
    end;

process_iq(_Session, _Type, _NS, IQ) ->
    process_generic(IQ).

-spec process_presence(pid(), #xmlel{}) -> ok.
process_presence(_Session, Presence) ->
    process_generic(Presence).

-spec process_message(pid(), #xmlel{}) -> ok.
process_message(_Session, Message) ->
    process_generic(Message).

-spec process_generic(#xmlel{}) -> ok.
process_generic(Packet) ->
    From = exmpp_jid:parse(exmpp_stanza:get_sender(Packet)),
    To = exmpp_jid:parse(exmpp_stanza:get_recipient(Packet)),
    Routes = get_routes(From, To),
    route_packet(Routes, Packet).

-spec route_packet(list(), #xmlel{}) -> ok.
route_packet([{{client, Session}, NewFrom, NewTo}|Tail], Packet) ->
    Tmp = exmpp_stanza:set_sender(Packet, NewFrom),
    NewPacket = exmpp_stanza:set_recipient(Tmp, NewTo),
    exmpp_session:send_packet(Session, NewPacket),
    route_packet(Tail, Packet);
route_packet([{{server, Session}, NewFrom, NewTo}|Tail], Packet) ->
    Tmp = exmpp_stanza:set_sender(Packet, NewFrom),
    NewPacket = exmpp_stanza:set_recipient(Tmp, NewTo),
    send_packet(Session, NewPacket),
    route_packet(Tail, Packet);    
route_packet([], _Packet) ->
    ok.

%% Various helpers

-spec send_packet(pid(), #xmlel{}) -> ok.
send_packet(Session, El) ->
    exmpp_component:send_packet(Session, El).

-spec client_spawn(list(), list()) -> {tuple(), pid()} | false.
client_spawn(JID, Password) ->
    try
	[User, Domain] = string:tokens(JID, "@"),
	FullJID = exmpp_jid:make(User, Domain, random),
	Session = exmpp_session:start_link(),
	exmpp_session:auth_info(Session, FullJID, Password),
	exmpp_session:auth_method(Session, digest),
	{ok, _StreamId} = exmpp_session:connect_TCP(Session, Domain, 5222),
	{FullJID, Session}
    catch
	_Class:_Error -> false
    end.
