(** AWS Lambda Runtime API (2018-06-01). HTTP is performed through {!Transport.Call}; nothing else
    does I/O. *)

module Error = Error
module Response = Response
module Invocation = Invocation
module Context = Context
module Request = Request
module Transport = Transport

val api_version : string

type handler = Invocation.t -> (string, Error.t) result
(** [Ok] is posted to [/response], [Error] to [/error]. *)

type fatal =
  | Container_error  (** 500: exit the process. *)
  | Malformed_invocation of Invocation.parse_error
  | Unexpected_status of { request : Request.t; status : int }

val fatal_to_string : fatal -> string
val next : unit -> (Invocation.t, fatal) result
val respond : Invocation.t -> (string, Error.t) result -> (unit, fatal) result

val step : ?propagate:(exn -> bool) -> handler -> (unit, fatal) result
(** {!next}, handler, {!respond}. Exceptions from the handler become [/error] posts unless
    [propagate] returns [true]. Exceptions raised at the {!Transport.call} sites (transport
    failures, cancellation) are not caught: they propagate out of [step]. *)

val run : ?propagate:(exn -> bool) -> handler -> fatal
(** {!step} until it fails. Returns the [fatal]; raises when a transport call raises. *)

val report_init_error : Error.t -> (unit, fatal) result

(** {!Transport.Call} over [Aws_api.Http]. A handler for [Aws_api.Http.Call] (e.g.
    [Aws_api_cohttp_eio.run]) must be installed outside. *)
module Http : sig
  val endpoint_from_env : unit -> string option
  (** [AWS_LAMBDA_RUNTIME_API] *)

  val handle : endpoint:string -> (unit -> 'a) -> 'a
  (** Performs each {!Transport.Call} with [Aws_api.Http.call] against
      [http://<endpoint>/<api_version>]. *)

  val run : ?propagate:(exn -> bool) -> endpoint:string -> handler -> fatal
  (** {!Aws_api_lambda.run} under {!handle}: returns the [fatal], or raises when the Runtime API
      cannot be reached. Sets [_X_AMZN_TRACE_ID] per invocation (process-wide, via [Unix.putenv]).
      With cohttp-eio, pass [~propagate:Aws_api_cohttp_eio.is_cancelled] so cancellation inside the
      handler unwinds the loop instead of being posted as a function error. *)
end
