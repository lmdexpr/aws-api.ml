type meth = [ `GET | `POST | `PUT | `DELETE ]
type request = { meth : meth; uri : Uri.t; headers : (string * string) list; body : string option }
type response = { status : int; headers : (string * string) list; body : string }
type _ Effect.t += Call : request -> response Effect.t

let call request = Effect.perform (Call request)

let string_of_meth = function
  | `GET -> "GET"
  | `POST -> "POST"
  | `PUT -> "PUT"
  | `DELETE -> "DELETE"

let header name headers =
  let name = String.lowercase_ascii name in
  List.find_map
    (fun (key, value) -> if String.lowercase_ascii key = name then Some value else None)
    headers
