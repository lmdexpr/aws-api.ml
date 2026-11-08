(** The parts of a Smithy JSON AST model the generator reads, as typed values. [of_json] rejects
    what violates Smithy itself; what this generator does not support is left to {!Plan}. *)

type id = private string
(** A shape id, [namespace#Name] with neither part empty. *)

val local : id -> string
(** The [Name] of [namespace#Name]. *)

type scalar = String | Int | Float | Bool | Timestamp | Blob | Document | Unit

type member = {
  name : string;
  target : id;
  required : bool;  (** always false for a union member: exactly one is set *)
}

type operation = { input : id; output : id }
type protocol = Json_1_0 | Json_1_1

type service = {
  id : id;
  operations : (id * operation) list;
  protocol : protocol option;  (** [None] for a protocol other than AWS JSON *)
  signing_name : string;
  endpoint_prefix : string;
}

(** Smithy requires a union to have a member; a structure may have none. *)
type record = Structure of member list | Union of member Nel.t

(** A shape a member can target. *)
type shape =
  | Scalar of scalar
  | Enum of (string * string) Nel.t  (** member name, wire value *)
  | List of id
  | Map of { key : id; value : id }
  | Record of record
  | Error of member list  (** a structure with the smithy.api#error trait *)
  | Other of string  (** a shape kind the generator does not map, e.g. resource *)

type shapes
(** The shapes a member can target, by id. *)

type t = private {
  service : service;
  enums : (id * (string * string) Nel.t) list;
    (** in the model's order, which the generated file follows *)
  records : (id * record) list;  (** in the model's order *)
  shapes : shapes;
}

val of_json : Yojson.Safe.t -> t
(** Fails on a malformed shape id, a model with no service or several, an operation id that is not
    an operation, or an empty enum or union. *)

val find : shapes -> id -> shape
(** The shape [id] names, including the smithy.api# prelude, which the model does not list. *)
