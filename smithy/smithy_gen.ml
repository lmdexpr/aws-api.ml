(* Emits, for one service: a record type per structure and union, one module per
   operation. Serialization is left to ppx_yojson_conv; enums are strings; error shapes are
   not generated (runtime/error.ml covers them). *)

open Yojson.Safe.Util

type shape = { id : string; kind : string; json : Yojson.Safe.t }

let local id = match String.split_last ~sep:"#" id with Some (_, n) -> n | None -> id
let trait name json = match member "traits" json with `Assoc _ as t -> member name t | _ -> `Null
let has_trait name json = trait name json <> `Null

let keywords =
  String.split_on_char ' '
    "and as assert asr begin class constraint do done downto else end exception external false for \
     fun function functor if in include inherit initializer land lazy let lor lsl lsr lxor match \
     method mod module mutable new nonrec object of open or private rec sig struct then to true \
     try type val virtual when while with"

(* GetParameterRequest -> get_parameter_request, DocumentARN -> document_arn. *)
let snake name =
  let b = Buffer.create (String.length name * 2) in
  String.iteri
    (fun i c ->
      let upper c = Char.lowercase_ascii c <> c in
      let prev_lower = i > 0 && (not (upper name.[i - 1])) && name.[i - 1] <> '_' in
      let next_lower = i + 1 < String.length name && not (upper name.[i + 1]) in
      if upper c && i > 0 && (prev_lower || next_lower) then Buffer.add_char b '_';
      Buffer.add_char b (Char.lowercase_ascii c))
    name;
  let s = Buffer.contents b in
  let s = if List.mem s keywords then s ^ "_" else s in
  (* Names go into source as identifiers, so they are parsed as such, not trusted. *)
  let ident = function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false in
  if s = "" || (not (String.for_all ident s)) || (s.[0] >= '0' && s.[0] <= '9') then
    failwith (Printf.sprintf "%S: not an OCaml identifier after snake_case" name);
  s

(* Names the generated module defines before the model's: a shape or operation mapping onto
   one would shadow it, and two shapes mapping onto one identifier would silently merge. *)
(* Constructors share the value namespace with [protocol] and [make]. *)
let reserved_types = [ "t"; "protocol"; "make" ]
let reserved_modules = [ "error"; "wire"; "transport"; "def" ]

(* Goes into the host name. *)
let host_label s =
  if s <> "" && String.for_all (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false) s
  then
    s
  else
    failwith (Printf.sprintf "%S: not a host label" s)

let check_unique ?(reserved = []) what names =
  let sorted = List.sort compare names in
  let rec go = function
    | a :: (b :: _ as rest) ->
      if a = b then failwith (Printf.sprintf "%s: %S is generated twice" what a);
      go rest
    | _ -> ()
  in
  go sorted;
  List.iter
    (fun n -> if List.mem n reserved then failwith (Printf.sprintf "%s: %S is reserved" what n))
    names

let () =
  let path = Sys.argv.(1) in
  let shapes =
    Yojson.Safe.from_file path |> member "shapes" |> to_assoc
    |> List.map (fun (id, json) -> id, { id; kind = json |> member "type" |> to_string; json })
  in
  let shape id = List.assoc id shapes in
  let service = List.find (fun (_, s) -> s.kind = "service") shapes |> snd in
  let rec type_expr id =
    match local id, id with
    | ( (( "String" | "Integer" | "Long" | "Boolean" | "Float" | "Double" | "Timestamp" | "Blob"
         | "Document" | "Unit" | "PrimitiveBoolean" | "PrimitiveInteger" | "PrimitiveLong" | "Short"
         | "Byte" | "BigInteger" | "BigDecimal" ) as name),
        id )
      when String.starts_with ~prefix:"smithy.api#" id ->
      prelude name
    | _, id -> (
      let s = shape id in
      match s.kind with
      | "string" | "enum" -> "string"
      | "integer" | "long" | "short" | "byte" | "intEnum" -> "int"
      | "float" | "double" | "bigInteger" | "bigDecimal" -> "float"
      | "boolean" -> "bool"
      | "timestamp" -> "Aws_json_wire.timestamp"
      | "blob" -> "Aws_json_wire.blob"
      | "document" -> "Aws_json_wire.document"
      | "list" | "set" ->
        type_expr (s.json |> member "member" |> member "target" |> to_string) ^ " list"
      | "map" ->
        type_expr (s.json |> member "value" |> member "target" |> to_string) ^ " Aws_json_wire.map"
      | "structure" | "union" -> snake (local id)
      | kind -> failwith (id ^ ": unsupported shape " ^ kind))
  and prelude = function
    | "String" -> "string"
    | "Integer" | "Long" | "Short" | "Byte" | "PrimitiveInteger" | "PrimitiveLong" -> "int"
    | "Boolean" | "PrimitiveBoolean" -> "bool"
    | "Float" | "Double" | "BigInteger" | "BigDecimal" -> "float"
    | "Timestamp" -> "Aws_json_wire.timestamp"
    | "Blob" -> "Aws_json_wire.blob"
    | "Document" -> "Aws_json_wire.document"
    | "Unit" -> "Aws_json_wire.empty"
    | name -> failwith ("prelude: " ^ name)
  in
  let records =
    List.filter
      (fun (_, s) ->
        (s.kind = "structure" || s.kind = "union") && not (has_trait "smithy.api#error" s.json))
      shapes
  in
  let record (id, s) =
    let members = s.json |> member "members" |> to_assoc in
    if members = [] then
      Printf.sprintf "%s = Aws_json_wire.empty" (snake (local id))
    else
      let field (name, m) =
        let target = m |> member "target" |> to_string in
        if s.kind = "structure" && has_trait "smithy.api#required" m then
          Printf.sprintf "%s : %s; [@key %S]" (snake name) (type_expr target) name
        else
          Printf.sprintf "%s : %s option; [@key %S] [@yojson.option]" (snake name)
            (type_expr target) name
      in
      Printf.sprintf "%s = {\n  %s\n}\n[@@yojson.allow_extra_fields]"
        (snake (local id))
        (String.concat "\n  " (List.map field members))
  in
  (* [let get_item_input ?consistent_read ~table_name ~key () = { ... }]: optional members as
     optional arguments, so callers name only what they set. *)
  let constructor (id, s) =
    let members = s.json |> member "members" |> to_assoc in
    if members = [] then
      None
    else
      let required (_, m) = s.kind = "structure" && has_trait "smithy.api#required" m in
      let arg ((name, _) as m) = (if required m then "~" else "?") ^ snake name in
      let unit = if List.for_all required members then "" else " ()" in
      Some
        (Printf.sprintf "let %s %s%s : %s = { %s }"
           (snake (local id))
           (String.concat " " (List.map arg members))
           unit
           (snake (local id))
           (String.concat "; " (List.map (fun (name, _) -> snake name) members)))
  in
  let operation id =
    let s = shape id in
    let io key = s.json |> member key |> member "target" |> to_string in
    Printf.sprintf
      {|module %s = struct
  module Def = struct
    let action = %S

    type request = %s [@@deriving yojson_of]
    type response = %s [@@deriving of_yojson]
  end

  include Def
  include Aws_json_transport.Make (Def)
end|}
      (String.capitalize_ascii (snake (local id)))
      (local id)
      (type_expr (io "input"))
      (type_expr (io "output"))
  in
  let operations =
    service.json |> member "operations" |> to_list
    |> List.map (fun o -> o |> member "target" |> to_string)
  in
  check_unique ~reserved:reserved_types "types" (List.map (fun (id, _) -> snake (local id)) records);
  check_unique ~reserved:reserved_modules "operations"
    (List.map (fun id -> snake (local id)) operations);
  List.iter
    (fun (_, s) ->
      check_unique (s.id ^ " fields")
        (s.json |> member "members" |> to_assoc |> List.map (fun (n, _) -> snake n)))
    records;
  let version =
    if has_trait "aws.protocols#awsJson1_0" service.json then
      "Json_1_0"
    else if has_trait "aws.protocols#awsJson1_1" service.json then
      "Json_1_1"
    else
      failwith "not an AWS JSON protocol service"
  in
  Printf.printf
    {|(* Generated by smithy/smithy_gen.exe from %s. Do not edit. *)

open Ppx_yojson_conv_lib.Yojson_conv.Primitives

module Error = Aws_json_error
module Wire = Aws_json_wire
module Transport = Aws_json_transport

type t = Transport.t

let protocol =
  Transport.{ version = %s; target_prefix = %S; signing_name = %S; endpoint_prefix = %S }

let make ?endpoint ?provider ~region ~now () = Transport.make ?endpoint ?provider ~protocol ~region ~now ()

type %s
[@@deriving yojson]

%s

%s
|}
    (Filename.basename path) version (local service.id)
    (trait "aws.auth#sigv4" service.json |> member "name" |> to_string |> host_label)
    (trait "aws.api#service" service.json |> member "endpointPrefix" |> to_string |> host_label)
    (String.concat "\n\nand " (List.map record records))
    (List.filter_map constructor records |> String.concat "\n")
    (List.map operation operations |> String.concat "\n\n")
