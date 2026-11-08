(** What to generate from a model, with every name already parsed into the one it gets in source.
    [make] rejects what this generator does not support (a protocol other than AWS JSON, an error
    shape used as a member type, a name that is not an OCaml identifier, ...); values come only from
    it, so Emit formats them without checking anything. Error shapes are not generated: every
    operation fails with [Aws_json_error.t]. *)

type ty = private
  | Scalar of Model.scalar
  | Named of Naming.Ident.t  (** an enum, structure or union *)
  | List of ty
  | Map of ty  (** string keys *)

type field = private { wire : string; name : Naming.Ident.t; ty : ty; required : bool }

type record = private {
  name : Naming.Ident.t;
  fields : field list;
  constructor : bool;  (** a constructor of the same name, for a record with fields *)
}

type enum = private { name : Naming.Ident.t; values : (Naming.Tag.t * string) Nel.t }
type operation = private { name : Naming.Ident.t; action : string; input : ty; output : ty }

type service = private {
  protocol : Model.protocol;
  target_prefix : string;
  signing_name : Naming.Host_label.t;
  endpoint_prefix : Naming.Host_label.t;
}

type t = private {
  service : service;
  enums : enum list;
  records : record list;
  operations : operation list;
}

val make : Model.t -> t
