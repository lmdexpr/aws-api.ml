(** Strings from the model parsed into the names they become in generated source. Names go into
    source unquoted, so they are parsed, not trusted. Each parser fails with [context], the id of
    the shape the string comes from. *)

(** A lower-case OCaml identifier that is not a keyword. *)
module Ident : sig
  type t = private string

  val snake : context:string -> string -> t
  (** [GetParameterRequest] -> [get_parameter_request], [DocumentARN] -> [document_arn]; a keyword
      gets a trailing underscore. *)

  val module_name : t -> string
end

(** A polymorphic variant tag other than [`Unknown_value], which every generated enum adds. *)
module Tag : sig
  type t = private string

  val of_string : context:string -> string -> t
end

(** Lower-case letters, digits and hyphens: it goes into the endpoint's host name. *)
module Host_label : sig
  type t = private string

  val of_string : context:string -> string -> t
end
