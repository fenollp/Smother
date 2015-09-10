-module(smother_server).
-behaviour(gen_server).

-include_lib("wrangler/include/wrangler.hrl").
-include("include/eval_records.hrl").
-include("include/analysis_reports.hrl").

-export([log/3,declare/3,analyse/1,analyse/2,clear/1,analyse_to_file/1,analyse_to_file/2,show_files/0,get_zeros/1,get_nonzeros/1,get_split/1,get_percentage/1,reset/1,init_file/2]).
-export([init/1,handle_call/2,handle_cast/2,terminate/2,handle_call/3,code_change/3,handle_info/2]).

-export([build_pattern_record/1,build_bool_record/1,within_loc/2]).

-export([store_zero/0]).

-export([all_vars/1,get_pattern_subcomponents/1,list_from_list/1]).

%% @private
init(Dict) ->
    {ok,Dict}.

%% @private
handle_call(Action,_From,State) ->
    handle_call(Action,State).

%% @private
get_source(Module,State) ->
    case lists:keyfind(Module,1,State) of
	false -> "";
	{Module, Source,_FD} -> Source
    end.

%% @private
handle_call(show_files,State) ->
    Files = lists:map(fun({File,_Source,_FD}) -> File end, State),
    {reply,Files,State};
handle_call({init_file,Module,Source},State) ->
    {reply,ok,lists:keystore(Module,1,State,{Module,Source,[]})};
handle_call({clear,Module},State) ->
    {reply,ok,lists:keystore(Module,1,State,{Module,get_source(Module,State),[]})};
handle_call({reset, Module}, State) ->
  OldDict = case get({zero_state, Module}) of
              X when is_list(X) -> X;
              _                 -> [] end,
  {reply, ok, lists:keystore(Module, 1, State, {Module, get_source(Module,State),OldDict})};
handle_call(store_zero, State) ->
  [ put({zero_state, M}, S) || {M, _F, S} <- State ],
  {reply, ok, State};
