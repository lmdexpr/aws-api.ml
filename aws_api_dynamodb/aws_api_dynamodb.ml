module Value = Value
module Number = Number
module Item = Item
module Projection = Projection
module Error = Error
module Action = Action
module Client = Client
module Transaction = Transaction
module Single_table = Single_table
module Transport = Aws_json_transport

type t = Transport.t

let protocol =
  Transport.
    {
      version = Json_1_0;
      target_prefix = "DynamoDB_20120810";
      signing_name = "dynamodb";
      endpoint_prefix = "dynamodb";
    }

let make ?endpoint ?provider ~region ~now () =
  Transport.make ?endpoint ?provider ~protocol ~region ~now ()

(* DynamoDB Local listens on 8000 and accepts any credentials. *)
let local ?(endpoint = Uri.of_string "http://127.0.0.1:8000/") ?(region = "us-east-1") ~now () =
  make ~endpoint
    ~provider:(Sigv4.Provider.Static.make ~access_key:"local" ~secret_key:"local" ())
    ~region ~now ()
