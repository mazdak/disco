-module(jobpack).

-export([exists/1,
         extract/2,
         extracted/1,
         read/1,
         save/2,
         jobdict/1,
         jobinfo/1]).

-include("disco.hrl").

find(Key, Dict) ->
    case catch dict:find(Key, Dict) of
        {ok, Field} ->
            Field;
        error ->
            throw(disco:format("jobpack missing key '~s'", [Key]))
    end.

find_bool(Key, Dict) ->
    case dict:find(Key, Dict) of
        {ok, Field} ->
            Field =/= 0;
        error ->
            false
    end.

exists(JobHome) ->
    filelib:is_file(filename:join(JobHome, "jobfile")).

extract(JobPack, JobHome) ->
    JobHomeZip = find(<<"jobhome">>, jobdict(JobPack)),
    case zip:extract(JobHomeZip, [{cwd, JobHome}]) of
        {ok, Files} ->
            prim_file:write_file(filename:join(JobHome, ".jobhome"), <<"">>),
            Files;
        {error, Reason} ->
            throw({"Couldn't extract jobhome", JobHome, Reason})
    end.

extracted(JobHome) ->
    filelib:is_file(filename:join(JobHome, ".jobhome")).

read(JobHome) ->
    JobFile = filename:join(JobHome, "jobfile"),
    case prim_file:read_file(JobFile) of
        {ok, JobPack} ->
            JobPack;
        {error, Reason} ->
            throw({"Couldn't read jobfile", JobFile, Reason})
    end.

save(JobPack, JobHome) ->
    {MegaSecs, Secs, MicroSecs} = now(),
    TmpFile = filename:join(JobHome, disco:format("jobfile@~.16b:~.16b:~.16b",
                                                  [MegaSecs, Secs, MicroSecs])),
    JobFile = filename:join(JobHome, "jobfile"),
    case prim_file:write_file(TmpFile, JobPack) of
        ok ->
            case prim_file:rename(TmpFile, JobFile) of
                ok ->
                    JobFile;
                {error, Reason} ->
                    throw({"Couldn't rename jobpack", TmpFile, Reason})
            end;
        {error, Reason} ->
            throw({"Couldn't save jobpack", TmpFile, Reason})
    end.

jobinfo(JobPack) when is_binary(JobPack) ->
    jobinfo(jobdict(JobPack));
jobinfo(JobDict) ->
    Scheduler = find(<<"scheduler">>, JobDict),
    {validate_prefix(find(<<"prefix">>, JobDict)),
     #jobinfo{inputs = find(<<"input">>, JobDict),
              worker = find(<<"worker">>, JobDict),
              owner = find(<<"owner">>, JobDict),
              map = find_bool(<<"map?">>, JobDict),
              reduce = find_bool(<<"reduce?">>, JobDict),
              nr_reduce = find(<<"nr_reduces">>, JobDict),
              max_cores = find(<<"max_cores">>, Scheduler),
              force_local = find_bool(<<"force_local">>, Scheduler),
              force_remote = find_bool(<<"force_remote">>, Scheduler)}}.

jobdict(JobPack) ->
    bencode:decode(JobPack).

validate_prefix(Prefix) when is_binary(Prefix)->
    validate_prefix(binary_to_list(Prefix));
validate_prefix(Prefix) ->
    case string:chr(Prefix, $/) + string:chr(Prefix, $.) of
        0 ->
            Prefix;
        _ ->
            throw("invalid prefix")
    end.