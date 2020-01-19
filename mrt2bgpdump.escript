#!/usr/bin/env escript
%% -*- erlang -*-
%%! -smp enable

% when trying to improve the speed of the decoder you can use the
% following for hints though it is actually stdout that is slow
% env ERL_COMPILER_OPTIONS=bin_opt_info ./mrt2bgpdump.escript ris-data/bview.20191101.0000.06.gz | head -n30

-mode(compile).

-record(state, {
	file			:: file:fd(),
	id			:: inet:ip4_address(),
	peers		= []	:: list(peer()) | array:array(peer())
}).

-define(TABLE_DUMP_V2, 13).

-define(PEER_INDEX_TABLE, 1).
-record(peer, {
	id			:: inet:ip4_address(),
	ip			:: inet:ip_addres(),
	as			:: non_neg_integer()
}).
-type peer() :: #peer{}.

-define(RIB_IPV4_UNICAST, 2).
-define(RIB_IPV6_UNICAST, 4).
-record(rib, {
	peer_index		:: non_neg_integer(),
	timestamp		:: erlang:timestamp(),
	prefix			:: inet:ip_address(),
	prefix_len		:: non_neg_integer(),
	origin			:: igp | egp | incomplete,
	as_path		= []	:: list(list(pos_integer()) | {pos_integer()})
}).

-define(ORIGIN, 1).
-define(AS_PATH, 2).

-define(AS_SET, 1).
-define(AS_SEQUENCE, 2).

