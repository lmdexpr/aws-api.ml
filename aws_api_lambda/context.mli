(** Function configuration from environment variables. *)

type t = {
  function_name : string;  (** [AWS_LAMBDA_FUNCTION_NAME] *)
  function_version : string;  (** [AWS_LAMBDA_FUNCTION_VERSION] *)
  memory_size_mb : int;  (** [AWS_LAMBDA_FUNCTION_MEMORY_SIZE] *)
  region : string;  (** [AWS_REGION] *)
  log_group_name : string option;  (** [AWS_LAMBDA_LOG_GROUP_NAME], unset under SnapStart *)
  log_stream_name : string option;  (** [AWS_LAMBDA_LOG_STREAM_NAME], unset under SnapStart *)
}

type parse_error =
  | Missing_variable of string
  | Invalid_variable of { name : string; value : string }

val parse_error_to_string : parse_error -> string

val of_env : (string -> string option) -> (t, parse_error) result
(** [of_env Sys.getenv_opt] on Lambda. *)
