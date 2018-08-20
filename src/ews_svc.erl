%%  ews_svc
%%
%% >-----------------------------------------------------------------------< %%

-module(ews_svc).

-export([start_link/0]).

-export([add_wsdl_url/2, add_wsdl_bin/2,
         list_services/0, list_services/1,
         list_service_ops/1, list_service_ops/2,
         get_op_info/2, get_op_info/3,
         get_op/2, get_op/3,
         get_op_message_details/2, get_op_message_details/3,
         list_types/1, get_type/2,
         get_model/1, get_service_models/1,
         list_simple_clashes/1, list_full_clashes/1, emit_model/2,
         call/4, call/5, call/6,
         add_pre_hook/2, remove_pre_hook/2,
         add_post_hook/2, remove_post_hook/2,
         remove_model/1]).

-export([init/1, handle_call/3, handle_cast/2,
         handle_info/2, code_change/3, terminate/2]).

-behaviour(gen_server).

-record(state, {services=#{}, models=#{}, service_index=#{}}).

-include("ews.hrl").

%% >-----------------------------------------------------------------------< %%

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

add_wsdl_url(ModelRef, WsdlUrl) ->
    gen_server:call(?MODULE, {add_wsdl_url, ModelRef, WsdlUrl},
                    timer:minutes(1)).

add_wsdl_bin(ModelRef, WsdlBin) ->
    gen_server:call(?MODULE, {add_wsdl_bin, ModelRef, WsdlBin},
                    timer:minutes(1)).

list_services() ->
    gen_server:call(?MODULE, list_services).

list_services(ModelRef) ->
    gen_server:call(?MODULE, {list_services, ModelRef}).

list_service_ops(Service) ->
    gen_server:call(?MODULE, {list_service_ops, Service}).

list_service_ops(ModelRef, Service) ->
    gen_server:call(?MODULE, {list_service_ops, ModelRef, Service}).

get_op_info(Service, Op) ->
    gen_server:call(?MODULE, {get_op_info, Service, Op}).

get_op_info(ModelRef, Service, Op) ->
    gen_server:call(?MODULE, {get_op_info, ModelRef, Service, Op}).

get_op(Service, Op) ->
    gen_server:call(?MODULE, {get_op, Service, Op}).

get_op(ModelRef, Service, Op) ->
    gen_server:call(?MODULE, {get_op, ModelRef, Service, Op}).

get_op_message_details(Service, Op) ->
    gen_server:call(?MODULE, {get_op_message_details, Service, Op}).

get_op_message_details(ModelRef, Service, Op) ->
    gen_server:call(?MODULE, {get_op_message_details, ModelRef, Service, Op}).

list_types(ModelRef) ->
    gen_server:call(?MODULE, {list_types, ModelRef}).

get_type(ModelRef, TypeKey) ->
    gen_server:call(?MODULE, {get_type, ModelRef, TypeKey}).

get_service_models(ServiceName) ->
    gen_server:call(?MODULE, {get_service_models, ServiceName}).

get_model(ModelRef) ->
    gen_server:call(?MODULE, {get_model, ModelRef}).

list_full_clashes(ModelRef) ->
    gen_server:call(?MODULE, {list_clashes, ModelRef}).

list_simple_clashes(Model) ->
    F = fun({Ns, N}, D) -> dict:append(N, Ns, D) end,
    TypeList = dict:to_list(lists:foldl(F, dict:new(),
                                        ews_svc:list_types(Model))),
    [ Qname || Qname = {_, Nss} <- lists:usort(TypeList), length(Nss) > 1 ].

emit_model(ModelRef, File) ->
    gen_server:call(?MODULE, {emit_model, ModelRef, File}).

call(ServiceName, OpName, HeaderParts, BodyParts) ->
    call(ServiceName, OpName, HeaderParts, BodyParts, undefined).

call(ModelRef, ServiceName, OpName, HeaderParts, BodyParts)
  when is_atom(ModelRef) ->
    call(ModelRef, ServiceName, OpName, HeaderParts, BodyParts, undefined);
call(ServiceName, OpName, HeaderParts, BodyParts, Opaque)
  when is_list(ServiceName) ->
    case gen_server:call(?MODULE, {get_service_models, ServiceName}) of
        [{ModelRef, Model}] ->
            call_service_op(ModelRef, Model, ServiceName, OpName,
                            HeaderParts, BodyParts, Opaque);
        [] ->
            {error, no_service};
        [_ | _] ->
            {error, ambiguous_service}
    end.

call(ModelRef, ServiceName, OpName, HeaderParts, BodyParts, Opaque) ->
    Model = gen_server:call(?MODULE, {get_model, ModelRef}),
    call_service_op(ModelRef, Model, ServiceName, OpName,
                    HeaderParts, BodyParts, Opaque).

add_pre_hook(ModelRef, Hook) ->
    gen_server:call(?MODULE, {add_pre_hook, ModelRef, Hook}).
add_post_hook(ModelRef, Hook) ->
    gen_server:call(?MODULE, {add_post_hook, ModelRef, Hook}).
remove_pre_hook(ModelRef, HookRef) ->
    gen_server:call(?MODULE, {remove_pre_hook, ModelRef, HookRef}).
remove_post_hook(ModelRef, HookRef) ->
    gen_server:call(?MODULE, {remove_post_hook, ModelRef, HookRef}).

remove_model(ModelRef) ->
    gen_server:call(?MODULE, {remove_model, ModelRef}).

%% >-----------------------------------------------------------------------< %%

init([]) ->
    {ok, #state{}}.

handle_call({add_wsdl_url, ModelRef, WsdlUrl}, S, State) ->
    WsdlDoc = ews_wsdl:fetch(WsdlUrl),
    handle_call({add_wsdl_bin, ModelRef, WsdlDoc}, S, State);
handle_call({add_wsdl_bin, ModelRef, WsdlDoc}, _, State) ->
    #state{services=OldSvcs, models=OldModels, service_index=OldSvcIdx} = State,
    OldModel = maps:get(ModelRef, OldModels, undefined),
    OldModelSvcs = maps:get(ModelRef, OldSvcs, []),
    OldSvcNames = [N || {N, _} <- OldModelSvcs],
    Wsdl = #wsdl{types=Model} = ews_wsdl:parse(WsdlDoc, ModelRef),
    Svcs = compile_wsdl(Wsdl),
    NewSvcs = OldSvcs#{ModelRef => lists:ukeysort(1, Svcs++OldModelSvcs)},
    NewSvcNames = [N || {N, _} <- Svcs],
    NewModels = OldModels#{ModelRef => ews_model:append_model(OldModel, Model,
                                                              ModelRef)},
    NewSvcIdx = update_service_index(OldSvcIdx, ModelRef,
                                     NewSvcNames -- OldSvcNames),
    Count = [ {N, length(Ops)} || {N, Ops} <- Svcs ],
    NewState = State#state{services=NewSvcs, models=NewModels,
                           service_index=NewSvcIdx},
    {reply, {ok, Count}, NewState};
