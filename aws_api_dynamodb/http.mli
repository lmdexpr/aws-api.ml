(** Handles {!Effects.Call} over [Aws_api.Http]: endpoint from {!Config}, SigV4 signature, POST. A
    handler for [Aws_api.Http.Call] (e.g. [Aws_api_cohttp_eio.run]) must be installed outside. *)

val run : ?provider:Sigv4.Provider.t -> now:(unit -> float) -> config:Config.t -> (unit -> 'a) -> 'a
(** [Sigv4.with_provider provider] around {!handle}. [provider] defaults to a fresh
    {!default_provider}, whose credential cache then lives only for this [run]: call [run] once
    around the whole program (or build the provider once and pass it) rather than once per request.
    [now] returns the UTC epoch. Missing credentials, 5xx responses and transport failures raise at
    the perform site. *)

val handle : now:(unit -> float) -> config:Config.t -> (unit -> 'a) -> 'a
(** The request handler alone; [Sigv4.Credentials.fetch] must resolve. *)

val default_provider :
  ?getenv:(string -> string option) ->
  ?read_file:(string -> string option) ->
  now:(unit -> float) ->
  unit ->
  Sigv4.Provider.t
(** [Sigv4.Provider.default] with its HTTP fetches (ECS, IMDS) performed through
    [Aws_api.Http.call]; [getenv] and [read_file] are passed through. Build once and reuse so the
    cache is shared. *)
