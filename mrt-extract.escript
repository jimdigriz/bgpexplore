#!/usr/bin/env escript
%% -*- erlang -*-
%%! -smp enable

-mode(compile).

main([RIS]) ->
	io:format("cidr\tpath~n", []),
	{ok, F} = file:open(RIS, [read,raw,compressed,binary]),
	main(<<>>, F).

% https://tools.ietf.org/html/rfc6396#section-2
main(<<_Timestamp:32/signed, Type:16, SubType:16, Length:32, Message:Length/binary, Rest/binary>>, F) when Type == 13 ->	% TABLE_DUMP_V2
	main2(Message, SubType, Rest, F);
main(<<_Timestamp:32/signed, _Type:16, _SubType:16, Length:32, _Message:Length/binary, Rest/binary>>, F) ->
	main(Rest, F);
main(Rest0, F) ->
	case file:read(F, 64 * 1024) of
		{ok, Rest} ->
			main(<<Rest0/binary, Rest/binary>>, F);
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
main2(<<_Sequence:32, PrefixLength:8, Rest0/binary>>, SubType, RestM, F) when SubType == 2 -> % RIB_IPV4_UNICAST
	PrefixPadLength = if PrefixLength rem 8 > 0 -> 8 - (PrefixLength rem 8); true -> 0 end,
	<<Prefix0:PrefixLength, _PrefixPad:PrefixPadLength, _EntryCount:16, Rest/binary>> = Rest0,
	Prefix1 = Prefix0 bsl (32 - PrefixLength),
	Prefix = list_to_tuple([(Prefix1 bsr X) rem 256 || X <- lists:seq(32 - 8, -1, -8)]),
	main3(Rest, Prefix, PrefixLength, RestM, F);
main2(<<_Sequence:32, PrefixLength:8, Rest0/binary>>, SubType, RestM, F) when SubType == 4 -> % RIB_IPV6_UNICAST
	PrefixPadLength = if PrefixLength rem 8 > 0 -> 8 - (PrefixLength rem 8); true -> 0 end,
	<<Prefix0:PrefixLength, _PrefixPad:PrefixPadLength, _EntryCount:16, Rest/binary>> = Rest0,
	Prefix1 = Prefix0 bsl (128 - PrefixLength),
	Prefix = list_to_tuple([(Prefix1 bsr X) rem 65536 || X <- lists:seq(128 - 16, -1, -16)]),
	main3(Rest, Prefix, PrefixLength, RestM, F);
main2(_Message, _SubType, RestM, F) ->
	main(RestM, F).

% https://tools.ietf.org/html/rfc6396#section-4.3.4
main3(<<_PeerIndex:16, _OriginatedTime:32/signed, AttributeLength:16, BGPAttributes:AttributeLength/binary, Rest/binary>>, Prefix, PrefixLength, RestM, F) ->
	main4(BGPAttributes, Prefix, PrefixLength, Rest, RestM, F);
main3(<<>>, _Prefix, _PrefixLength, RestM, F) ->
	main(RestM, F).

% https://tools.ietf.org/html/rfc4271#section-4.3
main4(<<_AFOpt:1, _AFTrans:1, _AFPartial:1, AFExtLen:1, _AFRest:4, AttrType:8, Rest0/binary>>, Prefix, PrefixLength, RestMM, RestM, F) ->
	LengthSize = 8 * (1 + AFExtLen),
	<<Length:LengthSize, Rest1/binary>> = Rest0,
	<<Attr:Length/binary, Rest/binary>> = Rest1,
	main5(AttrType, Attr, Prefix, PrefixLength, Rest, RestMM, RestM, F);
main4(<<>>, Prefix, PrefixLength, RestMM, RestM, F) ->
	main3(RestMM, Prefix, PrefixLength, RestM, F).

main5(AttrType, Attr, Prefix, PrefixLength, RestMMM, RestMM, RestM, F) when AttrType == 2 -> % AS_PATH
	main6(Attr, Prefix, PrefixLength, RestMMM, RestMM, RestM, F);
main5(_AttrType, _Attr, Prefix, PrefixLength, RestMMM, RestMM, RestM, F) ->
	main4(RestMMM, Prefix, PrefixLength, RestMM, RestM, F).

main6(<<PSType:8, PSLen0:8, Rest0/binary>>, Prefix, PrefixLength, RestMMM, RestMM, RestM, F) ->
	PSLen = 4 * PSLen0,
	<<PSVal:PSLen/binary, Rest/binary>> = Rest0,
	main7(PSType, PSLen, PSVal, Prefix, PrefixLength, Rest, RestMMM, RestMM, RestM, F);
main6(<<>>, Prefix, PrefixLength, RestMMM, RestMM, RestM, F) ->
	main4(RestMMM, Prefix, PrefixLength, RestMM, RestM, F).

main7(PSType, PSLen, PSVal, Prefix, PrefixLength, RestMMMM, RestMMM, RestMM, RestM, F) when PSType == 2 -> % AS_SEQUENCE
	CIDR = [ inet:ntoa(Prefix), "/", integer_to_list(PrefixLength) ],
	ASPath = lists:join(":", lists:map(fun(P) ->
		X0 = binary:part(PSVal, {P, 4}),
		<<X:32>> = X0,
		integer_to_list(X)
	end, lists:seq(0, PSLen - 1, 4))),
	io:format("~s\t~s~n", [CIDR, ASPath]),
	main6(RestMMMM, Prefix, PrefixLength, RestMMM, RestMM, RestM, F);
main7(_PSType, _PSLen, _PSVal, Prefix, PrefixLength, RestMMMM, RestMMM, RestMM, RestM, F) ->
	main6(RestMMMM, Prefix, PrefixLength, RestMMM, RestMM, RestM, F).
