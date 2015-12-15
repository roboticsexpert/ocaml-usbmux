open Lwt
module T = ANSITerminal
module B = Yojson.Basic
module U = Yojson.Basic.Util

let byte_swap_16 value =
  ((value land 0xFF) lsl 8) lor ((value lsr 8) land 0xFF)

module Protocol = struct

  type conn_code = Success
                 | Device_requested_not_connected
                 | Port_requested_not_available
                 | Malformed_request

  type event = Attached of device_t
             | Detached of device_id
  and device_id = int
  and device_t = { serial_number : string;
                   connection_speed : int;
                   connection_type : string;
                   product_id : int;
                   location_id : int;
                   device_id : int; }

  type msg_t = Result of conn_code
             | Event of event

  let do_read_header i_chan () =
    i_chan |> Lwt_io.atomic begin fun ic ->
      Lwt_io.LE.read_int32 ic >>= fun raw_count ->
      Lwt_io.LE.read_int32 ic >>= fun raw_version ->
      Lwt_io.LE.read_int32 ic >>= fun raw_request ->
      Lwt_io.LE.read_int32 ic >|= fun raw_tag ->
      Int32.(to_int raw_count, to_int raw_version, to_int raw_request, to_int raw_tag)
    end

  let listen_message =
    Plist.(Dict [("MessageType", String "Listen");
                 ("ClientVersionString", String "ocaml-usbmux");
                 ("ProgName", String "ocaml-usbmux")]
           |> make)

  let time_now () =
    let open Unix in
    let localtime = localtime (time ()) in
    Printf.sprintf "[%02u:%02u:%02u]" localtime.tm_hour localtime.tm_min localtime.tm_sec

  let colored_message ?(t_color=T.Yellow) ?(m_color=T.Blue) ?(with_time=true) str =
    let just_time = T.sprintf [T.Foreground t_color] "%s " (time_now ()) in
    let just_message = T.sprintf [T.Foreground m_color] "%s" str in
    if with_time then just_time ^ just_message else just_message

  let log_reply = function
    | Result Success -> Lwt_log.info (colored_message "Listening for iDevices")
    | Result Device_requested_not_connected ->
      Lwt_log.info (colored_message ~m_color:T.Red "Device requested was not connected")
    | Result Port_requested_not_available ->
      Lwt_log.info (colored_message ~m_color:T.Red "Port requested was not available")
    | Result Malformed_request ->
      Lwt_io.printl (colored_message ~m_color:T.Red "Malformed request, check the request")
    (* Lazy, add rest here *)
    | _ -> return ()

  let parse_reply raw_reply =
    let open Yojson.Basic in
    let handle = Plist.parse_dict raw_reply in
    match (Util.member "MessageType" handle) |> Util.to_string with
    | "Result" -> (match (Util.member "Number" handle) |> Util.to_int with
        | 0 -> Result Success
        | 2 -> Result Device_requested_not_connected
        | 3 -> Result Port_requested_not_available
        | 5 -> Result Malformed_request
        | _ -> assert false)
    | "Attached" ->
      Event (Attached
               {serial_number = Util.member "SerialNumber" handle |> Util.to_string;
                connection_speed = Util.member "ConnectionSpeed" handle |> Util.to_int;
                connection_type = Util.member "ConnectionType" handle |> Util.to_string;
                product_id = Util.member "ProductID" handle |> Util.to_int;
                location_id = Util.member "LocationID" handle |> Util.to_int;
                device_id = Util.member "DeviceID" handle |> Util.to_int ;})
    | "Detached" ->
      Event (Detached (Util.member "DeviceID" handle |> Util.to_int))
    | otherwise ->
      print_endline otherwise;
      assert false

  let handle r () = match r with
    (* Come back to this *)
    | Result (Success | Device_requested_not_connected) -> Lwt.return ()
    | Event Attached { serial_number; connection_speed; connection_type;
                       product_id; location_id; device_id; } ->
      Lwt_io.printlf "Device %d with serial number: %s connected" device_id serial_number
    | Event Detached d ->
      Lwt_io.printlf "Device %d disconnected" d
    | _ -> return ()

  let create_listener debug =
    let total_len = (String.length listen_message) + 16 in
    Lwt_io.open_connection (Unix.ADDR_UNIX "/var/run/usbmuxd") >>= fun (ic, oc) ->

    Lwt_io.LE.write_int32 oc (Int32.of_int total_len) >>= fun () ->
    Lwt_io.LE.write_int32 oc (Int32.of_int 1) >>= fun () ->
    Lwt_io.LE.write_int32 oc (Int32.of_int 8) >>= fun () ->
    Lwt_io.LE.write_int32 oc (Int32.of_int 1) >>= fun () ->

    Lwt_io.write_from_string oc listen_message 0 (String.length listen_message) >>= fun c ->

    Lwt_log.info ("Write count: " ^ string_of_int c |> colored_message) >>= fun () ->


    let rec forever () =
      do_read_header ic () >>= fun (msg_len, version, request, tag) ->
      Lwt_log.info (Printf.sprintf "Read count: %d" msg_len |> colored_message) >>= fun () ->
      Lwt_io.read ~count:(msg_len) ic >>= fun raw_reply ->
      Lwt_log.info (Plist.parse_dict raw_reply
                    |> B.pretty_to_string
                    |> colored_message ~m_color:T.Green) >>= fun () ->
      let reply = raw_reply |> parse_reply in
      if debug then log_reply reply >>= handle reply >>= forever
      else handle reply () >>= forever
    in
    forever ()

end

module Relay = struct

  (** Note: PortNumber must be network-endian, so it gets byte swapped here *)
  let connect_message device_id port =
    Plist.((Dict [("MessageType", String "Connect");
                  ("ClientVersionString", String "ocaml-usbmux");
                  ("ProgName", String "ocaml-usbmux");
                  ("DeviceID", Integer port);
                  ("PortNumber", Integer (byte_swap_16 port))])
           |> make)

  let create be_verbose udid ports =
    Lwt.return ()

end

