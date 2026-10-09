(** Handles [Aws_api.Http.Call] with a cohttp-eio client. *)

val run : ?max_response_size:int -> client:Cohttp_eio.Client.t -> (unit -> 'a) -> 'a
(** [run ~client k] performs every request made by [k] with [client], reading the response body
    fully; [max_response_size] bounds it (default 16 MiB). HTTPS endpoints need a client made with
    [~https]. A transport exception is raised where the request was performed. *)

val is_cancelled : exn -> bool
(** [Eio.Cancel.Cancelled]. For [Aws_api_lambda.Http.run ~propagate]: cancellation must unwind the
    loop rather than be posted as a function error. *)
