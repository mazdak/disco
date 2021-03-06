-module(ddfs_gc).
-export([start_gc/1, gc_status/0, hosted_tags/1]).

% GC internal api.
-export([abort/2]).

-include("config.hrl").
-include("ddfs.hrl").
-include("ddfs_tag.hrl").
-include("ddfs_gc.hrl").

-define(CALL_TIMEOUT, 30 * ?SECOND).

-spec gc_status() -> {ok, not_running | phase()} | {error, term()}.
gc_status() ->
    ?MODULE ! {self(), gc_status},
    receive
        R -> R
    after ?CALL_TIMEOUT ->
            {error, timeout}
    end.


-spec abort(term(), atom()) -> no_return().
abort(Msg, Code) ->
    error_logger:warning_report({"GC: aborted", Msg}),
    exit(Code).


-spec start_gc(string()) -> no_return().
start_gc(Root) ->
    true = register(?MODULE, self()),
    % Wait some time for all nodes to start and stabilize.
    InitialWait =
        case disco:has_setting("DDFS_GC_INITIAL_WAIT") of
            true -> list_to_integer(disco:get_setting("DDFS_GC_INITIAL_WAIT")) * ?MINUTE;
            false -> ?GC_DEFAULT_INITIAL_WAIT
        end,
    timer:sleep(InitialWait),
    process_flag(trap_exit, true),
    GCMaxDuration = lists:min([?GC_MAX_DURATION,
                               ?ORPHANED_BLOB_EXPIRES,
                               ?ORPHANED_TAG_EXPIRES]),
    start_gc(Root, ets:new(deleted_ages, [set, public]), GCMaxDuration).

-spec start_gc(string(), ets:tab(), non_neg_integer()) -> no_return().
start_gc(Root, DeletedAges, GCMaxDuration) ->
    case ddfs_gc_main:start_link(Root, DeletedAges) of
        {ok, Gc} ->
            Start = now(),
            start_gc_wait(Gc, GCMaxDuration),
            % timer:now_diff() returns microseconds.
            Wait = round(timer:now_diff(now(), Start) / 1000),
            % Wait until the next scheduled gc run slot.
            Idle = ?GC_INTERVAL - (Wait rem ?GC_INTERVAL),
            idle(Idle);
        E ->
            error_logger:error_report({"GC: error starting", E}),
            idle(?GC_INTERVAL)
    end,
    start_gc(Root, DeletedAges, GCMaxDuration).

-spec idle(timeout()) -> ok.
idle(Timeout) ->
    Start = now(),
    receive
        {From, gc_status} ->
            From ! {ok, not_running},
            Wait = round(timer:now_diff(now(), Start) / 1000),
            idle(Wait);
        _Other ->
            Wait = round(timer:now_diff(now(), Start) / 1000),
            idle(Wait)
    after Timeout ->
            ok
    end.

-spec start_gc_wait(pid(), timeout()) -> ok.
start_gc_wait(Pid, Interval) ->
    Start = now(),
    receive
        {'EXIT', Pid, Reason} ->
            error_logger:error_report({"GC: exit", Pid, Reason});
        {'EXIT', Other, Reason} ->
            error_logger:error_report({"GC: unexpected exit", Other, Reason}),
            start_gc_wait(Pid, round(Interval - (timer:now_diff(now(), Start) / 1000)));
        {From, gc_status} when is_pid(From) ->
            ddfs_gc_main:gc_status(Pid, From),
            start_gc_wait(Pid, round(Interval - (timer:now_diff(now(), Start) / 1000)));
        Other ->
            error_logger:error_report({"GC: unexpected msg exit", Other}),
            start_gc_wait(Pid, round(Interval - (timer:now_diff(now(), Start) / 1000)))
    after Interval ->
            error_logger:error_report({"GC: timeout exit"}),
            exit(Pid, force_timeout)
    end.

-spec hosted_tags(host()) -> {ok, [tagname()]} | {'error', term()}.
hosted_tags(Host) ->
    case disco:slave_safe(Host) of
        false ->
            {error, unknown_host};
        Node ->
            case hosted_tags(Host, Node) of
                {error, _} = E -> E;
                Tags -> {ok, Tags}
            end
    end.
-spec hosted_tags(host(), node()) -> [tagname()] | {'error', term()}.
hosted_tags(Host, Node) ->
    case catch ddfs_master:get_tags(safe) of
        {ok, Tags} ->
            lists:foldl(
              fun (_T, {error, _} = E) ->
                      E;
                  (T, HostedTags) ->
                      case tag_is_hosted(T, Host, Node, ?MAX_TAG_OP_RETRIES) of
                          true -> [T|HostedTags];
                          false -> HostedTags;
                          E -> E
                      end
              end, [], Tags);
        E ->
            E
    end.

-spec tag_is_hosted(tagname(), host(), node(), non_neg_integer()) ->
                           boolean() | {'error', term()}.
tag_is_hosted(T, _Host, _Node, 0) ->
    {error, {get_tag, T}};
tag_is_hosted(T, Host, Node, Retries) ->
    case catch ddfs_master:tag_operation(gc_get, T, ?GET_TAG_TIMEOUT) of
        {{missing, _}, false} ->
            false;
        {'EXIT', {timeout, _}} ->
            tag_is_hosted(T, Host, Node, Retries - 1);
        {_Id, Urls, TagReplicas} ->
            lists:member(Node, TagReplicas) orelse urls_are_hosted(Urls, Host, Node);
        E ->
            E
    end.

-spec urls_are_hosted([[url()]], host(), node())
                     -> boolean() | {'error' | term()}.
urls_are_hosted([], _Host, _Node) ->
    false;
urls_are_hosted([[]|Rest], Host, Node) ->
    urls_are_hosted(Rest, Host, Node);
urls_are_hosted([Urls|Rest], Host, Node) ->
    Hosted =
        lists:foldl(
          fun (<<"tag://", T/binary>>, false) ->
                  tag_is_hosted(T, Host, Node, ?MAX_TAG_OP_RETRIES);
              (Url, false) ->
                  case ddfs_util:parse_url(Url) of
                      not_ddfs -> false;
                      {H, _V, _T, _H, _B} -> H =:= Host
                  end;
              (_Url, TrueOrError) ->
                  TrueOrError
          end, false, Urls),
    case Hosted of
        false -> urls_are_hosted(Rest, Host, Node);
        TrueOrError -> TrueOrError
    end.
