(** Error reported to Lambda. *)

type t = { error_type : string; error_message : string; stack_trace : string list }

val v : ?stack_trace:string list -> error_type:string -> string -> t
(** [stack_trace] defaults to []. Lambda recommends [<Category.Reason>] for [error_type]; it is sent
    as a header, so characters outside [A-Za-z0-9._-] are replaced with [_] and an empty value
    becomes [Error]. *)

val of_exn : ?backtrace:Printexc.raw_backtrace -> exn -> t
(** [error_type] is the constructor name, [error_message] is [Printexc.to_string]. *)

val sanitize_error_type : string -> string
(** The header-safe form described at {!v}. *)

val to_json : t -> string
(** [{"errorMessage":…,"errorType":…,"stackTrace":[…]}]. *)