handle_call({declare,Module,Loc,Declaration},State) ->
    %%io:format("Declaration in ~p~n",[File]),
    {FDict,Source} = case lists:keyfind(Module,1,State) of
		false -> {[],get_source(Module,State)};
		{Module, Src,FD} -> {FD,Src}
	    end,
    FDict2 = 
	case Declaration of
	    {if_expr,VarNames,Content} ->

		%% TODO: Wrangler now supports three layers of lists for ifs:
		%% Patterns
		%% Clauses
		%% Components in clauses
		%%
		%% e.g.: 
		%% if (A == 0), (B > 4); (C==1) ->
		%%	B / 1;
		%%   true ->
		%%	B / A
		%% end.
		%% Has two patterns, (<Long-prop> and true)
		%% The first pattern has two clauses ([[A == 0, B > 4],[C == 1]]),
		%% The first clause has two components ([A == 0, B > 4])
		%% 
		%% This code currently flattens this out and so will only handle one 
		%% clause and once component per pattern...
		
		%%io:format("If Declaration:~n~p~n~p~n",[VarNames,Content]),
		%%io:format("IF declaration with ~p patterns ~p~n",[length(Content), Loc]),
		ExpRecords = 
		    lists:flatten(
		    lists:map(fun(C) ->
				      R = lists:map(fun(Cc) -> 
							    Rr = lists:map(fun ?MODULE:build_bool_record/1, Cc),
							    lists:flatten(Rr)
						    end,
						    C),
				      
				      R
			      end,
			      Content)
		     ),
		lists:keystore(Loc,1,FDict,{Loc,{if_expr,VarNames,ExpRecords}});
	    {case_expr,Content} ->
		ExpRecords = lists:map(fun({_P,_G}=C) ->
					     build_pattern_record(C)
				     end,
				     Content),
		%% Fix the last pattern to ignore fall through
		%% FIXME: add config to require defensive code or not?
		ExpRecords2 = ignore_fallthrough(ExpRecords),
		lists:keystore(Loc,1,FDict,{Loc,{case_expr,ExpRecords2}});
	    {receive_expr,Content} ->
		Patterns = lists:map(fun({_P,_G}=C) ->
					     build_pattern_record(C)
				     end,
				     Content),
		lists:keystore(Loc,1,FDict,{Loc,{receive_expr,Patterns}});
	    {fun_case,F,Arity,Args,Guard} ->
		ArgRecords = 
		    case Args of 
			[] ->
			    {{StartLine,StartChar},{_EndLine,_EndChar}} = Loc,
			    BStart = StartChar + length(atom_to_list(F)),
			    BracketLoc = {{StartLine,BStart},{StartLine,BStart+1}},
			    build_pattern_record({[{wrapper,nil,{attr,BracketLoc,[{range,BracketLoc}],none},{nil,BracketLoc}}],Guard});
			_ ->
			    build_pattern_record({[list_from_list(Args)],Guard})
		    end,
                AR2 = ArgRecords#pat_log{extras=[]},
		AR3 = case all_vars(lists:map(fun(#pat_log{exp=Exp}) -> Exp end, ArgRecords#pat_log.subs)) of
			  true ->
			      AR2#pat_log{nmcount=-1};
			  _ ->
			      AR2
		      end,
		%%Find function declaration and add a pattern...
		{OldLoc, {fun_expr,F,Arity,Patterns}} = 
		    case lists:filter(fun({_Loc,Rec}) ->
					      case Rec of
						  {fun_expr,F,Arity,_Patterns} ->
						      true;
						  _ ->
						      false
					      end
				      end
				      ,FDict) of
			[Rec] ->
			    Rec;
			[] ->
			    {Loc,{fun_expr,F,Arity,[]}}
		    end,
		NewFRecord = {fun_expr,F,Arity,Patterns ++ [{Loc,AR3}]},
		%% This assumes declarations will arrive in order...
		{Start,_End} = OldLoc,
		{_NewStart,NewEnd} = Loc,
		NewLoc = {Start,NewEnd},
		lists:keystore(NewLoc,1,lists:keydelete(OldLoc,1,FDict),{NewLoc,NewFRecord});
	    _D ->
		io:format("Unknown smother declaration: ~p~n",[Declaration]),
		FDict
	end,
    {reply,ok,lists:keystore(Module,1,State,{Module,Source,FDict2})};
handle_call({analyse,Module},State) ->
    case lists:keyfind(Module,1,State) of
	{Module,_Source,FDict} ->
	    {reply,{ok,FDict},State};
	_ ->
	    {reply,{error,no_record_found,Module},State}
    end;
handle_call({analyse,Module,Loc},State) ->
    case lists:keyfind(Module,1,State) of
	{Module,_Source,FDict} ->
	    Analysis = lists:filter(fun({L,_V}) -> within_loc(Loc,L) end,FDict),
	    {reply,{ok,Analysis},State};
	_ ->
	    {reply,{error,no_record_found,Module},State}
    end;
handle_call({analyse_to_file,Module,Outfile},State) ->
    case lists:keyfind(Module,1,State) of
	{Module,Source,FDict} ->
		    case smother_analysis:make_html_json_analysis(Source,FDict,Outfile) of 
			ok ->
			    {reply,{ok,Outfile},State};
			{error, Error} ->
			    {reply,{error,Error},State}
		    end;
	_ ->
	    {reply,{error,no_record_found,Module},State}
    end;
handle_call(Action,State) ->
    io:format("Unexpected call to the smother server: ~p~n", [Action]),
    {reply,unknown_call,State}.

%% @private
handle_cast(stop,S) ->
    {stop,normal,S};
handle_cast({log,File,Loc,LogData},State) ->
    {FDict,Source} = case lists:keyfind(File,1,State) of
		false -> {[], get_source(File,State)};
		{File, Src,FD} -> {FD,Src}
	    end,
    if FDict == [] ->
	    {noreply,State};
       true ->
	    case lists:filter(fun({L,_R}) -> L == Loc end, FDict) of
		[] -> 
		    %% No exact matches, so it could be a sub-pattern of a function
		    case lists:filter(fun({L,_R}) -> within_loc(L,Loc) end, FDict) of
			[{ParentLoc, {fun_expr,F,Arity,Patterns}}] ->
			    NewPatterns = apply_fun_log(Loc,LogData,Patterns),
			    NewFDict = lists:keystore(ParentLoc,1,FDict,{ParentLoc,{fun_expr,F,Arity,NewPatterns}}),
			    {noreply,lists:keystore(File,1,State,{File,Source,NewFDict})};
			_D ->
			    io:format("No relevant condition for location ~p~n",[Loc]),
			    lists:map(fun({L,_R}) -> 
					      io:format("    ~p vs ~p <~p>~n",[L, Loc, L == Loc])
				      end, FDict),
			    {noreply,State}
		    end;
		[{Loc, {receive_expr,Patterns}}] ->
		    [EVal | Bindings] = LogData,
		    %%io:format("RECEIVED: ~p~n",[EVal]),
		    NewPatterns = apply_pattern_log(EVal,Patterns,Bindings),
		    NewFDict = lists:keystore(Loc,1,FDict,{Loc,{receive_expr,NewPatterns}}),
		    {noreply,lists:keystore(File,1,State,{File,Source,NewFDict})};	
		[{Loc,{if_expr,VarNames,ExRecords}}] ->
		    Bindings = lists:zip(VarNames,LogData),
		    ExRecords2 = apply_bool_log(Bindings,ExRecords,false),
		    NewFDict = lists:keystore(Loc,1,FDict,{Loc,{if_expr,VarNames,ExRecords2}}),
		    {noreply,lists:keystore(File,1,State,{File,Source,NewFDict})};
		[{Loc,{case_expr,ExRecords}}]  ->
		    [EVal | Bindings] = LogData,
		    ExRecords2 = apply_pattern_log(EVal,ExRecords,Bindings),
		    NewFDict = lists:keystore(Loc,1,FDict,{Loc,{case_expr,ExRecords2}}),
		    {noreply,lists:keystore(File,1,State,{File,Source,NewFDict})};
		[{ParentLoc, {fun_expr,F,Arity,Patterns}}] ->
		    NewPatterns = apply_fun_log(Loc,LogData,Patterns),
		    NewFDict = lists:keystore(ParentLoc,1,FDict,{ParentLoc,{fun_expr,F,Arity,NewPatterns}}),
		    {noreply,lists:keystore(File,1,State,{File,Source,NewFDict})};
		D ->
		    io:format("Unknown declaration: ~p~n", [D]),
		    {noreply,State}
	    end
    end;
handle_cast(M,S) ->
    io:format("Unexpected cast msg to smother server:~w~n", [M]),
    {noreply,S}.

%% @private
terminate(normal,_State) ->
    ok;
terminate(_,_State) ->
    ok.

%% @private
handle_info(Info,State) ->
    io:format("Smother server recieved information: ~p~n",[Info]),
    {noreply,State}.

%% @private
code_change(_OldVsn,State,_Extra) ->
    {ok,State}.


%% API functions

show_files() ->
    start_if_needed(),
    gen_server:call({global,smother_server}, show_files, infinity).

analyse(File) ->
    start_if_needed(),
    gen_server:call({global,smother_server},{analyse,File}, 5000).

analyse(File,Loc) ->
    start_if_needed(),
    gen_server:call({global,smother_server},{analyse,File,Loc}, infinity).

analyse_to_file(File,Outfile) ->
    start_if_needed(),
    gen_server:call({global,smother_server},{analyse_to_file,File,Outfile}, infinity).
analyse_to_file(File) ->
    start_if_needed(),
    Outfile = lists:flatten(io_lib:format("~s-SMOTHER.html",[File])),
    gen_server:call({global,smother_server},{analyse_to_file,File,Outfile}, infinity).
    
reset(File) ->    
    start_if_needed(),
    gen_server:call({global,smother_server},{reset,File}, infinity).

store_zero() ->
    start_if_needed(),
    gen_server:call({global, smother_server}, store_zero, infinity).

declare(File,Loc,Declaration) ->
    start_if_needed(),
    gen_server:call({global,smother_server},{declare,File,Loc,Declaration}, infinity).

log(File,Loc,ParamValues) ->
    start_if_needed(),
    gen_server:cast({global,smother_server},{log,File,Loc,ParamValues}).

clear(File) ->
    start_if_needed(),
    gen_server:call({global,smother_server},{clear,File}, infinity).
init_file(Module,Source) ->
    start_if_needed(),
    gen_server:call({global,smother_server},{init_file,Module,Source}, infinity).
    

start_if_needed() ->
    case global:whereis_name(smother_server) of
	undefined ->
	    gen_server:start({global,smother_server},smother_server,[],[]);
	_ ->
	    ok
    end.


within_loc({{Sl,Sp},{El,Ep}} = _Loc, {{SSl,SSp},{SEl,SEp}} = _SubLoc) ->
    (
      (Sl < SSl)
      or ((Sl == SSl) and (Sp =< SSp))
    ) and (
	(El > SEl)
	or ((El == SEl) and (Ep >= SEp))
       ).

apply_bool_log(_Bindings,[],_All) ->
    [];
apply_bool_log(Bindings,[#bool_log{}=Log | Es],All) ->   
    E = revert(Log#bool_log.exp),
    %%io:format("Evaluating:~n~p~nUnder: ~p~n",[E,Bindings]),
    {value,Eval,_} = erl_eval:expr(E,Bindings),
    %%io:format("Evals to ~p~n",[Eval]),
    case Eval of
	true ->
	    NTSubs = apply_bool_log(Bindings,Log#bool_log.tsubs,true),
	    %% Don't continue applying once a condition matches?
	    if All ->
		    [Log#bool_log{tcount=Log#bool_log.tcount+1,tsubs=NTSubs} | apply_bool_log(Bindings,Es,All)];
	       true ->
		    [Log#bool_log{tcount=Log#bool_log.tcount+1,tsubs=NTSubs} | Es]
	    end;
	false ->
	    NFSubs = apply_bool_log(Bindings,Log#bool_log.fsubs,true),
	    [Log#bool_log{fcount=Log#bool_log.fcount+1,fsubs=NFSubs} | apply_bool_log(Bindings,Es,All)];
	Unexpected ->
	    exit({"Expected boolean expression",Unexpected,E,Bindings})
    end.
    
get_bool_subcomponents([]) ->
    [];
get_bool_subcomponents({tree,infix_expr,_Attrs,{infix_expr,Op,Left,Right}}) ->
    {tree,operator,_OpAttrs,Image} = Op,
    case lists:any(fun(E) -> Image == E end,['and','or','xor']) of
	true ->
	    [Left,Right];
	false ->
	    []
    end;
get_bool_subcomponents([_V | _VMore] = _VList) ->
    %%io:format("Got a list with ~p elements...~n", [length(VList)]),
    %% FIXME comma,semicolon syntax.....
    [];
get_bool_subcomponents({wrapper,atom,_Attrs,_Atom}) ->
    [];
get_bool_subcomponents({atom,_Line,true}) ->
    [];
get_bool_subcomponents(_V) ->
    %%VList = tuple_to_list(V),
    %%io:format("Expression with ~p elements, starting with {~p,~p,... ",[length(VList),lists:nth(1,VList),lists:nth(2,VList)]),
    %%io:format("UNKNOWN bool expression type:~n~p~n~n", [V]),
    [].

get_pattern_subcomponents({tree,tuple,_Attrs,Content}) ->
    Content;
get_pattern_subcomponents({tree,list,_Attrs,{list,[Head],none}}) ->
    [Head];
get_pattern_subcomponents({tree,list,_Attrs,{list,[Head],Tail}}) ->
    [Head | get_pattern_subcomponents(Tail)];
get_pattern_subcomponents({wrapper,underscore,_Attrs,_Image}) ->	
    [];
get_pattern_subcomponents({wrapper,variable,_Attrs,_Image}) ->	
    [];
get_pattern_subcomponents({wrapper,nil,_Attrs,_Image}) ->	
    [];
get_pattern_subcomponents({fun_declaration,_Loc,Args}) ->
    Args;
get_pattern_subcomponents({tree,record_expr,_Attrs,{record_expr,none,_Name,Content}}) ->
    Content;
get_pattern_subcomponents({tree,record_field,_Attrs,{record_field,_Name,Content}}) ->
    get_pattern_subcomponents(Content);
get_pattern_subcomponents({tree,match_expr,_Attrs,{match_expr,Left,Right}}) ->
    get_pattern_subcomponents(Left) ++ get_pattern_subcomponents(Right);
get_pattern_subcomponents(_V) ->
    %%io:format("UNKNOWN pattern expression type:~n~p~n~n", [_V]),
    [].

build_bool_record(E) ->
    Subs = lists:map(fun ?MODULE:build_bool_record/1,get_bool_subcomponents(E)),
    #bool_log{exp=E,tsubs=Subs,fsubs=Subs}.

%% @private
all_vars([]) ->
    true;
all_vars([{wrapper,variable,_Attrs,_Image}| Tl]) ->
    all_vars(Tl);
all_vars([{wrapper,underscore,_Attrs,_Image} | Tl]) ->
    all_vars(Tl);
all_vars([_H | _]) ->
    false.

build_pattern_record({wrapper,variable,_Attrs,_Image}=E) ->
    %% Its not meaningful to consider sub components and non-matches of variables...
    #pat_log{exp=E,nmcount=-1,subs=[],extras=[],matchedsubs=[]};
build_pattern_record({wrapper,underscore,_Attrs,_Image}=E) ->
    %% Its not meaningful to consider sub components and non-matches of underscores!
    #pat_log{exp=E,nmcount=-1,subs=[],extras=[],matchedsubs=[]};
%% build_pattern_record({smother_record,Name,Loc,Content}=E) ->
%%     %% Records are processed by the compiler
%%     #pat_log{exp=E,nmcount=-1,subs=lists:map(fun build_pattern_record/1, Content),extras=[],matchedsubs=[]};
%% build_pattern_record({smother_record_element,Name,Loc,Exp}=E) ->
%%     %% Records are processed by the compiler
%%     #pat_log{exp=E,nmcount=-1,subs=Exp,extras=[],matchedsubs=[]};
build_pattern_record({E,Gs}) ->
    EPat = build_pattern_record(E),
    GuardPats = lists:flatten(lists:map(fun(G) ->
				  lists:map(fun build_bool_record/1, G)
			  end,
			  Gs)),
    EPat#pat_log{guards=GuardPats};
build_pattern_record([E]) ->
    build_pattern_record(E);
build_pattern_record(E) ->
    Comps = get_pattern_subcomponents(E),
    Subs = case all_vars(Comps) of
    	       true -> [];
    	       _ -> 
		   lists:map(fun ?MODULE:build_pattern_record/1,Comps)
    	   end,
    Extras = make_extras(E),
    #pat_log{exp=E,subs=Subs,extras=Extras,matchedsubs=Subs}.


add_match([]) ->
    [];
add_match([S | Ss]) ->
    [ S#pat_log{
	mcount=S#pat_log.mcount+1,
	matchedsubs=add_match(S#pat_log.matchedsubs)
       } | add_match(Ss)].

match_record_subs([],_FieldBindings,_Bindings) ->
    {ok,[]};
match_record_subs([#pat_log{exp={tree,record_field,_Attrs,{record_field,{wrapper,atom,_,{atom,_,Name}},Content}}=Exp}=PatLog | MoreSubs],FieldBindings,Bindings) ->
    {OtherStatus,OtherSubs} = match_record_subs(MoreSubs,FieldBindings,Bindings),
    case lists:keyfind(Name,1,FieldBindings) of
	false ->
	    {fail,[PatLog#pat_log{nmcount=PatLog#pat_log.nmcount+1} | OtherSubs]};
	{Name,Val} ->
	    [#pat_log{}=NewPatLog] = apply_pattern_log(Val,[PatLog#pat_log{exp=Content}],Bindings),
	    if NewPatLog#pat_log.nmcount > PatLog#pat_log.nmcount ->
		    {fail,[NewPatLog#pat_log{exp=Exp} | OtherSubs]};
	       true ->
		    {OtherStatus,[NewPatLog#pat_log{exp=Exp} | OtherSubs]}
	    end
    end;
match_record_subs([PL | _],_FieldBindings,_Bindings) ->
    exit({"Applying match_record_subs to somethign that's not a record field!",PL}).

apply_pattern_log(_EVal,[],_Bindings) ->
    [];
apply_pattern_log(EVal,[#pat_log{exp={wrapper,integer,_Attrs,{integer,_Loc,Image}},guards=Guards}=PatLog | Es],Bindings) when is_integer(EVal) ->
    EVImg = lists:flatten(io_lib:format("~w",[EVal])),
    if EVImg == Image ->
	    {Result,NewGuards} = 
		try 
		    match_guards(Guards,Bindings)
		catch error:{unbound_var,V} ->
			io:format("Error: unbound var ~p~n",[V]),
			{fail,Guards}
		end,
	    
	    NewPat = PatLog#pat_log{
		       mcount=PatLog#pat_log.mcount+1,
		       matchedsubs=add_match(PatLog#pat_log.matchedsubs),
		       guards=NewGuards
		      },
	    
	    %%io:format("Pattern MATCH, Guards: ~p~n",[Result]),
	    case Result of
		ok ->
		    %% Don't continue on the other patterns once a pattern matches, they should not show any evaluation
		    [NewPat | Es];
		_ ->
		    [NewPat | apply_pattern_log(EVal,Es,Bindings)]
	    end;
       true ->
	    %% A simple integer has no subs or extras
	    [PatLog#pat_log{nmcount=PatLog#pat_log.nmcount+1}| apply_pattern_log(EVal,Es,Bindings)]
    end;
apply_pattern_log(EVal,[#pat_log{exp={wrapper,variable,_Attrs,{var,_Loc,Name}},guards=Guards}=PatLog | Es],Bindings) ->
    %% Matching to a variable can't fail...
    {Result,NewGuards} = 
	try 
	    match_guards(Guards,Bindings++[{Name,EVal}])
	catch error:{unbound_var,V} ->
		io:format("Error: unbound var ~p~n",[V]),
		{fail,Guards}
	end,
    
    NewPat = PatLog#pat_log{
	       mcount=PatLog#pat_log.mcount+1,
	       matchedsubs=add_match(PatLog#pat_log.matchedsubs),
	       guards=NewGuards
	      },
    
    %%io:format("Pattern MATCH, Guards: ~p~n",[Result]),
    case Result of
	ok ->
	    %% Don't continue on the other patterns once a pattern matches, they should not show any evaluation
	    [NewPat | Es];
	_ ->
	    [NewPat | apply_pattern_log(EVal,Es,Bindings)]
    end;
apply_pattern_log(EVal,[#pat_log{exp={wrapper,underscore,_Attrs,_},guards=Guards}=PatLog | Es],Bindings) ->
    %% Matching to an underscore can't fail...
    {Result,NewGuards} = 
	try 
	    match_guards(Guards,Bindings)
	catch error:{unbound_var,V} ->
		io:format("Error: unbound var ~p~n",[V]),
		{fail,Guards}
	end,
    
    NewPat = PatLog#pat_log{
	       mcount=PatLog#pat_log.mcount+1,
	       matchedsubs=add_match(PatLog#pat_log.matchedsubs),
	       guards=NewGuards
	      },
    
    %%io:format("Pattern MATCH, Guards: ~p~n",[Result]),
    case Result of
	ok ->
	    %% Don't continue on the other patterns once a pattern matches, they should not show any evaluation
	    [NewPat | Es];
	_ ->
	    [NewPat | apply_pattern_log(EVal,Es,Bindings)]
    end;
apply_pattern_log({smother_record,Fields,Values}=EVal,
		  [#pat_log{
		      exp={tree,record_expr,_Attr,{record_expr,none,{tree,atom,_NAttr,Name},_ExpContent}}
			   ,subs=Subs,guards=Guards,extras=Extras}=PatLog | Es]
		   ,Bindings)->
    
    FieldBindings = 
	lists:zip([smother_record_name|Fields],tuple_to_list(Values)),
    {SubResult,NewSubs} = match_record_subs(Subs,FieldBindings,Bindings),
    case SubResult of
	fail ->
	    [PatLog#pat_log{nmcount=PatLog#pat_log.nmcount+1,subs=NewSubs}| apply_pattern_log(EVal,Es,Bindings)];
	_ ->
	    %% Now check for guard matches...
	    {Result,NewGuards} = 
		try 
		    %% FIXME: needs bindings from record fields...
		    match_guards(Guards,Bindings)
		catch error:{unbound_var,V} ->
			io:format("Error: unbound var ~p~n",[V]),
			{fail,Guards}
		end,
	    case process_subs(PatLog,EVal,Bindings) of
		{NewSubs,Extra} ->
		    NewExtras = 
			case Extra of
			    no_extras ->
				Extras;
			    _ ->
				case lists:keyfind(Extra,1,Extras) of
				    {Extra,EMCount} ->
					lists:keyreplace(Extra,1,Extras,{Extra,EMCount+1});
				    _ ->
					io:format("Unknown extra result: ~p in record ~p~n",[Extra,Name]),
					Extras
				end
			end,
		    case Result of
			ok ->
			    %% Guards passed, so don't show evaluation of further patterns
			    [PatLog#pat_log{mcount=PatLog#pat_log.mcount+1,subs=NewSubs,extras=NewExtras,guards=NewGuards}|Es];
			
			fail ->
			    [PatLog#pat_log{mcount=PatLog#pat_log.mcount+1,subs=NewSubs,extras=NewExtras,guards=NewGuards}| apply_pattern_log(EVal,Es,Bindings)]
		    end;
		Err ->
		    exit({"Unexpected result from process_subs",Err})
	    end
    end;
apply_pattern_log(EVal,[#pat_log{exp={tree,match_expr,_Attrs,{match_expr, Left,Right}}=Exp}=PatLog | Es],Bindings) ->
    case Left of
	{wrapper,variable,_VAttrs,_Image} ->
	    %%io:format("Matching just ~p vs ~p~n",[EVal,Right]),
	    [#pat_log{}=NewPatLog| NewEs] = apply_pattern_log(EVal,[PatLog#pat_log{exp=Right}| Es],Bindings),
	    [NewPatLog#pat_log{exp=Exp} | NewEs];
	_ ->
	    case Right of
		{wrapper,variable,_VAttrs,_Image} ->
		    %%io:format("Matching just ~p vs ~p~n",[EVal,Left]),
		    [#pat_log{}=NewPatLog| NewEs] = apply_pattern_log(EVal,[PatLog#pat_log{exp=Left}| Es],Bindings),
		    [NewPatLog#pat_log{exp=Exp} | NewEs];
		_ ->
		    %% A match expression with no variables?
		    %% Is that even allowed in patterns?
		    exit({"Smother can't handle match expressions with complex components on both sides.",{match_expr, Left,Right}})
	    end
    end;
apply_pattern_log(EVal,[#pat_log{exp=Exp,guards=Guards,extras=Extras}=PatLog | Es],Bindings) ->
    %%io:format("FALLTHROUGH:~n~p~n~p~n------------------------------~n",[EVal,Exp]),
    ValStx = abstract_revert(EVal),
    try
	%% io:format("Reverting ~p~n~n",[PatLog#pat_log.exp]),
	TrueExp = revert(Exp),
	%%io:format("Comparing ~p to pattern ~p~n", [TrueExp,ValStx]),
	
	{value,_V,NewBindings} = erl_eval:expr(erl_syntax:revert(erl_syntax:match_expr(TrueExp,ValStx)),Bindings),
	%%io:format("Got back: ~p~n",[NewBindings]),

	%% Now check for guard matches...
	{Result,NewGuards} = 
	    try 
		match_guards(Guards,Bindings++NewBindings)
	    catch error:{unbound_var,V} ->
		    io:format("Error: unbound var ~p~n",[V]),
		    {fail,Guards}
	    end,

	NewPat = PatLog#pat_log{
		   mcount=PatLog#pat_log.mcount+1,
		   matchedsubs=add_match(PatLog#pat_log.matchedsubs),
		   guards=NewGuards,
                   extras=Extras
		  },

	%%io:format("Pattern MATCH, Guards: ~p~n",[Result]),
	case Result of
	    ok ->
		%% Don't continue on the other patterns once a pattern matches, they should not show any evaluation
		[NewPat | Es];
	    _ ->
		[NewPat | apply_pattern_log(EVal,Es,Bindings)]
	end
    catch
	error:_Msg ->
	    %%io:format("Non-Match!  ~p~n",[_Msg]),
	    %%io:format("No Match: ~p vs ~p~n~p~n",[revert(PatLog#pat_log.exp),ValStx,_Msg]),
	    case process_subs(PatLog,EVal,Bindings) of
		{NewSubs,Extra} ->
		    NewExtras = 
			case Extra of
			    no_extras ->
				Extras;
			    _ ->
				case lists:keyfind(Extra,1,Extras) of
				    {Extra,EMCount} ->
					lists:keyreplace(Extra,1,Extras,{Extra,EMCount+1});
				    _ ->
					io:format("Unknown extra result: ~p in ~p~n",[Extra,smother_analysis:exp_printer(Exp)]),
					Extras
				end
			end,
		    [PatLog#pat_log{nmcount=PatLog#pat_log.nmcount+1,subs=NewSubs,extras=NewExtras}| apply_pattern_log(EVal,Es,Bindings)];
		Err ->
		    exit({"Unexpected result from process_subs",Err})
	    end
    end.

match_guards([],_Bindings) ->
    {ok, []};
match_guards([#bool_log{}=G | Gs], Bindings) ->
    {SubRes, NewGs} = match_guards(Gs,Bindings),
    NewLog = hd(apply_bool_log(Bindings,[G],true)),
    if NewLog#bool_log.tcount > G#bool_log.tcount ->
	    %% Matched...
	    {SubRes, [NewLog | NewGs]};
       true ->
	    %% Didn't match...
	    {fail, [NewLog | NewGs]}
    end;
match_guards([Gs],Bindings) ->
    match_guards(Gs, Bindings);
match_guards([Gs | MoreGs],Bindings) ->
    {LeftRes, NewLeft} = match_guards(Gs, Bindings),
    {RightRes, NewRight} = match_guards(MoreGs, Bindings),
    if LeftRes == ok; 
       RightRes == ok ->
	    {ok, [NewLeft| NewRight]};
       true ->
	    {fail, [NewLeft | NewRight]}
    end;
match_guards(G, _Bindings) ->
    io:format("Wait, what...? ~p~n",[G]).

process_subs(#pat_log{exp={tree,tuple,_Attrs,Content}=_Exp,subs=Subs},EVal,Bindings) ->
    case abstract_revert(EVal) of
	{tuple,_OLine,ValContent} ->
	    if length(Content) /= length(ValContent) ->
		    {Subs,tuple_size_mismatch};
	       true ->
		    %% Tuple subs should always be the same order as the tuple content...
		    case all_vars(Content) of
			true ->
			    %% The Subs will have been pruned
			    %% So, subs is probably == []
			    {Subs,no_extras};
			_ ->
			    ZipList = lists:zip(Subs,ValContent),
			    NewSubs=lists:flatten(lists:map(fun({S,VC}) -> 
								    apply_pattern_log(
								      erl_parse:normalise(VC)
								      ,[S]
								      ,Bindings) 
							    end,
							    ZipList)
						 ),
			    {NewSubs, no_extras}
		    end
	    end;
	_Val ->
	    {Subs,not_a_tuple}
    end;
process_subs(#pat_log{exp={wrapper,integer,_Attrs,_Image},subs=Subs},_EVal,_Bindings) ->
    {Subs,no_extras};
process_subs(#pat_log{exp={wrapper,nil,_Attrs,_Image},subs=Subs},_EVal,_Bindings) ->
    {Subs,no_extras};
process_subs(#pat_log{exp={tree,list,_Attrs,_Content}=Exp,subs=Subs},EVal,Bindings) ->
    %% Get the true length, rather than the number of Subs, since some of those have been stripped
    Comps = get_pattern_subcomponents(Exp),
    L = length(Comps),
    case abstract_revert(EVal) of
	{cons,_OLine,Head,ValContent} ->
	    ContentList = [Head | list_to_list(ValContent)],
	    if L == 0 ->
		    io:format("~p is empty~n",[smother_analysis:exp_printer(Exp)]),
		    {Subs,non_empty_list};
	       L /= length(ContentList) ->
		    {Subs,list_size_mismatch};
	       true ->
		    if Subs == [] ->
			    {Subs,no_extras};
			length(Subs) /= L ->
			    %% FIXME - match when some subs are hidden?
			    %%io:format("~p: ~p comps but ~p subs~n",[smother_analysis:exp_printer(Exp),length(Comps),length(Subs)]),
			    exit({"Miss-matched params and sub-components.",ContentList,Comps,Subs});
		       true ->
			    ZipList = lists:zip(Subs,ContentList),
			    NewSubs = lists:flatten(lists:map(fun({S,VC}) ->
								      apply_pattern_log(
									erl_parse:normalise(VC)
									,[S]
									,Bindings)
							      end,
							      ZipList)
						   ),
			    {NewSubs, no_extras}
		    end
	       end;
	{nil,_OLine} ->
	    if L /= 0 ->
		    {Subs, empty_list};
	       true ->
		    {Subs, no_extras}
	    end;
	{string,_Line,ValContent} ->
	    if L == 0 ->
		    {Subs,non_empty_list};
	       L /= length(ValContent) ->
		    {Subs,list_size_mismatch};
	       true ->
		    ZipList = lists:zip(Subs,ValContent),
		    NewSubs = lists:flatten(lists:map(fun({S,VC}) ->
							      %% VC will be char codes here so no need to normalise them...
							      apply_pattern_log(
								VC
								,[S]
								,Bindings)
						      end,
						      ZipList)
					   ),
		    {NewSubs, no_extras}
	    end;
	_Val ->
	    %% io:format("~p is not a list...~n",[_Val]),
	    {Subs,not_a_list}
    end;
process_subs(#pat_log{exp={fun_declaration,Loc,Rec},subs=Subs},_Eval,_Bindings) ->
    io:format("Fun pattern: ~p ~p~n",[Loc,Rec]),
    {Subs,no_extras};
process_subs(#pat_log{exp={wrapper,atom,_Attrs,_Image},subs=Subs},_EVal,_Bindings) ->
    {Subs,no_extras};
process_subs(#pat_log{exp={tree,record_expr,_Attrs,{record_expr,none,_NameTree,_Content}},subs=Subs}=_S,{smother_record,Fields,Values},Bindings) ->
    %% Re-ordering the elements of a record shouldn't - of itself - cause a miss-match, so this has to cope with
    %% the element values being in a different order
    ValPairs = lists:zip([smother_record_name|Fields],tuple_to_list(Values)),
    NewSubs = lists:map(fun(#pat_log{exp={tree,record_field,_SAttrs,{record_field,{wrapper,atom,_NAttrs,{atom,_,SubName}},Content}}}=SPL) ->
				   case lists:keyfind(SubName,1,ValPairs) of
				       false ->
					   SPL#pat_log{nmcount = SPL#pat_log.nmcount+1};
				       {SubName,SubEVal} ->
					   %% Apply the binding for this field to an imaginary pattern log that has all the same values, but 
					   %% only the content expression
					   SubSub = hd(apply_pattern_log(SubEVal,[SPL#pat_log{exp=Content}],Bindings)),
					   SubSub#pat_log{exp=SPL#pat_log.exp}
				   end
			end,
			Subs),
    {NewSubs,no_extras};
process_subs(#pat_log{subs=Subs}=_S,_EVal,_Bindings) ->
    %%io:format("Don't know how to process subs for: ~p~nwith ~p under ~p~n", [_S#pat_log.exp,_EVal,_Bindings]),
    {Subs,no_extras}.

make_extras({tree,tuple,_,_}) ->
    [{tuple_size_mismatch,0},{not_a_tuple,0}];
make_extras({tree,list,_Attrs,none}) ->
    [{non_empty_list,0},{not_a_list,0}];
make_extras({tree,list,_Attrs,{list,_,_}}) ->
    [{empty_list,0},{list_size_mismatch,0},{not_a_list,0}];
make_extras(_P) ->
    %%io:format("No extras for ~p~n",[P]),
    [].



list_to_list({nil,_Line}) ->
    [];
list_to_list({cons,_Line,Item,Tail}) ->
    [Item | list_to_list(Tail)].

list_from_list([]) ->
    none;
list_from_list([Item|More]) ->
    {IStart,IEnd} = smother_analysis:get_range(Item),
    {_EndStart,EndLoc} = 
	case More of
	    [] ->
		{IStart,IEnd};
	    _ ->
		smother_analysis:get_range(lists:nth(length(More),More))
	end,
    NewLoc = {IStart,EndLoc},
    {tree,list,{attr,NewLoc,[{range,NewLoc}],none},{list,[Item],list_from_list(More)}}.

fix_ints({integer,Line,Image}) ->
    %% This will crash with non-standard ints such as 16#42 and stuff
    {integer,Line,list_to_integer(Image)};
fix_ints({op,Line,Image,Left,Right}) ->
    {op,Line,Image,fix_ints(Left),fix_ints(Right)};
fix_ints({cons,Line,Head,Tail}) ->
    {cons,Line,fix_ints(Head),fix_ints(Tail)};
fix_ints({tuple,Line,Content}) ->
    {tuple,Line,[fix_ints(C) || C <- Content]};
fix_ints({var,Line,Image}) ->
    {var,Line,Image};
fix_ints(E) ->
    %%io:format("Can't fix ints in ~p~n",[E]),
    E.

fix_lines({Type,_Line,Image}) ->
  {Type,0,Image};
fix_lines({X,_Line,Image,Left,Right}) ->
  {X,0,Image,fix_lines(Left),fix_lines(Right)};
fix_lines({Y,_Line,Head,Tail}) ->
  {Y,0,fix_lines(Head),fix_lines(Tail)};
fix_lines({Z,_Line}) ->
  {Z,0};
fix_lines([]) ->
    [];
fix_lines([X |Xs]) ->
    [fix_lines(X) | fix_lines(Xs)];
fix_lines(E) ->
  %%io:format("Can't fix lines in ~p~n",[E]),
  E.

revert(Exp) ->
    R = wrangler_syntax:revert(Exp),
    fix_lines(fix_ints(R)).

apply_fun_log(_Loc,_LogData,[]) ->
    [];
apply_fun_log(Loc,LogData,[{Loc,Rec} | Ps]) ->
    NewSubs = hd(apply_pattern_log(LogData,[Rec],[])),
    [{Loc,NewSubs} | Ps];
apply_fun_log(Loc,LogData,[{PreLoc,Rec} | Ps]) ->
    NewSubs = hd(apply_pattern_log(LogData,[Rec],[])),
    [{PreLoc,NewSubs} | apply_fun_log(Loc,LogData,Ps)].


de_pid(EVal) ->
    %% PIDs, Ports, and Functions are all non-decmposible so they will just be bound to variables...
    if is_pid(EVal) or is_port(EVal) or is_function(EVal) or is_reference(EVal) ->
	    lists:flatten(io_lib:format("~p",[EVal]));
       is_list(EVal) ->
	    [de_pid(EV) || EV <- EVal];
       is_tuple(EVal) ->
	    list_to_tuple([de_pid(EV) || EV <- tuple_to_list(EVal)]);
       true ->
	    EVal
    end.

abstract_revert(EVal) ->
    try
	DP = de_pid(EVal),
	%%io:format("reverting ~p~n",[DP]),
	erl_syntax:revert(erl_syntax:abstract(DP))
    catch
	error:PIDMsg ->
	    %% PID types can't be abstracted
	    io:format("PID problem: ~p~n",[PIDMsg]),
	    {nil,0}
    end.

	
get_zeros(File) ->
    case analyse(File) of
    	 {error,Msg} ->
  	     {error,Msg};
	 {ok,Analysis} ->
	     smother_analysis:get_zeros(Analysis)
    end.
get_nonzeros(File) ->
    case analyse(File) of
    	 {error,Msg} ->
  	     {error,Msg};
	 {ok,Analysis} ->
	     smother_analysis:get_nonzeros(Analysis)
    end.

get_split(File) ->
  {length(get_zeros(File)),length(get_nonzeros(File))}.

get_percentage(File) ->
    case analyse(File) of
    	 {error,Msg} ->
  	     {error,Msg};
    	 {error,M1,Msg} ->
  	     {error,M1,Msg};
	 {ok,Analysis} ->
	     smother_analysis:get_percentage(Analysis)
    end.


ignore_fallthrough([]) ->
    [];
ignore_fallthrough([Rec=#pat_log{} | []]) ->
    NewRec = Rec#pat_log{nmcount=-1,subs=[],extras=[],matchedsubs=[]},
    [NewRec];
ignore_fallthrough([R | Rs]) ->
    [R | ignore_fallthrough(Rs)].
