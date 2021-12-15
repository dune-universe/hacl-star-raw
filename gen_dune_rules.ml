let print_header () =
  Format.printf "@[<v>;; This file was auto-generated by [%s]@,@,@]" __FILE__

type generation_mode = Lib | Lib_gen

let chop_suffix_opt name ~suffix =
  match Filename.check_suffix name suffix with
  | false -> None
  | true -> Some (Filename.chop_suffix name suffix)

let root_lib = "hacl-star-raw"
let inner_lib = Printf.sprintf "%s.%s" root_lib
let evercrypt_lib = inner_lib "ocamlevercrypt"

module Item = struct
  let list_of_dir path =
    Sys.readdir path
    |> Array.to_list
    |> List.filter_map (chop_suffix_opt ~suffix:"_bindings.ml")
    |> List.sort String.compare

  let s = Printf.sprintf
  let gen_module = s "%s_gen"
  let gen_exe = s "%s_gen.exe"
  let stubs_module = s "%s_stubs"
  let stubs_file = s "%s_stubs.ml"
  let c_stubs_module = s "%s_c_stubs"
  let c_stubs_file = s "%s_c_stubs.c"
  let bindings_module = s "%s_bindings"
  let bindings_lib = s "%s.%s_bindings" root_lib
  let stubs_lib = s "%s.%s_stubs" root_lib
end

module Sexp = struct
  type t = List of t list | Atom of string

  let atom x = Atom x
  let list x = List x
  let atoms xs = list (List.map atom xs)
  let field_s x xs = list (atom x :: xs)
  let field x xs = field_s x (List.map atom xs)

  let rec pp =
    let rec pp_list ppf = function
      | [] -> ()
      | [ x ] -> Format.fprintf ppf "%a" pp x
      | x :: xs -> Format.fprintf ppf "%a@ %a" pp x pp_list xs
    in
    fun ppf -> function
      | List l -> Format.fprintf ppf "@[<hv 1>(%a)@]" pp_list l
      | Atom s -> Format.pp_print_string ppf s

  let print_stanza ?header name fields =
    let t = list (atom name :: fields) in
    (match header with
    | Some s ->
        Format.printf
          "@[<v 0>;; -------------------------------------------------@,\
           ;;   %s@,\
           ;; -------------------------------------------------@,\
           @]@."
          s
    | None -> ());
    Format.printf "%a@.@." pp t
end

module Lib_gen = struct
  let executable item =
    let open Sexp in
    print_stanza "executable"
      [ field "name" [ Item.gen_module item ]
      ; field "modules" [ Item.gen_module item ]
      ; field "libraries"
          [ "ctypes"; "ctypes.stubs"; evercrypt_lib; Item.bindings_lib item ]
      ]

  let print_stanzas = List.iter executable
end

module Lib = struct
  let global_stanzas libraries =
    let open Sexp in
    print_stanza "library"
      [ field "name" [ "hacl_star_raw" ]
      ; field "public_name" [ root_lib ]
      ; field_s "modules" []
      ; field_s "libraries"
          (List.map (fun n -> field "re_export" [ n ]) libraries)
      ];

    print_stanza "alias"
      [ field "name" [ "foreign_headers" ]
      ; field_s "deps" [ atoms [ "glob_files"; "../*.h" ] ]
      ]

  let bindings_library deps item =
    let open Sexp in
    print_stanza ~header:item "library"
      [ field "name" [ item ]
      ; field "modules" [ Item.bindings_module item ]
      ; field "public_name" [ Item.bindings_lib item ]
      ; field "wrapped" [ "false" ]
      ; field_s "flags"
          [ atoms [ ":standard"; "-w"; "-27-33"; "-warn-error"; "-A" ] ]
      ; field "libraries" ([ "ctypes"; "ctypes.stubs" ] @ deps)
      ]

  let stubs_library item =
    let open Sexp in
    let local_name =
      if Sys.file_exists (item ^ ".c") then [ " " ^ item ^ ".o" ] else []
    in
    print_stanza "library"
      [ field "name" [ Item.stubs_module item ]
      ; field "modules" [ Item.stubs_module item ]
      ; field "public_name" [ Item.stubs_lib item ]
      ; field "wrapped" [ "false" ]
      ; field "libraries" [ "ctypes"; evercrypt_lib ]
      ; field_s "foreign_stubs"
          [ field "language" [ "c" ]
          ; field "names" [ Item.c_stubs_module item ]
          ; field_s "extra_deps"
              [ atoms ([ "alias"; "foreign_headers" ] @ local_name) ]
          ; field_s "flags" [ atoms [ ":include"; "dune.cflags" ] ]
          ; field "include_dirs"
              [ "."; "./kremlin/include"; "./kremlin/kremlib/dist/minimal" ]
          ]
      ]

  let stubgen_rule item =
    let open Sexp in
    print_stanza "rule"
      [ field "targets" [ Item.c_stubs_file item; Item.stubs_file item ]
      ; field_s "action"
          [ field_s "chdir"
              [ atom "../"; field "run" [ "lib_gen/" ^ Item.gen_exe item ] ]
          ]
      ]

  let print_stanzas deps modules =
    let libraries =
      List.concat_map
        (fun n -> [ Item.bindings_lib n; Item.stubs_lib n ])
        modules
    in
    global_stanzas libraries;
    ListLabels.iter modules ~f:(fun item ->
        let deps = Hashtbl.find deps (Item.bindings_lib item) in
        bindings_library deps item;
        stubs_library item;
        stubgen_rule item)
end

let read_dependencies path =
  let extra_deps = [ (Item.bindings_lib "Lib_RandomBuffer_System", []) ] in
  let ic = Scanf.Scanning.open_in path in
  let () = Scanf.bscanf ic "%_s@\n" () in
  let depends = Hashtbl.create 0 in
  let lib_name n =
    try Scanf.sscanf n "lib/%s@.cmx" (fun x -> Some (inner_lib x)) with
    | Scanf.Scan_failure _ -> None
    | End_of_file -> None
  in
  let rec process_lines () =
    Scanf.bscanf ic "%s@\n" @@ fun line ->
    let line = line ^ "\n" in
    Scanf.sscanf line "%s@: %s@\n" @@ fun target deps ->
    (match lib_name target with
    | None -> ()
    | Some target ->
        let deps = String.split_on_char ' ' deps |> List.filter_map lib_name in
        Hashtbl.add depends target deps);
    if not (Scanf.Scanning.end_of_input ic) then process_lines ()
  in
  process_lines ();
  List.iter (fun (k, v) -> Hashtbl.add depends k v) extra_deps;
  depends

let () =
  let mode, deps_path =
    match Sys.argv with
    | [| _; "--dir"; "lib"; deps_path |] -> (Lib, deps_path)
    | [| _; "--dir"; "lib-gen"; deps_path |] -> (Lib_gen, deps_path)
    | _ ->
        Format.eprintf "Usage: %s --dir [lib | lib-gen] <ctypes.depend>"
          Sys.argv.(0);
        exit 1
  in
  let items = Item.list_of_dir "../lib" in
  print_header ();
  match mode with
  | Lib_gen -> Lib_gen.print_stanzas items
  | Lib ->
      let deps = read_dependencies deps_path in
      Lib.print_stanzas deps items
