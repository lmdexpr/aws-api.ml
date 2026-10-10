(** Typed layer over the generated [Aws_api_dynamodb]: attribute values as a variant, exact decimal
    numbers, a table client, and single-table helpers. Every call takes an [Aws_api_dynamodb.t] from
    [Aws_api_dynamodb.make] or {!local}. *)

module Value = Value
module Number = Number
module Item = Item
module Projection = Projection
module Envelope = Envelope
module Error = Error
module Client = Client
module Transaction = Transaction
module Single_table = Single_table

val local : ?endpoint:Uri.t -> ?region:string -> now:(unit -> float) -> unit -> Aws_api_dynamodb.t
(** DynamoDB Local: [http://127.0.0.1:8000/] with static credentials. *)
