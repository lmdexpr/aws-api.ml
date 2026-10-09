(** Request to the Runtime API. *)

val api_version : string
(** ["2018-06-01"] *)

type meth = [ `GET | `POST ]

type t = {
  meth : meth;
  path : string;  (** Relative to [/<api_version>]. *)
  headers : (string * string) list;
  body : string option;
}

val next : t
(** [GET /runtime/invocation/next]. Do not set a timeout on it. *)

val response : Invocation.t -> string -> t
(** [POST /runtime/invocation/{request_id}/response] *)

val error : Invocation.t -> Error.t -> t
(** [POST /runtime/invocation/{request_id}/error] *)

val init_error : Error.t -> t
(** [POST /runtime/init/error] *)

val url : endpoint:string -> t -> string
(** [http://<endpoint>/<api_version><path>]. [endpoint] is [AWS_LAMBDA_RUNTIME_API]. *)
