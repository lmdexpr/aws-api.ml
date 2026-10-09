(** The single HTTP effect every AWS call goes through.

    This library never performs I/O itself: install a handler for {!Call} (e.g.
    [Aws_api_cohttp_eio.run]) around the code that performs calls. *)

type meth = [ `GET | `POST | `PUT | `DELETE ]
type request = { meth : meth; uri : Uri.t; headers : (string * string) list; body : string option }
type response = { status : int; headers : (string * string) list; body : string }
type _ Effect.t += Call : request -> response Effect.t

val call : request -> response
(** A handler answers with the response, whatever its status, and makes a transport failure raise
    here, e.g. with [Effect.Deep.discontinue]. Raises [Effect.Unhandled] when no handler is
    installed. *)

val string_of_meth : meth -> string

val header : string -> (string * string) list -> string option
(** Looks a header up case-insensitively. *)
