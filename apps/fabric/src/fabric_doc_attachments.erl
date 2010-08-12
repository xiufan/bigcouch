-module(fabric_doc_attachments).

-include("fabric.hrl").

%% couch api calls
-export([receiver/2]).

receiver(_Req, undefined) ->
    <<"">>;
receiver(_Req, {unknown_transfer_encoding, Unknown}) ->
    exit({unknown_transfer_encoding, Unknown});
receiver(Req, chunked) ->
    MiddleMan = spawn(fun() -> middleman(Req, chunked) end),
    fun(4096, ChunkFun, ok) ->
        write_chunks(MiddleMan, ChunkFun)
    end;
receiver(_Req, 0) ->
    <<"">>;
receiver(Req, Length) when is_integer(Length) ->
    Middleman = spawn(fun() -> middleman(Req, Length) end),
    fun() ->
        Middleman ! {self(), gimme_data},
        receive {Middleman, Data} -> Data end
    end;
receiver(_Req, Length) ->
    exit({length_not_integer, Length}).

%%
%% internal
%%

write_chunks(MiddleMan, ChunkFun) ->
    MiddleMan ! {self(), gimme_data},
    receive
    {MiddleMan, {0, _Footers}} ->
        % MiddleMan ! {self(), done},
        ok;
    {MiddleMan, ChunkRecord} ->
        ChunkFun(ChunkRecord, ok),
        write_chunks(MiddleMan, ChunkFun)
    end.

receive_unchunked_attachment(_Req, 0) ->
    ok;
receive_unchunked_attachment(Req, Length) ->
    receive {MiddleMan, go} ->
        Data = couch_httpd:recv(Req, 0),
        MiddleMan ! {self(), Data}
    end,
    receive_unchunked_attachment(Req, Length - size(Data)).

middleman(Req, chunked) ->
    % spawn a process to actually receive the uploaded data
    RcvFun = fun(ChunkRecord, ok) ->
        receive {From, go} -> From ! {self(), ChunkRecord} end, ok
    end,
    Receiver = spawn(fun() -> couch_httpd:recv_chunked(Req,4096,RcvFun,ok) end),

    % take requests from the DB writers and get data from the receiver
    N = erlang:list_to_integer(couch_config:get("cluster","n")),
    middleman_loop(Receiver, N, dict:new(), 0, []);

middleman(Req, Length) ->
    Receiver = spawn(fun() -> receive_unchunked_attachment(Req, Length) end),
    N = erlang:list_to_integer(couch_config:get("cluster","n")),
    middleman_loop(Receiver, N, dict:new(), 0, []).

middleman_loop(Receiver, N, Counters, Offset, ChunkList) ->
    receive {From, gimme_data} ->
        % figure out how far along this writer (From) is in the list
        {NewCounters, WhichChunk} = case dict:find(From, Counters) of
        {ok, I} ->
            {dict:update_counter(From, 1, Counters), I};
        error ->
            {dict:store(From, 2, Counters), 1}
        end,
        ListIndex = WhichChunk - Offset,

        % talk to the receiver to get another chunk if necessary
        ChunkList1 = if ListIndex > length(ChunkList) ->
            Receiver ! {self(), go},
            receive {Receiver, ChunkRecord} -> ChunkList ++ [ChunkRecord] end;
        true -> ChunkList end,

        % reply to the writer
        From ! {self(), lists:nth(ListIndex, ChunkList1)},

        % check if we can drop a chunk from the head of the list
        SmallestIndex = dict:fold(fun(_, Val, Acc) -> lists:min([Val,Acc]) end,
            WhichChunk+1, NewCounters),
        Size = dict:size(NewCounters),

        {NewChunkList, NewOffset} =
        if Size == N andalso (SmallestIndex - Offset) == 2 ->
            {tl(ChunkList1), Offset+1};
        true ->
            {ChunkList1, Offset}
        end,
        middleman_loop(Receiver, N, NewCounters, NewOffset, NewChunkList)
    after 10000 ->
        ok
    end.
