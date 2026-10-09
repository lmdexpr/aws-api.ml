(** Event returned by [GET /runtime/invocation/next]. *)

type t = {
  request_id : string;  (** [Lambda-Runtime-Aws-Request-Id] *)
  deadline_ms : int;  (** [Lambda-Runtime-Deadline-Ms], Unix epoch ms *)
  invoked_function_arn : string;  (** [Lambda-Runtime-Invoked-Function-Arn] *)
  trace_id : string option;  (** [Lambda-Runtime-Trace-Id] *)
  client_context : string option;  (** [Lambda-Runtime-Client-Context] *)
  cognito_identity : string option;  (** [Lambda-Runtime-Cognito-Identity] *)
  invocation_id : string option;  (** [Lambda-Runtime-Invocation-Id] *)
  payload : string;  (** Response body, verbatim. *)
}

type parse_error = Missing_header of string | Invalid_header of { name : string; value : string }

val parse_error_to_string : parse_error -> string

val of_response : Response.t -> (t, parse_error) result
(** Ignores the status. *)

val remaining_ms : now_ms:int -> t -> int
(** [deadline_ms - now_ms]. *)

val invocation_id_header : string
