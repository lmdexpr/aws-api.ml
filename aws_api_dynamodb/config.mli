type t = { endpoint : Uri.t; region : string }

val aws : region:string -> t
(** [https://dynamodb.<region>.amazonaws.com/]. *)

val local : ?endpoint:Uri.t -> ?region:string -> unit -> t
(** Defaults: [http://127.0.0.1:8000/], [us-east-1]. *)
