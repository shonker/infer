(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd
module L = Logging
open LineageShape.StdModules
module Shapes = LineageShape.Summary
open IOption.Let_syntax
module V = Lineage.Vertex
module E = Lineage.Edge
module G = Lineage.G

let pp_caller_table =
  IFmt.Labelled.iter_bindings ~sep:Fmt.semi Hashtbl.iteri
    (Fmt.pair ~sep:IFmt.colon_sp Procname.pp_verbose
       (Fmt.brackets @@ Fmt.list ~sep:Fmt.sp Procname.pp_verbose) )


(** Returns a hash table associating its callers to each known procname. *)
let create_caller_table () =
  let caller_table = Hashtbl.create (module Procname) in
  let record ~callee ~caller =
    Hashtbl.update caller_table callee ~f:(function
      | None ->
          [caller]
      | Some callers ->
          caller :: callers )
  in
  Summary.OnDisk.iter_specs ~f:(fun {Summary.proc_name; dependencies} ->
      let {Dependencies.summary_loads; other_proc_names} =
        match dependencies with
        | Complete c ->
            c
        | Partial ->
            L.die InternalError "deserialized summary with incomplete dependencies"
      in
      List.iter summary_loads ~f:(fun callee -> record ~callee ~caller:proc_name) ;
      List.iter other_proc_names ~f:(fun callee -> record ~callee ~caller:proc_name) ) ;
  L.debug Report Verbose "@;@[Caller table: @[%a@]@]@;" pp_caller_table caller_table ;
  caller_table


let find_callers caller_table procname =
  match Hashtbl.find caller_table procname with None -> [] | Some callers -> callers


let fetch_shapes procname =
  let* summary = Summary.OnDisk.get ~lazy_payloads:true procname in
  Lazy.force summary.Summary.payloads.lineage_shape


module Todo = struct
  (** Utility module to deal with interprocedural todo nodes *)

  type node =
    | Return of FieldPath.t
    | Argument of int * FieldPath.t
    | ReturnOf of Procname.t * FieldPath.t
    | ArgumentOf of Procname.t * int * FieldPath.t

  let pp_node fmt node =
    match node with
    | Return path ->
        Fmt.pf fmt "ret%a" FieldPath.pp path
    | Argument (index, path) ->
        Fmt.pf fmt "arg%d%a" index FieldPath.pp path
    | ReturnOf (callee, path) ->
        Fmt.pf fmt "%a.ret%a" Procname.pp callee FieldPath.pp path
    | ArgumentOf (callee, index, path) ->
        Fmt.pf fmt "%a.arg%d%a" Procname.pp callee index FieldPath.pp path


  type t = {procname: Procname.t; node: node}

  let to_vertices shapes node =
    match node with
    | Return path ->
        Shapes.map_return shapes path ~f:(fun ret_path -> V.Return ret_path)
    | ReturnOf (callee, path) ->
        Shapes.map_return_of shapes callee path ~f:(fun ret_path -> V.ReturnOf (callee, ret_path))
    | Argument (index, path) ->
        Shapes.map_argument shapes index path ~f:(fun arg_path -> V.Argument (index, arg_path))
    | ArgumentOf (callee, index, path) ->
        Shapes.map_argument_of shapes callee index path ~f:(fun arg_path ->
            V.ArgumentOf (callee, index, arg_path) )


  let return procname = {procname; node= Return []}

  let argument procname arg_index = {procname; node= Argument (arg_index, [])}
end

type todo = Todo.t

let is_sanitizing_e sanitizers edge =
  match E.kind @@ G.E.label edge with
  | Summary {callee; _} ->
      Set.mem sanitizers callee
  | Direct | Call | Return | Capture | Builtin | DynamicCallFunction | DynamicCallModule ->
      false


(** Collects the reachable subgraph from a given source node in the lineage graph of one procedures.
    Returns this subgraph and two lists of nodes from other procedures to explore, the first one
    being reached through Return edges and the second one though Calls.

    If [follow_return] is false then the Return list will be empty (ie. [Return] edges will be
    ignored). *)
let collect_reachable_in_procedure ~sanitizers ~follow_return caller_table ~init:subgraph procname
    graph vertices =
  let rec dfs todo acc_subgraph (return_todo : todo list) (call_todo : todo list) =
    match todo with
    | [] ->
        (acc_subgraph, return_todo, call_todo)
    | vertex :: next ->
        let acc_subgraph', todo', _ =
          G.fold_succ_e
            (fun edge (acc, todo, n) ->
              if n <= 0 || G.mem_edge_e acc edge || is_sanitizing_e sanitizers edge then
                (acc, todo, n)
              else (G.add_edge_e acc edge, G.E.dst edge :: todo, n - 1) )
            graph vertex
            (acc_subgraph, next, Option.value ~default:Int.max_value Config.lineage_limit)
        in
        let return_todo' =
          if follow_return then
            let callers = find_callers caller_table procname in
            match (vertex : V.t) with
            | Return field_path ->
                List.fold callers ~init:return_todo ~f:(fun acc caller ->
                    {Todo.procname= caller; node= ReturnOf (procname, field_path)} :: acc )
            | Local _
            | Argument (_, _)
            | ArgumentOf (_, _, _)
            | Captured _
            | CapturedBy (_, _)
            | ReturnOf _
            | Self
            | Function _ ->
                return_todo
          else return_todo
        in
        let call_todo' =
          match (vertex : V.t) with
          | ArgumentOf (callee, index, field_path) ->
              {Todo.procname= callee; node= Argument (index, field_path)} :: call_todo
          | Local _
          | Argument (_, _)
          | Captured _
          | CapturedBy (_, _)
          | Return _
          | ReturnOf _
          | Self
          | Function _ ->
              call_todo
        in
        dfs todo' acc_subgraph' return_todo' call_todo'
  in
  dfs vertices subgraph [] []


(** Collect the reachable lineage subgraphs from a node over all program procedures. Returns it as a
    map from each procname to its subgraph.

    The result will not traverse paths that include a Call edge followed (even not immediately) by a
    Return edge (but will include the corresponding Summary edges). It works by first collecting all
    the nodes reachable by traversing Return edges, then from this set the ones reachable through
    Call edges but not Return. *)
let collect_reachable caller_table ~sanitizers sources =
  let rec aux ~follow_return (todo : todo list) (todo_later : todo list) acc_graphs =
    match (todo, todo_later) with
    | [], [] ->
        acc_graphs
    | [], _ :: _ ->
        aux ~follow_return:false todo_later [] acc_graphs
    | {procname; node} :: todo_next, _ ->
        if Set.mem sanitizers procname then aux ~follow_return todo_next todo_later acc_graphs
        else
          let summary = Summary.OnDisk.get ~lazy_payloads:true procname in
          let shapes =
            let* summary in
            Lazy.force summary.Summary.payloads.lineage_shape
          in
          let vertices = Todo.to_vertices shapes node in
          let lineage =
            let* summary in
            Lazy.force summary.Summary.payloads.lineage
          in
          let lineage_graph =
            match lineage with
            | None ->
                G.of_vertices vertices
            | Some lineage ->
                Lineage.Summary.graph lineage
          in
          let init_reachable_subgraph =
            match Map.find acc_graphs procname with None -> G.of_vertices vertices | Some g -> g
          in
          let reachable_subgraph, return_todo, call_todo =
            collect_reachable_in_procedure ~sanitizers ~follow_return caller_table procname
              lineage_graph vertices ~init:init_reachable_subgraph
          in
          let acc_reachable_graphs' = Map.set acc_graphs ~key:procname ~data:reachable_subgraph in
          let todo' = List.rev_append return_todo todo_next in
          let todo_later' = List.rev_append call_todo todo_later in
          aux ~follow_return todo' todo_later' acc_reachable_graphs'
  in
  aux ~follow_return:true sources [] (Map.empty (module Procname))


(** Similar to collect_reachable for a subgraph from which you can reach a given node. *)
let collect_coreachable_in_procedure ~init:subgraph caller_table procname graph vertices =
  let rec codfs todo acc_subgraph interproc_todo =
    match todo with
    | [] ->
        (acc_subgraph, interproc_todo)
    | vertex :: next ->
        let fold_pred_e_if_mem_vertex f graph vertex acc =
          (* The interprocedural todo list may have requested to continue the exploration from
             ArgumentOf vertices from which the sink may be reached but not reachable from the
             source. In that case, they won't be present in the reachable subgraph.

             This typically happens when a procedure `h/1` is in a source->sink path when called by
             `f`, but not when called by `g`. Then the co-reachability analysis of `h` will put
             `({f,g}, h$arg0)` on the todo stack, but only `(f, h$arg0)` will exist as a node. *)
          if G.mem_vertex graph vertex then G.fold_pred_e f graph vertex acc else acc
        in
        let acc_subgraph', todo' =
          fold_pred_e_if_mem_vertex
            (fun edge (acc, todo) ->
              if G.mem_edge_e acc edge then (acc, todo)
              else (G.add_edge_e acc edge, G.E.src edge :: todo) )
            graph vertex (acc_subgraph, next)
        in
        let interproc_todo' =
          let callers = find_callers caller_table procname in
          match (vertex : V.t) with
          | Argument (index, field_path) ->
              List.fold callers ~init:interproc_todo ~f:(fun acc caller ->
                  {Todo.procname= caller; node= ArgumentOf (procname, index, field_path)} :: acc )
          | ReturnOf (callee, field_path) ->
              {Todo.procname= callee; node= Return field_path} :: interproc_todo
          | Local _
          | ArgumentOf (_, _, _)
          | Captured _
          | CapturedBy (_, _)
          | Return _
          | Self
          | Function _ ->
              interproc_todo
        in
        codfs todo' acc_subgraph' interproc_todo'
  in
  codfs vertices subgraph []


(** See collect_reachable and collect_coreachable_in_procedure. *)
let collect_coreachable caller_table sinks reachable_graphs =
  let rec aux (todo : todo list) acc_graphs =
    match todo with
    | [] ->
        acc_graphs
    | {procname; node} :: todo_next -> (
      match Map.find reachable_graphs procname with
      | None ->
          (* That node has been added as a caller of some co-reachable function, but it wasn't
             reachable. Skip it.

             TODO: if that function is completely unknown (eg. there is a typo) then the final taint
             graph might be empty, leading the user to falsely believe there is no flow. Check that
             we can efficiently retrieve that information (including on functions with no summary,
             eg. `binary_to_atom`). *)
          aux todo_next acc_graphs
      | Some reachable_graph ->
          let init_coreachable_subgraph =
            match Map.find acc_graphs procname with None -> G.empty | Some subgraph -> subgraph
          in
          let shapes = fetch_shapes procname in
          let vertices = Todo.to_vertices shapes node in
          let coreachable_subgraph, interproc_todo =
            collect_coreachable_in_procedure ~init:init_coreachable_subgraph caller_table procname
              reachable_graph vertices
          in
          let todo' = List.rev_append interproc_todo todo_next in
          aux todo' (Map.set acc_graphs ~key:procname ~data:coreachable_subgraph) )
  in
  aux sinks (Map.empty (module Procname))


let parse_mfa string =
  let module_name, string =
    match String.lsplit2 ~on:':' string with
    | None ->
        ("", string)
    | Some (module_name, rest) ->
        (module_name, rest)
  in
  let* function_name, arity = String.lsplit2 ~on:'/' string in
  let+ arity = int_of_string_opt arity in
  Procname.make_erlang ~module_name ~function_name ~arity


let parse_mfa_exn s =
  match parse_mfa s with Some mfa -> mfa | None -> L.die InternalError "`%s`" s


(** Expects ["[module:]function/arity${ret,argN}"] and returns the corresponding procname and todo
    node. *)
let parse_node string =
  let* mfa, node = String.lsplit2 ~on:'$' string in
  let* procname = parse_mfa mfa in
  if [%equal: string] node "ret" then Some (Todo.return procname)
  else
    let* arg_index = String.chop_prefix ~prefix:"arg" node in
    let* arg_index = int_of_string_opt arg_index in
    Some (Todo.argument procname arg_index)


let parse_node_exn name string =
  match parse_node string with
  | Some node ->
      node
  | None ->
      L.die UserError "%s: invalid format. Expected `mod:fun/arity${ret,argN}, got `%s`." name
        string


let report_graph_map filename_parts graphs =
  let filename = Filename.of_parts (Config.results_dir :: filename_parts) in
  Unix.mkdir_p (Filename.dirname filename) ;
  Out_channel.with_file filename ~f:(fun outchan ->
      Map.iteri
        ~f:(fun ~key:procname ~data:subgraph ->
          match Procdesc.load procname with
          | None ->
              (* We can't report a graph if we don't have a procdesc. This should only happen when
                 the graph contains only an argument or the return of a function without summary,
                 typically used as a source or sink. In that case the corresponding node will anyway
                 still be reported as ArgumentOf/ReturnOf within another callee procedure. *)
              if G.nb_edges subgraph <> 0 then
                L.die InternalError
                  "Unexpected non-singleton taint graph for procname %a without description"
                  Procname.pp procname
          | Some proc_desc ->
              Lineage.Out.report_graph outchan proc_desc subgraph )
        graphs )


let report ~lineage_source ~lineage_sink ~lineage_sanitizers =
  let source = parse_node_exn "lineage-source" lineage_source in
  let sink = parse_node_exn "lineage-sink" lineage_sink in
  let sanitizers = Set.of_list (module Procname) (List.map ~f:parse_mfa_exn lineage_sanitizers) in
  let caller_table = create_caller_table () in
  let reachable_graphs = collect_reachable caller_table ~sanitizers [source] in
  if Config.debug_mode then
    report_graph_map ["lineage-taint-debug"; "lineage-reachable.json"] reachable_graphs ;
  let coreachable_graphs = collect_coreachable caller_table [sink] reachable_graphs in
  report_graph_map ["lineage-taint"; "lineage-taint.json"] coreachable_graphs


module Private = struct
  module Todo = Todo

  let parse_node = parse_node
end
