module IO = struct
  type +'a t = 'a Async.Deferred.t

  let map f x = Async.Deferred.map ~f x

  let bind x f = Async.Deferred.bind x ~f

  let return x = Async.Deferred.return x
end

include Conduit.Make (IO) (Cstruct) (Cstruct)
module S = Service

let failwith fmt = Format.kasprintf failwith fmt

let ( >>? ) x f = Async.Deferred.Result.bind x ~f

type ('a, 'b, 'c) service = ('a, 'b, 'c) Service.t

let serve_when_ready :
    type cfg t v.
    ?timeout:int ->
    ?stop:unit Async.Deferred.t ->
    handler:(flow -> unit Async.Deferred.t) ->
    (cfg, t, v) service ->
    cfg ->
    [ `Initialized of unit Async.Deferred.t ] Async.Deferred.t =
 fun ?timeout ?(stop = Async.Deferred.never ()) ~handler service cfg ->
  let open Async in
  let timeout =
    match timeout with
    | None -> Deferred.never
    | Some t -> fun () -> after (Core.Time.Span.of_int_sec t) in
  Service.init service cfg >>| function
  | Error err -> failwith "%a" Service.pp_error err
  | Ok t ->
      `Initialized
        (let rec loop () =
           let accept = Service.accept service t in
           Deferred.choose
             [
               choice accept (Result.map (fun f -> `Flow f));
               choice (timeout ()) (fun () -> Ok `Timeout);
             ]
           >>? function
           | `Flow flow ->
               don't_wait_for (handler flow) ;
               Scheduler.yield () >>= loop
           | `Timeout -> return (Ok `Timeout) in
         let stop_result =
           Deferred.choose
             [
               choice stop (fun () -> Ok `Stopped);
               choice (loop ()) (fun r -> r);
             ]
           >>= function
           | Ok (`Timeout | `Stopped) -> Service.stop service t
           | Error _ as err0 -> (
               Service.stop service t >>= function
               | Ok () | Error _ -> return err0) in
         stop_result >>= function
         | Ok () -> return ()
         | Error err -> failwith "%a" Service.pp_error err)

let serve ?timeout ?stop ~handler service cfg =
  Async.Deferred.bind (serve_when_ready ?timeout ?stop ~handler service cfg)
    ~f:(fun (`Initialized loop) -> loop)

let reader_and_writer_of_flow flow =
  let open Async in
  let recv flow writer =
    let tmp = Cstruct.create 0x1000 in
    let rec loop () =
      recv flow tmp >>= function
      | Ok (`Input len) ->
          Pipe.write writer (Cstruct.to_string (Cstruct.sub tmp 0 len)) >>= loop
      | Ok `End_of_flow ->
          Pipe.close writer ;
          Async.return ()
      | Error err -> failwith "%a" pp_error err in
    loop () in
  let send flow reader =
    let rec loop () =
      Pipe.read reader >>= function
      | `Eof -> Async.return ()
      | `Ok v ->
          let rec go tmp =
            if Cstruct.len tmp = 0
            then Async.return ()
            else
              send flow tmp >>= function
              | Ok shift -> go (Cstruct.shift tmp shift)
              | Error err -> failwith "%a" pp_error err in
          go (Cstruct.of_string v) >>= loop in
    loop () in
  let preader = Pipe.create_reader ~close_on_exception:true (recv flow) in
  let pwriter = Pipe.create_writer (send flow) in
  Reader.of_pipe (Core.Info.of_string "reader") preader >>= fun reader ->
  Writer.of_pipe (Core.Info.of_string "writer") pwriter >>= fun (writer, _) ->
  Async.return (reader, writer)

module TCP = struct
  open Async
  open Async_unix

  type endpoint =
    | Inet of Socket.Address.Inet.t
    | Unix of Socket.Address.Unix.t

  module Protocol = struct
    type input = Cstruct.t

    type output = Cstruct.t

    type +'a io = 'a Async.Deferred.t

    type flow =
      | Socket : {
          address : [< Socket.Address.t ];
          socket : ([ `Active ], [< Socket.Address.t ]) Socket.t;
          reader : Async.Reader.t;
          writer : Async.Writer.t;
        }
          -> flow

    let address (Socket { address; _ }) =
      match address with #Socket.Address.t as addr -> addr

    let reader (Socket { reader; _ }) = reader

    let writer (Socket { writer; _ }) = writer

    type nonrec endpoint = endpoint =
      | Inet of Socket.Address.Inet.t
      | Unix of Socket.Address.Unix.t

    type error = Core.Error.t

    let pp_error = Core.Error.pp

    let connect edn =
      let connect = function
        | Inet address ->
            Tcp.connect (Tcp.Where_to_connect.of_inet_address address)
            >>| fun (socket, reader, writer) ->
            Socket { address; socket; reader; writer }
        | Unix address ->
            Tcp.connect (Tcp.Where_to_connect.of_unix_address address)
            >>| fun (socket, reader, writer) ->
            Socket { address; socket; reader; writer } in
      Monitor.try_with (fun () -> connect edn) >>= function
      | Ok _ as v -> Async.return v
      | Error exn -> Async.return (Error (Core.Error.of_exn exn))

    let of_cstruct raw =
      let { Cstruct.buffer; off; len } = raw in
      Core.Bigsubstring.create ~pos:off ~len buffer

    (* XXX(dinosaure): as [lwt] and seems required for [conduit-tls], [recv] wants to read
       as much as possible. Due to underlying non-blocking socket, even if we reached [`Eof],
       we must retry to read until we have something or the underlying socket was closed. *)
    let recv (Socket { reader; _ }) raw =
      Monitor.try_with (fun () ->
          Reader.read_bigsubstring reader (of_cstruct raw))
      >>= function
      | Error err ->
          Reader.close reader >>= fun () ->
          Async.return (Error (Core.Error.of_exn err))
      | Ok (`Ok n) -> Async.return (Ok (`Input n))
      | Ok `Eof -> Async.return (Ok `End_of_flow)

    let send (Socket { writer; _ }) raw =
      Writer.write_bigsubstring writer (of_cstruct raw) ;
      Writer.flushed writer >>= fun () -> Async.return (Ok (Cstruct.len raw))

    let close (Socket { socket; reader; writer; _ }) =
      (* XXX(dinosaure): we should be protected against the double-close. *)
      if Reader.is_closed reader
         && Writer.is_closed writer
         && Fd.is_closed (Socket.fd socket)
      then Async.return (Ok ())
      else (
        Socket.shutdown socket `Both ;
        Reader.close reader >>= fun () ->
        Writer.close writer >>= fun () -> Async.return (Ok ()))
  end

  let endpoint, protocol = register ~name:"async-tcp" (module Protocol)

  let port : int value = info ~name:"async-port"

  let domain_name : [ `host ] Domain_name.t value =
    info ~name:"async-domain-name"

  type configuration =
    | Listen : int option * ('a, 'b) Tcp.Where_to_listen.t -> configuration

  module Service = struct
    type +'a io = 'a Async.Deferred.t

    type flow = Protocol.flow

    type error = Exn of [ `Make | `Accept ] * exn | Socket_closed

    let pp_error ppf = function
      | Exn (`Make, exn) ->
          Format.fprintf ppf "Got an exception while making socket: %s"
            (Printexc.to_string exn)
      | Exn (`Accept, exn) ->
          Format.fprintf ppf "Got an exception while accepting socket: %s"
            (Printexc.to_string exn)
      | Socket_closed -> Format.fprintf ppf "Socket closed"

    type nonrec configuration = configuration

    type t =
      | Socket :
          ([ `Passive ], ([< Socket.Address.t ] as 'a)) Socket.t * 'a
          -> t

    let close_socket_on_error ~process socket ~f =
      Monitor.try_with f >>| function
      | Ok v -> Ok v
      | Error exn ->
          Async.don't_wait_for (Unix.close (Socket.fd socket)) ;
          Error (Exn (process, exn))

    type socket_type =
      | Socket_type :
          ([< Socket.Address.t ] as 'a) Socket.Type.t * 'a
          -> socket_type

    let ( >>? ) x f =
      x >>= function Ok x -> f x | Error _ as err -> Async.return err

    let init (Listen (backlog, where_to_listen)) =
      let (Socket_type (socket_type, addr)) =
        match Tcp.Where_to_listen.address where_to_listen with
        | `Inet _ as addr -> Socket_type (Socket.Type.tcp, addr)
        | `Unix _ as addr -> Socket_type (Socket.Type.unix, addr) in
      let socket = Socket.create socket_type in
      let f () = Socket.bind socket addr >>| Socket.listen ?backlog in
      close_socket_on_error ~process:`Make socket ~f >>? fun socket ->
      Async.return (Ok (Socket (socket, addr)))

    let accept (Socket (socket, _)) =
      Socket.accept socket >>= function
      | `Ok (socket, address) ->
          let reader = Reader.create (Socket.fd socket) in
          let writer = Writer.create (Socket.fd socket) in
          let flow = Protocol.Socket { socket; reader; writer; address } in
          Async.return (Ok flow)
      | `Socket_closed -> Async.return (Error Socket_closed)

    let stop (Socket (socket, _)) =
      Fd.close (Socket.fd socket) >>= fun () -> Async.return (Ok ())
  end

  let service = S.register (module Service) protocol

  let configuration ?backlog listen = Listen (backlog, listen)

  let resolve ctx =
    let gethostbyname port domain_name =
      Monitor.try_with (fun () ->
          Unix.Inet_addr.of_string_or_getbyname
            (Domain_name.to_string domain_name))
      >>= function
      | Ok inet_addr ->
          let inet = Socket.Address.Inet.create inet_addr ~port in
          Async.return (Some (Inet inet))
      | _ -> Async.return None in
    fold endpoint Fun.[ req $ port; req $ domain_name ] ~f:gethostbyname ctx

  let port v ctx = add port v ctx

  let domain_name v ctx = add domain_name v ctx

  let inet v ctx = add endpoint (Inet v) ctx

  let unix v ctx = add endpoint (Unix v) ctx
end
