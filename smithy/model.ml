type id = string

let local id =
  match String.split_on_char '#' id with
  | [ _; local ] -> local
  | _ -> invalid_arg @@ Printf.sprintf "Model.local: %S is not a shape id" id

type scalar = String | Int | Float | Bool | Timestamp | Blob | Document | Unit
type member = { name : string; target : id; required : bool }
type operation = { input : id; output : id }
type protocol = Json_1_0 | Json_1_1

type service = {
  id : id;
  operations : (id * operation) list;
  protocol : protocol option;
  signing_name : string;
  endpoint_prefix : string;
}

type record = Structure of member list | Union of member Nel.t

type shape =
  | Scalar of scalar
  | Enum of (string * string) Nel.t
  | List of id
  | Map of { key : id; value : id }
  | Record of record
  | Error of member list
  | Other of string

module Ids = Map.Make (String)

type shapes = shape Ids.t

type t = {
  service : service;
  enums : (id * (string * string) Nel.t) list;
  records : (id * record) list;
  shapes : shapes;
}

(** Smithy JSON AST to {!t}. *)
module Parse = struct
  open Yojson.Safe.Util

  let trait name json =
    match member "traits" json with `Assoc _ as t -> member name t | _ -> `Null

  let has_trait name json = trait name json <> `Null

  (** [context] is the shape the id appears in, if any. *)
  let id ?context s =
    match String.split_on_char '#' s with
    | [ namespace; name ] when namespace <> "" && name <> "" -> s
    | _ -> (
      match context with
      | Some context -> failwith @@ Printf.sprintf "%s: %S is not a shape id" context s
      | None -> failwith @@ Printf.sprintf "%S is not a shape id" s)

  let target ~context json = json |> member "target" |> to_string |> id ~context

  let targets ~context key json =
    match member key json with `List l -> List.map (target ~context) l | _ -> []

  (** An absent input or output is smithy.api#Unit. *)
  let io ~context key json =
    match member key json with `Null -> "smithy.api#Unit" | j -> target ~context j

  let members ~context ~union json =
    json |> member "members" |> to_assoc
    |> List.map @@ fun (name, m) ->
       {
         name;
         target = target ~context m;
         required = (not union) && has_trait "smithy.api#required" m;
       }

  let nel ~context what l =
    match Nel.of_list l with
    | Some l -> l
    | None -> failwith @@ Printf.sprintf "%s: %s with no members" context what

  type service = {
    id : id;
    operation_ids : id list;
    protocol : protocol option;
    signing_name : string;
    endpoint_prefix : string;
  }
  (** A service as read: its operations are still ids, resolved once every shape is read. *)

  type entry = Shape of shape | Operation of operation | Service of service

  let entry id json =
    let context = id in
    match json |> member "type" |> to_string with
    | "string" -> Shape (Scalar String)
    | "integer" | "long" | "short" | "byte" | "intEnum" -> Shape (Scalar Int)
    | "float" | "double" | "bigInteger" | "bigDecimal" -> Shape (Scalar Float)
    | "boolean" -> Shape (Scalar Bool)
    | "timestamp" -> Shape (Scalar Timestamp)
    | "blob" -> Shape (Scalar Blob)
    | "document" -> Shape (Scalar Document)
    | "enum" ->
      Shape
        (Enum
           (json |> member "members" |> to_assoc
           |> List.map (fun (tag, m) ->
             tag, match trait "smithy.api#enumValue" m with `String v -> v | _ -> tag)
           |> nel ~context "enum"))
    | "list" | "set" -> Shape (List (json |> member "member" |> target ~context))
    | "map" ->
      Shape
        (Map
           {
             key = json |> member "key" |> target ~context;
             value = json |> member "value" |> target ~context;
           })
    | "structure" when has_trait "smithy.api#error" json ->
      Shape (Error (members ~context ~union:false json))
    | "structure" -> Shape (Record (Structure (members ~context ~union:false json)))
    | "union" -> Shape (Record (Union (nel ~context "union" (members ~context ~union:true json))))
    | "operation" ->
      Operation { input = io ~context "input" json; output = io ~context "output" json }
    | "service" ->
      Service
        {
          id;
          operation_ids = targets ~context "operations" json;
          protocol =
            (if has_trait "aws.protocols#awsJson1_0" json then
               Some Json_1_0
             else if has_trait "aws.protocols#awsJson1_1" json then
               Some Json_1_1
             else
               None);
          signing_name = trait "aws.auth#sigv4" json |> member "name" |> to_string;
          endpoint_prefix = trait "aws.api#service" json |> member "endpointPrefix" |> to_string;
        }
    | other -> Shape (Other other)

  type acc = {
    enums : (id * (string * string) Nel.t) list;
    records : (id * record) list;
    shapes : shape Ids.t;
    operations : operation Ids.t;
    service : service option;
  }
  (** What one pass over the shapes gathers, before the service's operations are resolved. *)

  let empty =
    { enums = []; records = []; shapes = Ids.empty; operations = Ids.empty; service = None }

  let add (key, json) acc =
    let id = id key in
    match entry id json with
    | Shape (Enum values as s) ->
      { acc with enums = (id, values) :: acc.enums; shapes = Ids.add id s acc.shapes }
    | Shape (Record r as s) ->
      { acc with records = (id, r) :: acc.records; shapes = Ids.add id s acc.shapes }
    | Shape s -> { acc with shapes = Ids.add id s acc.shapes }
    | Operation o -> { acc with operations = Ids.add id o acc.operations }
    | Service s -> (
      match acc.service with
      | None -> { acc with service = Some s }
      | Some other -> failwith @@ Printf.sprintf "%s: a second service besides %s" id other.id)

  let resolve : acc -> t = function
    | { service = None; _ } -> failwith "no service shape"
    | { service = Some s; _ } as acc ->
      let operations =
        s.operation_ids
        |> List.map @@ fun id ->
           match Ids.find_opt id acc.operations with
           | Some o -> id, o
           | None -> failwith @@ Printf.sprintf "%s: %s is not an operation" s.id id
      in
      {
        service =
          {
            id = s.id;
            operations;
            protocol = s.protocol;
            signing_name = s.signing_name;
            endpoint_prefix = s.endpoint_prefix;
          };
        enums = acc.enums;
        records = acc.records;
        shapes = acc.shapes;
      }

  let model json =
    json |> member "shapes" |> to_assoc |> ListLabels.fold_right ~init:empty ~f:add |> resolve
end

let of_json = Parse.model

let prelude id =
  Option.map (fun s -> Scalar s)
  @@
  match local id with
  | "String" -> Some String
  | "Integer" | "Long" | "Short" | "Byte" | "PrimitiveInteger" | "PrimitiveLong" -> Some Int
  | "Boolean" | "PrimitiveBoolean" -> Some Bool
  | "Float" | "Double" | "BigInteger" | "BigDecimal" -> Some Float
  | "Timestamp" -> Some Timestamp
  | "Blob" -> Some Blob
  | "Document" -> Some Document
  | "Unit" -> Some Unit
  | _ -> None

let find shapes id =
  match
    if String.starts_with ~prefix:"smithy.api#" id then
      prelude id
    else
      Ids.find_opt id shapes
  with
  | Some s -> s
  | None -> failwith @@ Printf.sprintf "%s: unknown shape" id
