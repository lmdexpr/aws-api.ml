(** DynamoDB 4xx error, another HTTP failure, or a client-side limit ({!too_many_pages}). The type
    is the shared JSON-protocol error; see [smithy/runtime/aws_json_error.ml]. *)

type t = Aws_json_error.t = {
  code : string;
    (** [__type] without namespace; [""] when the body is not parseable; [TooManyPages] for
        {!too_many_pages}; {!http_status_code} / {!deserialization_code} for transport failures. *)
  message : string option;  (** [message] or [Message] from the body. *)
  body : string;  (** Raw response body; empty for {!deserialization} and {!too_many_pages}. *)
}

val of_body : string -> t
val http_status : status:int -> body:string -> t
val http_status_code : string
val is_http_status : t -> bool
val deserialization : exn -> t
val deserialization_code : string
val is_deserialization : t -> bool

val cancellation_reasons : t -> string list
(** [TransactionCanceledException]: one code per item, read from [body]. *)

val too_many_pages : max_pages:int -> t
(** Returned by [Client.query] / [Client.scan] when [max_pages] is exhausted. *)

val is_too_many_pages : t -> bool
val is_conditional_check_failed : t -> bool
val to_string : t -> string