handle_call(list_services, _, #state{services=Svcs} = State) ->
    MRefs = maps:keys(Svcs),
    {reply, {ok, [{M, N} || M <- MRefs, {N, _} <- maps:get(M, Svcs)]}, State};
handle_call({list_services, ModelRef}, _, #state{services=Svcs} = State) ->
    ModelSvcs = maps:get(ModelRef, Svcs, []),
    {reply, {ok, [ N || {N, _} <- ModelSvcs ]}, State};
handle_call({list_service_ops, Svc}, From, State) ->
    case get_service_models(Svc, State) of
        [{ModelRef, _}] ->
            handle_call({list_service_ops, ModelRef, Svc}, From, State);
        [] ->
            {reply, {error, no_service}, State};
        [_ | _] ->
            {reply, {error, ambiguous_service}, State}
    end;
handle_call({list_service_ops, ModelRef, Svc}, _,
            #state{services=Svcs} = State) ->
    ModelSvcs = maps:get(ModelRef, Svcs, []),
    case lists:keyfind(Svc, 1, ModelSvcs) of
        false ->
            {reply, {error, no_service}, State};
        {Svc, Ops} ->
            Names = [ N || #op{name=N} <- Ops ],
            {reply, {ok, Names}, State}
    end;
handle_call({get_op_info, SvcName, OpName}, From, State) ->
    case get_service_models(SvcName, State) of
        [{ModelRef, _}] ->
            handle_call({get_op_info, ModelRef, SvcName, OpName}, From, State);
        [] ->
            {reply, {error, no_service}, State};
        [_ | _] ->
            {reply, {error, ambiguous_service}, State}
    end;
handle_call({get_op_info, ModelRef, SvcName, OpName}, _, State) ->
    #state{services=Svcs, models=Models} = State,
    ModelSvcs = maps:get(ModelRef, Svcs, []),
    Model = maps:get(ModelRef, Models, undefined),
    {reply, find_op(SvcName, OpName, ModelSvcs, Model), State};
handle_call({get_op, SvcName, OpName}, From, State) ->
    case get_service_models(SvcName, State) of
        [{ModelRef, _}] ->
            handle_call({get_op, ModelRef, SvcName, OpName}, From, State);
        [] ->
            {reply, {error, no_service}, State};
        [_ | _] ->
            {reply, {error, ambiguous_service}, State}
    end;
handle_call({get_op, ModelRef, SvcName, OpName}, _,
            #state{services=Svcs} = State) ->
    ModelSvcs = maps:get(ModelRef, Svcs, []),
    case lists:keyfind(SvcName, 1, ModelSvcs) of
        false ->
            {reply, {error, no_service}, State};
        {SvcName, Ops} ->
            case lists:keyfind(OpName, #op.name, Ops) of
                false ->
                    {reply, {error, no_op}, State};
                Op ->
                    {reply, {ok, Op}, State}
            end
    end;
handle_call({get_op_message_details, SvcName, OpName}, From, State) ->
    case get_service_models(SvcName, State) of
        [{ModelRef, _}] ->
            handle_call({get_op_message_details,
                         ModelRef, SvcName, OpName}, From, State);
        [] ->
            {reply, {error, no_service}, State};
        [_ | _] ->
            {reply, {error, ambiguous_service}, State}
    end;
handle_call({get_op_message_details, ModelRef, SvcName, OpName}, _, State) ->
    #state{services=Svcs, models=Models} = State,
    ModelSvcs = maps:get(ModelRef, Svcs, []),
    Model = maps:get(ModelRef, Models, undefined),
    case lists:keyfind(SvcName, 1, ModelSvcs) of
        false ->
            {reply, {error, no_service}, State};
        {SvcName, Ops} ->
            case lists:keyfind(OpName, #op.name, Ops) of
                false ->
                    {reply, {error, no_op}, State};
                Op ->
                    {reply, {ok, message_info(Op, Model)}, State}
            end
    end;
handle_call({list_clashes, ModelRef}, _, #state{models=Models} = State) ->
    case maps:get(ModelRef, Models, undefined) of
        undefined ->
            {reply, [], State};
        #model{clashes = Clashes} ->
            {reply, dict:to_list(Clashes), State}
    end;
handle_call({list_types, ModelRef}, _, #state{models=Models} = State) ->
    case maps:get(ModelRef, Models, undefined) of
        undefined ->
            {reply, [], State};
        #model{type_map = Map} ->
            {reply, ews_model:keys(Map), State}
    end;
handle_call({get_type, ModelRef, Key}, _,
            #state{models=Models} = State) ->
    #model{type_map=Map} = maps:get(ModelRef, Models),
    {reply, ews_model:get(Key, Map), State};
handle_call({emit_model, ModelRef, File}, _, #state{models=Models} = State) ->
    case maps:get(ModelRef, Models, undefined) of
        undefined ->
            {reply, {error, no_model}, State};
        Model ->
            {reply, ews_emit:model_to_file(Model, File, ModelRef), State}
    end;
handle_call({get_service_models, ServiceName}, _, State) ->
    {reply, get_service_models(ServiceName, State), State};
handle_call({get_model, ModelRef}, _, #state{models=Models} = State) ->
    {reply, maps:get(ModelRef, Models, undefined), State};
handle_call({add_pre_hook, ModelRef, Hook}, _, #state{models=Models} = State) ->
    Model = maps:get(ModelRef, Models),
    OldHooks = Model#model.pre_hooks,
    Ref = make_ref(),
    NewModel = Model#model{pre_hooks = [{Ref, Hook} | OldHooks]},
    {reply, Ref, State#state{models = Models#{ModelRef => NewModel}}};
handle_call({add_post_hook, ModelRef, Hook}, _,
            #state{models=Models} = State) ->
    Model = maps:get(ModelRef, Models),
    OldHooks = Model#model.post_hooks,
    Ref = make_ref(),
    NewModel = Model#model{post_hooks = [{Ref, Hook} | OldHooks]},
    {reply, Ref, State#state{models = Models#{ModelRef => NewModel}}};
handle_call({remove_pre_hook, ModelRef, HookRef}, _,
            #state{models=Models} = State) ->
    Model = maps:get(ModelRef, Models),
    OldHooks = Model#model.pre_hooks,
    NewModel = Model#model{pre_hooks = proplists:delete(HookRef, OldHooks)},
    {reply, ok, State#state{models = Models#{ModelRef => NewModel}}};
handle_call({remove_post_hook, ModelRef, HookRef}, _,
            #state{models=Models} = State) ->
    Model = maps:get(ModelRef, Models),
    OldHooks = Model#model.post_hooks,
    NewModel = Model#model{post_hooks = proplists:delete(HookRef, OldHooks)},
    {reply, ok, State#state{models = Models#{ModelRef => NewModel}}};
handle_call({remove_model, ModelRef}, _, State) ->
    #state{models = Models, services = Svcs, service_index = SvcIdx} = State,
    NewModels = maps:remove(ModelRef, Models),
    NewSvcs = maps:remove(ModelRef, Svcs),
    NewSvcIdx = maps:fold(fun (Svc, ModelRefs, Acc) ->
                                  case ModelRefs -- [ModelRef] of
                                      [] ->
                                          Acc;
                                      NewModelRefs ->
                                          Acc#{Svc => NewModelRefs}
                                  end
                          end, #{}, SvcIdx),
    NewState = State#state{models = NewModels, services = NewSvcs,
                           service_index = NewSvcIdx},
    {reply, ok, NewState};
handle_call(_, _, State) ->
    {noreply, State}.

handle_cast(_Msg, #state{} = State) ->
    {noreply, State}.

handle_info(_Msg, #state{} = State) ->
    {noreply, State}.

terminate(_Reason, #state{} = _State) ->
    ok.

code_change(_OldVsn, #state{} = State, _Extra) ->
    {ok, State}.

%% >-----------------------------------------------------------------------< %%

compile_wsdl(Wsdl) ->
    #wsdl{services=Services,
          messages=Messages,
          port_types=PortTypes,
          bindings=Bindings} = Wsdl,
    [ compile_ops(S, Messages, PortTypes, Bindings) || S <- Services ].

compile_ops(#service{name=Name, ports=[Port]}, Messages, PortTypes, Bindings) ->
    #port{endpoint=Endpoint, binding=Binding} = Port,
    case lists:keyfind(Binding, #binding.name, Bindings) of
        #binding{port_type=PortType,
                 style=Style,
                 ops=BindingOps,
                 transport="http://schemas.xmlsoap.org/soap/http"} ->
            case lists:keyfind(PortType, #port_type.name, PortTypes) of
                #port_type{ops=PortOps} ->
                    {Name, compile_ops(Endpoint, Style, Messages,
                                       BindingOps, PortOps)};
                false ->
                    {error, binding_lacks_port_type}
            end;
        false ->
            {error, service_lack_soap_binding}
    end.

compile_ops(EndPoint, Style, Messages, BindingOps, PortOps) ->
   [ compile_op(O, EndPoint, Style, Messages, BindingOps) || O <- PortOps ].

compile_op(PortOp, EndPoint, Style, Messages, BindingOps) ->
    #port_type_op{name=Name,
                  doc=Doc,
                  input={_InputName, InputMessageRef},
                  output={_OutputName, OutputMessageRef},
                  faults=Faults} = PortOp,
    BindingOp = lists:keyfind(Name, #binding_op.name, BindingOps),
    {InputHeaderMsg, OutputHeaderMsg} = determine_headers(BindingOp, Messages),
    InputMsg = lists:keyfind(InputMessageRef, #message.name, Messages),
    OutputMsg = lists:keyfind(OutputMessageRef, #message.name, Messages),
    SoapAction = BindingOp#binding_op.action,
    #op{name=Name, doc=Doc,
        input={InputHeaderMsg, InputMsg},
        output={OutputHeaderMsg, OutputMsg},
        faults=[ lists:keyfind(F, #message.name, Messages) || {_,F} <- Faults ],
        style=Style, endpoint=EndPoint, action=SoapAction}.

determine_headers(#binding_op{input=Input, output=Output}, Messages) ->
    #binding_op_msg{headers=[#op_part{message=InputHdrMsg}|_]} = Input,
    #binding_op_msg{headers=[#op_part{message=OutputHdrMsg}|_]} = Output,
    {lists:keyfind(InputHdrMsg, #message.name, Messages),
     lists:keyfind(OutputHdrMsg, #message.name, Messages)}.

%% >-----------------------------------------------------------------------< %%

update_service_index(SvcIdx, ModelRef, NewSvcs) ->
    lists:foldl(fun (Svc, SI) ->
                        case SI of
                            #{Svc := L} ->
                                SI#{Svc => [ModelRef | L]};
                            _ ->
                                SI#{Svc => [ModelRef]}
                        end
                end, SvcIdx, NewSvcs).

find_op(SvcName, OpName, Svcs, Model) ->
    case lists:keyfind(SvcName, 1, Svcs) of
        false ->
            {error, no_service};
        {SvcName, Ops} ->
            case lists:keyfind(OpName, #op.name, Ops) of
                false ->
                    {error, no_op};
                Op ->
                    {ok, op_info(Op, Model)}
            end
    end.

op_info(Op, Model) ->
    #op{name=OpName,
        doc=Doc,
        input=InputMsg,
        output=OutputMsg,
        faults=FaultMsgs,
        endpoint=Endpoint,
        action=Action} = Op,
    {#message{parts=InHdrParts}, #message{parts=InParts}} = InputMsg,
    {#message{parts=OutHdrParts}, #message{parts=OutParts}} = OutputMsg,
    InHdrs = [ type_info(E, Model) || #part{element=E} <- InHdrParts ],
    OutHdrs = [ type_info(E, Model) || #part{element=E} <- OutHdrParts ],
    Ins = [ type_info(E, Model) || #part{element=E} <- InParts ],
    Outs = [ type_info(E, Model) || #part{element=E} <- OutParts ],
    Faults = [ type_info(E, Model) || #message{parts=Parts} <- FaultMsgs,
                                      #part{element=E} <- Parts ],
    [{name, OpName}, {doc, Doc},
     {in, Ins}, {in_hdr, InHdrs},
     {out, Outs}, {out_hdr, OutHdrs}, {fault, Faults},
     {endpoint, Endpoint}, {action, Action}].

type_info(ElemName, #model{type_map=Tbl}) ->
    case ews_model:get_elem(ElemName, Tbl) of
        false ->
            {error, not_root_elem};
        #elem{qname={_, N}, type={_,_}=TypeName} ->
            {N, TypeName};
        #elem{qname={_, N}, type=#base{}=Base} ->
            {N, Base};
        #elem{qname={_, N}, type=#enum{}=Enum} ->
            {N, Enum}
    end.

message_info(Op, Model) ->
    #op{name=OpName,
        doc=Doc,
        input=InputMsg,
        output=OutputMsg,
        faults=FaultMsgs,
        endpoint=Endpoint,
        action=Action} = Op,
    {#message{parts=InHdrParts}, #message{parts=InParts}} = InputMsg,
    {#message{parts=OutHdrParts}, #message{parts=OutParts}} = OutputMsg,
    InHdrs = [ E || #part{element=E} <- InHdrParts ],
    OutHdrs = [ E || #part{element=E} <- OutHdrParts ],
    Ins = [ E || #part{element=E} <- InParts ],
    Outs = [ E || #part{element=E} <- OutParts ],
    Faults = [ E || #message{parts=Parts} <- FaultMsgs,
                                      #part{element=E} <- Parts ],
    PreHooks = Model#model.pre_hooks,
    PostHooks = Model#model.post_hooks,
    [{name, OpName}, {doc, Doc},
     {in, [ find_elem(I, Model) || I <- Ins ]},
     {in_hdr, [ find_elem(I, Model) || I <- InHdrs ]},
     {out, [ find_elem(O, Model) || O <- Outs ]},
     {out_hdr, [ find_elem(O, Model) || O <- OutHdrs ]},
     {faults,  [ find_elem(F, Model) || F <- Faults ]},
     {pre_hooks, PreHooks}, {post_hooks, PostHooks},
     {endpoint, Endpoint}, {action, Action}].

find_elem(Qname, #model{type_map=Tbl}) ->
    case ews_model:get_elem(Qname, Tbl) of
        false ->
            {error, not_root_elem};
        #elem{} = E ->
            E
    end.

%% >-----------------------------------------------------------------------< %%
get_service_models(ServiceName,
                   #state{models=Models, service_index=SvcIndex}) ->
    ModelRefs = maps:get(ServiceName, SvcIndex, []),
    [{MRef, maps:get(MRef, Models)} || MRef <- ModelRefs].

%% >-----------------------------------------------------------------------< %%
%% TODO: Verify that # headers and body parts are same as message parts,
%%       could/should be done in the verify step
%% TODO: Serialize headers
%% TODO: Simplify ews_model module. Maybe use a named ets.
call_service_op(ModelRef, Model, ServiceName, OpName,
                HeaderParts, BodyParts, Opaque) ->
    case get_op_message_details(ModelRef, ServiceName, OpName) of
        {error, Error} ->
            {error, Error};
        {ok, Info} ->
            InHdrs = proplists:get_value(in_hdr, Info),
            EncodedHeader = ews_serialize:encode(HeaderParts, InHdrs, Model),
            Ins = proplists:get_value(in, Info),
            Endpoint = proplists:get_value(endpoint, Info),
            Action = proplists:get_value(action, Info),
            EncodedBody = ews_serialize:encode(BodyParts, Ins, Model),
            PreHooks = proplists:get_value(pre_hooks, Info),
            PostHooks = proplists:get_value(post_hooks, Info),
            HookArgs = [Opaque, Endpoint, Action, EncodedHeader, EncodedBody],
            [NewOpaque | Args] = run_hooks(PreHooks, HookArgs),
            case apply(ews_soap, call, Args) of
                {error, Error} ->
                    {error, Error};
                {ok, {ResponseHeader, ResponseBody}} ->
                    PostHookArgs = [NewOpaque, ResponseHeader, ResponseBody],
                    [_LastOpaque, _NewHeader, NewBody] =
                        run_hooks(PostHooks, PostHookArgs),
                    Outs = proplists:get_value(out, Info),
                    {ok, hd(ews_serialize:decode(NewBody, Outs, Model))};
                {fault, #fault{detail=undefined} = Fault} ->
                    {error, Fault};
                {fault, #fault{detail=Detail} = Fault} ->
                    Faults = proplists:get_value(faults, Info),
                    DecodedDetail = try_decode_fault(Faults, Detail, Model),
                    {error, Fault#fault{detail=DecodedDetail}}
            end
    end.

run_hooks(Hooks, Init) ->
    lists:foldr(fun ({_Ref, Hook}, Arg) -> Hook(Arg) end, Init, Hooks).

try_decode_fault([], Detail, _) ->
    Detail;
try_decode_fault([F|Faults], Detail, Model) ->
    case catch ews_serialize:decode(Detail, [F], Model) of
        {'EXIT',_} ->
            try_decode_fault(Faults, Detail, Model);
        DecodedDetail ->
            DecodedDetail
    end.
