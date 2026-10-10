module Value = Value
module Number = Number
module Item = Item
module Projection = Projection
module Envelope = Envelope
module Error = Error
module Client = Client
module Transaction = Transaction
module Single_table = Single_table

(* DynamoDB Local listens on 8000 and accepts any credentials. *)
let local ?(endpoint = Uri.of_string "http://127.0.0.1:8000/") ?(region = "us-east-1") ~now () =
  Aws_api_dynamodb.make ~endpoint
    ~provider:(Sigv4.Provider.Static.make ~access_key:"local" ~secret_key:"local" ())
    ~region ~now ()
