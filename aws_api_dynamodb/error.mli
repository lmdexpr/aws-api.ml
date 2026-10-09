(** DynamoDB 4xx error, or a client-side limit ({!too_many_pages}). *)

type t = {
  code : string;
    (** [__type] without namespace; [""] when the body is not parseable; [TooManyPages] for
        {!too_many_pages}. *)
  message : string option;  (** [message] or [Message] from the body. *)
  cancellation_reasons : string list;  (** [TransactionCanceledException]: one code per item. *)
  body : string;
}

val of_body : string -> t

val too_many_pages : max_pages:int -> t
(** Returned by [Client.query] / [Client.scan] when [max_pages] is exhausted. *)

val is_too_many_pages : t -> bool
val is_conditional_check_failed : t -> bool
val to_string : t -> string
