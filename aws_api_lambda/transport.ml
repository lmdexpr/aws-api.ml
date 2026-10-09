type _ Effect.t += Call : Request.t -> Response.t Effect.t

let call request = Effect.perform (Call request)