main([RIS]) ->
	{ok, F} = file:open(RIS, [read,raw,compressed,binary]),
	main(<<>>, #state{ file = F }).

% https://tools.ietf.org/html/rfc6396#section-2
main(<<Timestamp0:32/signed, Type:16, SubType:16, Length:32, Message:Length/binary, Rest/binary>>, State) when Type == ?TABLE_DUMP_V2 ->
	Timestamp = {Timestamp0 div 1000000, Timestamp0 rem 1000000, 0},
	main2(Message, Rest, State, #rib{ timestamp = Timestamp }, SubType);
main(<<_Timestamp:32/signed, _Type:16, _SubType:16, Length:32, _Message:Length/binary, Rest/binary>>, State) ->
	main(Rest, State);
main(Rest0, State = #state{ file = F }) ->
	case file:read(F, 64 * 1024) of
		{ok, Rest} ->
			main(<<Rest0/binary, Rest/binary>>, State);
		eof ->
			ok = file:close(F),
			halt(0);
		{error, X} ->
			io:fwrite(standard_error, "error: ~p~n", [X]),
			ok = file:close(F),
			halt(1)
	end.

% https://tools.ietf.org/html/rfc6396#section-4.3.2
% https://tools.ietf.org/html/rfc4760#section-5
main2(<<_Sequence:32, PrefixLength:8, Rest0/binary>>, RestM, State, RIB0, SubType) when SubType == ?RIB_IPV4_UNICAST ->
	PrefixPadLength = if PrefixLength rem 8 > 0 -> 8 - (PrefixLength rem 8); true -> 0 end,
	<<Prefix0:PrefixLength, _PrefixPad:PrefixPadLength, _EntryCount:16, Rest/binary>> = Rest0,
	Prefix = num2ip(Prefix0 bsl (32 - PrefixLength), 4),
	RIB = RIB0#rib{ prefix = Prefix, prefix_len = PrefixLength },
	main3(Rest, RestM, State, RIB);
main2(<<_Sequence:32, PrefixLength:8, Rest0/binary>>, RestM, State, RIB0, SubType) when SubType == ?RIB_IPV6_UNICAST ->
	PrefixPadLength = if PrefixLength rem 8 > 0 -> 8 - (PrefixLength rem 8); true -> 0 end,
	<<Prefix0:PrefixLength, _PrefixPad:PrefixPadLength, _EntryCount:16, Rest/binary>> = Rest0,
	Prefix = num2ip(Prefix0 bsl (128 - PrefixLength), 6),
	RIB = RIB0#rib{ prefix = Prefix, prefix_len = PrefixLength },
	main3(Rest, RestM, State, RIB);
% https://tools.ietf.org/html/rfc6396#section-4.3.1
main2(<<CollectorBGPID0:32, ViewNameLength:16, _ViewName:ViewNameLength/binary, _PeerCount:16, Rest/binary>>, RestM, State0, _RIB, SubType) when SubType == ?PEER_INDEX_TABLE ->
	CollectorBGPID = num2ip(CollectorBGPID0, 4),
	State = State0#state{ id = CollectorBGPID },
	main_peer(Rest, RestM, State);
main2(_Message, RestM, State, _RIB, _SubType) ->
	main(RestM, State).

% https://tools.ietf.org/html/rfc6396#section-4.3.4
main3(<<PeerIndex:16, _OriginatedTime:32/signed, AttributeLength:16, BGPAttributes:AttributeLength/binary, Rest/binary>>, RestM, State, RIB0) ->
	RIB = RIB0#rib{ peer_index = PeerIndex },
	main4(BGPAttributes, Rest, RestM, State, RIB);
main3(<<>>, RestM, State, _RIB) ->
	main(RestM, State).

% https://tools.ietf.org/html/rfc4271#section-4.3
main4(<<_AFOpt:1, _AFTrans:1, _AFPartial:1, AFExtLen:1, _AFRest:4, AttrType:8, Rest0/binary>>, RestMM, RestM, State, RIB) ->
	LengthSize = 8 * (1 + AFExtLen),
	<<Length:LengthSize, Rest1/binary>> = Rest0,
	<<Attr:Length/binary, Rest/binary>> = Rest1,
	main5(AttrType, Attr, Rest, RestMM, RestM, State, RIB);
main4(<<>>, RestMM, RestM, State, RIB) ->
	main3(RestMM, RestM, State, RIB).

main5(AttrType, <<Attr:8>>, RestMMM, RestMM, RestM, State, RIB) when AttrType == ?ORIGIN ->
	Origin = if Attr == 0 -> igp; Attr == 1 -> egp; true -> incomplete end,
	main4(RestMMM, RestMM, RestM, State, RIB#rib{ origin = Origin });
main5(AttrType, Attr, RestMMM, RestMM, RestM, State, RIB) when AttrType == ?AS_PATH ->
	main6(Attr, RestMMM, RestMM, RestM, State, RIB);
main5(_AttrType, _Attr, RestMMM, RestMM, RestM, State, RIB) ->
	main4(RestMMM, RestMM, RestM, State, RIB).

main6(<<PSType:8, PSLen0:8, Rest0/binary>>, RestMMM, RestMM, RestM, State, RIB) ->
	PSLen = 4 * PSLen0,
	<<PSVal:PSLen/binary, Rest/binary>> = Rest0,
	main7(PSType, PSLen, PSVal, Rest, RestMMM, RestMM, RestM, State, RIB);
main6(<<>>, RestMMM, RestMM, RestM, State, RIB) ->
	main8(RestMMM, RestMM, RestM, State, RIB).

main7(PSType, PSLen, PSVal, RestMMMM, RestMMM, RestMM, RestM, State, RIB0) when PSType == ?AS_SEQUENCE; PSType == ?AS_SET ->
	ASList = lists:map(fun(P) ->
		X0 = binary:part(PSVal, {P, 4}),
		<<X:32>> = X0,
		X
	end, lists:seq(0, PSLen - 1, 4)),
	ASPath = if
		PSType == ?AS_SET ->
			list_to_tuple(ASList);
		true ->
			ASList
	end,
	RIB = RIB0#rib{ as_path = [ASPath|RIB0#rib.as_path] },
	main6(RestMMMM, RestMMM, RestMM, RestM, State, RIB);
main7(_PSType, _PSLen, _PSVal, RestMMMM, RestMMM, RestMM, RestM, State, RIB) ->
	main6(RestMMMM, RestMMM, RestMM, RestM, State, RIB).

% TABLE_DUMP2|11/01/19 00:00:00|B|202.249.2.169|2497|16.105.113.0/24|2497 6461 15695 33383 {71,4445,7430,21302}|IGP
main8(RestMMM, RestMM, RestM, State, RIB0 = #rib{ origin = Origin0 }) ->
	Peer = array:get(RIB0#rib.peer_index, State#state.peers),
	{{Y,M,D},{HH,MM,SS}} = calendar:now_to_universal_time(RIB0#rib.timestamp),
	DateTime = io_lib:format("~2..0B/~2..0B/~2..0B ~2..0B:~2..0B:~2..0B", [M,D,Y rem 100,HH,MM,SS]),
	NextHop = inet:ntoa(Peer#peer.ip),
	ASNum = integer_to_list(Peer#peer.as),
	CIDR = [ inet:ntoa(RIB0#rib.prefix), "/", integer_to_list(RIB0#rib.prefix_len) ],
	ASPath = lists:join(" ", lists:reverse(lists:map(fun
		(X) when is_list(X) ->
			lists:join(" ", lists:map(fun integer_to_list/1, X));
		(X) when is_tuple(X) ->
			"{" ++ lists:join(",", lists:map(fun integer_to_list/1, tuple_to_list(X))) ++ "}"
	end, RIB0#rib.as_path))),
	Origin = if Origin0 == igp -> "IGP"; Origin0 == egp -> "EGP"; true -> "INCOMPLETE" end,
	Row = ["TABLE_DUMP2", DateTime, "B", NextHop, ASNum, CIDR, ASPath, Origin],
	io:put_chars(lists:join("|", Row) ++ "\n"),
	RIB = RIB0#rib{
		origin	= #rib{}#rib.origin,
		as_path	= #rib{}#rib.as_path
	},
	main4(RestMMM, RestMM, RestM, State, RIB).

main_peer(<<_PeerType:6, ASSize:1, IPFamily:1, PeerBGPID0:32, Rest0/binary>>, RestM, State0) ->
	PeerBGPID = num2ip(PeerBGPID0, 4),
	ASLen = if ASSize == 0 -> 16; true -> 32 end,
	IPLen = if IPFamily == 0 -> 32; true -> 128 end,
	<<PeerIPAddress0:IPLen, PeerAS:ASLen, Rest/binary>> = Rest0,
	PeerIPAddress = num2ip(PeerIPAddress0, if IPFamily == 0 -> 4; true -> 6 end),
	Peer = #peer{
		id	= PeerBGPID,
		as	= PeerAS,
		ip	= PeerIPAddress
	},
	State = State0#state{ peers = [Peer|State0#state.peers] },
	main_peer(Rest, RestM, State);
main_peer(<<>>, RestM, State) ->
	Peers = array:fix(array:from_list(lists:reverse(State#state.peers))),
	main(RestM, State#state{ peers = Peers }).

num2ip(N, 4) ->
	list_to_tuple([(N bsr X) rem 256 || X <- lists:seq(32 - 8, -1, -8)]);
num2ip(N, 6) ->
	list_to_tuple([(N bsr X) rem 65536 || X <- lists:seq(128 - 16, -1, -16)]).
