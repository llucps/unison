(* Unison file synchronizer: src/uigtk3.ml *)
(* Copyright 1999-2020, Benjamin C. Pierce

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*)


open Common
open Lwt

module Private = struct

let debug = Trace.debug "ui"

let myNameCapitalized = String.capitalize_ascii Uutil.myName

(**********************************************************************
                           LOW-LEVEL STUFF
 **********************************************************************)

(**********************************************************************
 Some message strings (build them here because they look ugly in the
 middle of other code.
 **********************************************************************)

let tryAgainMessage =
  Printf.sprintf
"You can use %s to synchronize a local directory with another local directory,
or with a remote directory.

Please enter the first (local) directory that you want to synchronize."
myNameCapitalized

(* ---- *)

let helpmessage = Printf.sprintf
"%s can synchronize a local directory with another local directory, or with
a directory on a remote machine.

To synchronize with a local directory, just enter the file name.

To synchronize with a remote directory, you must first choose a protocol
that %s will use to connect to the remote machine.  Each protocol has
different requirements:

1) To synchronize using SSH, there must be an SSH client installed on
this machine and an SSH server installed on the remote machine.  You
must enter the host to connect to, a user name (if different from
your user name on this machine), and the directory on the remote machine
(relative to your home directory on that machine).

2) To synchronize using %s's socket protocol, there must be a %s
server running on the remote machine, listening to the port that you
specify here.  (Use \"%s -socket xxx\" on the remote machine to
start the %s server.)  You must enter the host, port, and the directory
on the remote machine (relative to the working directory of the
%s server running on that machine)."
myNameCapitalized myNameCapitalized myNameCapitalized myNameCapitalized myNameCapitalized myNameCapitalized myNameCapitalized

(**********************************************************************
 Font preferences
 **********************************************************************)

let fontMonospace = lazy (Pango.Font.from_string "monospace")
let fontBold = lazy (Pango.Font.from_string "bold")
let fontItalic = lazy (Pango.Font.from_string "italic")

(**********************************************************************
 Unison icon
 **********************************************************************)

(* This does not work with the current version of Lablgtk, due to a bug
let icon =
  GdkPixbuf.from_data ~width:48 ~height:48 ~has_alpha:true
    (Gpointer.region_of_bytes Pixmaps.icon_data)
*)
let icon =
  lazy begin
    let p = GdkPixbuf.create ~width:48 ~height:48 ~has_alpha:true () in
    Gpointer.blit
      ~src:(Gpointer.region_of_bytes (Bytes.of_string Pixmaps.icon_data))
      ~dst:(GdkPixbuf.get_pixels p);
    p
  end

let leftPtrWatch =
  lazy (Gdk.Cursor.create `WATCH)

let make_busy w =
  if Util.osType <> `Win32 then
    Gdk.Window.set_cursor w#misc#window (Lazy.force leftPtrWatch)
let make_interactive w =
  if Util.osType <> `Win32 then
    (* HACK: setting the cursor to NULL restore the default cursor *)
    Gdk.Window.set_cursor w#misc#window (Obj.magic Gpointer.boxed_null)

(*********************************************************************
  UI state variables
 *********************************************************************)

type stateItem = { mutable ri : reconItem;
                   mutable bytesTransferred : Uutil.Filesize.t;
                   mutable bytesToTransfer : Uutil.Filesize.t;
                   mutable whatHappened : (Util.confirmation * string option) option}
let theState = ref [||]
let unsynchronizedPaths = ref None

(* ---- *)

let theToplevelWindow = ref None
let setToplevelWindow w = theToplevelWindow := Some w
let toplevelWindow () =
  match !theToplevelWindow with
    Some w -> w
  | None   -> raise (Util.Fatal "Main window not initialized; check your DISPLAY setup")

(*********************************************************************
  Lock management
 *********************************************************************)

let busy = ref false

let getLock f =
  let protect ~(finally : unit -> unit) f =
    (* Very simple [protect] when we know that [finally] does not raise *)
    (* FIXME: Switch to [Fun.protect] once OCaml 4.09 is the minimum? *)
    try let () = f () in finally () with
    | e ->
        finally ();
        raise e
  in
  if !busy then
    Trace.status "Synchronizer is busy, please wait.."
  else begin
    busy := true; protect ~finally:(fun () -> busy := false) f
  end

(**********************************************************************
  Miscellaneous
 **********************************************************************)

let sync_action = ref None

let last = ref (0.)

let gtk_sync forced =
  let t = Unix.gettimeofday () in
  if !last = 0. || forced || t -. !last > 0.05 then begin
    last := t;
    begin match !sync_action with
      Some f -> f ()
    | None   -> ()
    end;
    while Glib.Main.iteration false do () done
  end

(**********************************************************************
                      CHARACTER SET TRANSCODING
***********************************************************************)

(* Transcodage from Microsoft Windows Codepage 1252 to Unicode *)

(* Unison currently uses the "ASCII" Windows filesystem API.  With
   this API, filenames are encoded using a proprietary character
   encoding.  This encoding depends on the Windows setup, but in
   Western Europe, the Windows Codepage 1252 is usually used.
   GTK, on the other hand, uses the UTF-8 encoding.  This code perform
   the translation from Codepage 1252 to UTF-8.  A call to [transcode]
   should be wrapped around every string below that might contain
   non-ASCII characters. *)

let code =
  [| 0x0020; 0x0001; 0x0002; 0x0003; 0x0004; 0x0005; 0x0006; 0x0007;
     0x0008; 0x0009; 0x000A; 0x000B; 0x000C; 0x000D; 0x000E; 0x000F;
     0x0010; 0x0011; 0x0012; 0x0013; 0x0014; 0x0015; 0x0016; 0x0017;
     0x0018; 0x0019; 0x001A; 0x001B; 0x001C; 0x001D; 0x001E; 0x001F;
     0x0020; 0x0021; 0x0022; 0x0023; 0x0024; 0x0025; 0x0026; 0x0027;
     0x0028; 0x0029; 0x002A; 0x002B; 0x002C; 0x002D; 0x002E; 0x002F;
     0x0030; 0x0031; 0x0032; 0x0033; 0x0034; 0x0035; 0x0036; 0x0037;
     0x0038; 0x0039; 0x003A; 0x003B; 0x003C; 0x003D; 0x003E; 0x003F;
     0x0040; 0x0041; 0x0042; 0x0043; 0x0044; 0x0045; 0x0046; 0x0047;
     0x0048; 0x0049; 0x004A; 0x004B; 0x004C; 0x004D; 0x004E; 0x004F;
     0x0050; 0x0051; 0x0052; 0x0053; 0x0054; 0x0055; 0x0056; 0x0057;
     0x0058; 0x0059; 0x005A; 0x005B; 0x005C; 0x005D; 0x005E; 0x005F;
     0x0060; 0x0061; 0x0062; 0x0063; 0x0064; 0x0065; 0x0066; 0x0067;
     0x0068; 0x0069; 0x006A; 0x006B; 0x006C; 0x006D; 0x006E; 0x006F;
     0x0070; 0x0071; 0x0072; 0x0073; 0x0074; 0x0075; 0x0076; 0x0077;
     0x0078; 0x0079; 0x007A; 0x007B; 0x007C; 0x007D; 0x007E; 0x007F;
     0x20AC; 0x1234; 0x201A; 0x0192; 0x201E; 0x2026; 0x2020; 0x2021;
     0x02C6; 0x2030; 0x0160; 0x2039; 0x0152; 0x1234; 0x017D; 0x1234;
     0x1234; 0x2018; 0x2019; 0x201C; 0x201D; 0x2022; 0x2013; 0x2014;
     0x02DC; 0x2122; 0x0161; 0x203A; 0x0153; 0x1234; 0x017E; 0x0178;
     0x00A0; 0x00A1; 0x00A2; 0x00A3; 0x00A4; 0x00A5; 0x00A6; 0x00A7;
     0x00A8; 0x00A9; 0x00AA; 0x00AB; 0x00AC; 0x00AD; 0x00AE; 0x00AF;
     0x00B0; 0x00B1; 0x00B2; 0x00B3; 0x00B4; 0x00B5; 0x00B6; 0x00B7;
     0x00B8; 0x00B9; 0x00BA; 0x00BB; 0x00BC; 0x00BD; 0x00BE; 0x00BF;
     0x00C0; 0x00C1; 0x00C2; 0x00C3; 0x00C4; 0x00C5; 0x00C6; 0x00C7;
     0x00C8; 0x00C9; 0x00CA; 0x00CB; 0x00CC; 0x00CD; 0x00CE; 0x00CF;
     0x00D0; 0x00D1; 0x00D2; 0x00D3; 0x00D4; 0x00D5; 0x00D6; 0x00D7;
     0x00D8; 0x00D9; 0x00DA; 0x00DB; 0x00DC; 0x00DD; 0x00DE; 0x00DF;
     0x00E0; 0x00E1; 0x00E2; 0x00E3; 0x00E4; 0x00E5; 0x00E6; 0x00E7;
     0x00E8; 0x00E9; 0x00EA; 0x00EB; 0x00EC; 0x00ED; 0x00EE; 0x00EF;
     0x00F0; 0x00F1; 0x00F2; 0x00F3; 0x00F4; 0x00F5; 0x00F6; 0x00F7;
     0x00F8; 0x00F9; 0x00FA; 0x00FB; 0x00FC; 0x00FD; 0x00FE; 0x00FF |]

let rec transcodeRec buf s i l =
  if i < l then begin
    let c = code.(Char.code s.[i]) in
    if c < 0x80 then
      Buffer.add_char buf (Char.chr c)
    else if c < 0x800 then begin
      Buffer.add_char buf (Char.chr (c lsr 6 + 0xC0));
      Buffer.add_char buf (Char.chr (c land 0x3f + 0x80))
    end else if c < 0x10000 then begin
      Buffer.add_char buf (Char.chr (c lsr 12 + 0xE0));
      Buffer.add_char buf (Char.chr ((c lsr 6) land 0x3f + 0x80));
      Buffer.add_char buf (Char.chr (c land 0x3f + 0x80))
    end;
    transcodeRec buf s (i + 1) l
  end

let transcodeDoc s =
  let buf = Buffer.create 1024 in
  transcodeRec buf s 0 (String.length s);
  Buffer.contents buf

(****)

let escapeMarkup s = Glib.Markup.escape_text s

let transcodeFilename s =
  if Prefs.read Case.unicodeEncoding then
    Unicode.protect s
  else if Util.osType = `Win32 then transcodeDoc s else
  try
    Glib.Convert.filename_to_utf8 s
  with Glib.Convert.Error _ ->
    Unicode.protect s

let transcode s =
  if Prefs.read Case.unicodeEncoding then
    Unicode.protect s
  else
  try
    Glib.Convert.locale_to_utf8 s
  with Glib.Convert.Error _ ->
    Unicode.protect s

(**********************************************************************
                       USEFUL LOW-LEVEL WIDGETS
 **********************************************************************)

class scrolled_text ?editable ?shadow_type ?(wrap_mode=`WORD) ?packing ?show
    () =
  let sw =
    GBin.scrolled_window ?packing ~show:false
      ?shadow_type ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ()
  in
  let text = GText.view ?editable ~wrap_mode ~packing:sw#add () in
  let () = text#set_left_margin 4
  and () = text#set_right_margin 4 in
  object
    inherit GObj.widget_full sw#as_widget
    method text = text
    method insert s = text#buffer#set_text s;
    method show () = sw#misc#show ()
    initializer
      if show <> Some false then sw#misc#show ()
  end

(* ------ *)

(* Display a message in a window and wait for the user
   to hit the button. *)
let okBox ~parent ~title ~typ ~message =
  let t =
    GWindow.message_dialog
      ~parent ~title ~message_type:typ ~message ~modal:true
      ~buttons:GWindow.Buttons.ok () in
  ignore (t#run ()); t#destroy ()

(* ------ *)

let primaryText msg =
  Printf.sprintf "<span weight=\"bold\" size=\"larger\">%s</span>"
    (escapeMarkup msg)

(* twoBox: Display a message in a window and wait for the user
   to hit one of two buttons.  Return true if the first button is
   chosen, false if the second button is chosen. *)
let twoBox ?(kind=`DIALOG_WARNING) ~parent ~title ~astock ~bstock message =
  let t =
    GWindow.dialog ~parent ~border_width:6 ~modal:true
      ~resizable:false () in
  t#vbox#set_spacing 12;
  let h1 = GPack.hbox ~border_width:6 ~spacing:12 ~packing:t#vbox#pack () in
  ignore (GMisc.image ~stock:kind ~icon_size:`DIALOG
            ~yalign:0. ~packing:h1#pack ());
  let v1 = GPack.vbox ~spacing:12 ~packing:h1#pack () in
  ignore (GMisc.label
            ~markup:(primaryText title ^ "\n\n" ^ escapeMarkup message)
            ~selectable:true ~yalign:0. ~packing:v1#add ());
  t#add_button_stock bstock `NO;
  t#add_button_stock astock `YES;
  t#set_default_response `NO;
  t#show();
  let res = t#run () in
  t#destroy ();
  res = `YES

(* ------ *)

(* Avoid recursive invocations of the function below (a window receives
   delete events even when it is not sensitive) *)
let inExit = ref false

let doExit () = Lwt_unix.run (Update.unlockArchives ()); exit 0

let safeExit () =
  if not !inExit then begin
    inExit := true;
    if not !busy then exit 0 else
    if twoBox ~parent:(toplevelWindow ()) ~title:"Premature exit"
        ~astock:`YES ~bstock:`NO
        "Unison is working, exit anyway ?"
    then exit 0;
    inExit := false
  end

(* ------ *)

(* warnBox: Display a warning message in a window and wait (unless
   we're in batch mode) for the user to hit "OK" or "Exit". *)
let warnBox ~parent title message =
  let message = transcode message in
  if Prefs.read Globals.batch then begin
    (* In batch mode, just pop up a window and go ahead *)
    let t =
      GWindow.dialog ~parent
        ~border_width:6 ~modal:true ~resizable:false () in
    t#vbox#set_spacing 12;
    let h1 = GPack.hbox ~border_width:6 ~spacing:12 ~packing:t#vbox#pack () in
    ignore (GMisc.image ~stock:`DIALOG_INFO ~icon_size:`DIALOG
              ~yalign:0. ~packing:h1#pack ());
    let v1 = GPack.vbox ~spacing:12 ~packing:h1#pack () in
    ignore (GMisc.label ~markup:(primaryText title ^ "\n\n" ^
                                 escapeMarkup message)
              ~selectable:true ~yalign:0. ~packing:v1#add ());
    t#add_button_stock `CLOSE `CLOSE;
    t#set_default_response `CLOSE;
    ignore (t#connect#response ~callback:(fun _ -> t#destroy ()));
    t#show ()
  end else begin
    inExit := true;
    let ok =
      twoBox ~parent:(toplevelWindow ()) ~title ~astock:`OK ~bstock:`QUIT
        message in
    if not(ok) then doExit ();
    inExit := false
  end

(****)

let accel_paths = Hashtbl.create 17
let underscore_re = Str.regexp_string "_"
class ['a] gMenuFactory
    ?(accel_group=GtkData.AccelGroup.create ())
    ?(accel_path="<DEFAULT ROOT>/")
    ?(accel_modi=[`CONTROL])
    ?(accel_flags=[`VISIBLE]) (menu_shell : 'a) =
  object (self)
    val menu_shell : #GMenu.menu_shell = menu_shell
    val group = accel_group
    val m = accel_modi
    val flags = (accel_flags:Gtk.Tags.accel_flag list)
    val accel_path = accel_path
    method menu = menu_shell
    method accel_group = group
    method accel_path = accel_path
    method private bind
        ?(modi=m) ?key ?callback label ?(name=label) (item : GMenu.menu_item) =
      menu_shell#append item;
      let accel_path = accel_path ^ name in
      let accel_path = Str.global_replace underscore_re "" accel_path in
      (* Default accel path value *)
      if not (Hashtbl.mem accel_paths accel_path) then begin
        Hashtbl.add accel_paths accel_path ();
        GtkData.AccelMap.add_entry accel_path ?key ~modi
      end;
      (* Register this accel path *)
      GtkBase.Widget.set_accel_path item#as_widget accel_path accel_group;
      Gaux.may callback ~f:(fun callback -> item#connect#activate ~callback)
    method add_item ?key ?modi ?callback ?submenu ?bindname label =
      let item = GMenu.menu_item  ~use_mnemonic:true ~label () in
      self#bind ?modi ?key ?callback label ?name:bindname item;
      Gaux.may (submenu : GMenu.menu option) ~f:item#set_submenu;
      item
    method add_image_item ?(image : GObj.widget option)
        ?modi ?key ?callback ?stock ?name label =
      (* GTK 3 does not provide image menu items (there is a way to
         manually create a workaround but that does not work with
         lablgtk. Let's create a regular menu item instead. *)
      let item =
        GMenu.menu_item ~use_mnemonic:true ~label () in
      match stock  with
      | None ->
          self#bind ?modi ?key ?callback label ?name item;
          item
      | Some s ->
          try
            let st = GtkStock.Item.lookup s in
            self#bind
              ?modi ?key:(if st.GtkStock.keyval=0 then key else None)
              ?callback label ?name item;
            item
          with Not_found -> item

    method add_check_item ?active ?modi ?key ?callback label =
      let item = GMenu.check_menu_item ~label ~use_mnemonic:true ?active () in
      self#bind label ?modi ?key
        ?callback:(Gaux.may_map callback ~f:(fun f () -> f item#active))
        (item : GMenu.check_menu_item :> GMenu.menu_item);
      item
    method add_separator () = GMenu.separator_item ~packing:menu_shell#append ()
    method add_submenu label =
      let item = GMenu.menu_item ~use_mnemonic:true ~label () in
      self#bind label item;
      (GMenu.menu ~packing:item#set_submenu (), item)
    method replace_submenu (item : GMenu.menu_item) =
      GMenu.menu ~packing:item#set_submenu ()
end

(**********************************************************************
                         HIGHER-LEVEL WIDGETS
***********************************************************************)

(* FIXME: This is a lowest-effort port of GTK2 pixmap-based code to GTK3.
   It works but is probably needlessly inefficient(??). It should be
   rewritten from scratch to match the new GTK(+Cairo) API and only draw
   updated regions. *)
class stats width height =
  let area =
    let d = GMisc.drawing_area () in
    d#set_width_request width;
    d#set_height_request height;
    d#set_margin_left 4;
    d#set_margin_right 4;
    d#set_margin_top 8;
    d#set_margin_bottom 8;
    d#set_hexpand true;
    d#set_vexpand true;
    d
  in
  object (self)
    inherit GObj.widget_full area#as_widget
    val mutable maxim = ref 0.
    val mutable scale = ref 1.
    val mutable min_scale = 1.
    val mutable values = Array.make width 0.
    val mutable active = false
    val mutable width = float_of_int width
    val mutable height = float_of_int height
    initializer
      ignore (area#misc#connect#size_allocate ~callback:self#resize);
      ignore (area#misc#connect#draw ~callback:self#redraw)

    method resize rect =
      let oldw = truncate width in
      let neww = min rect.Gtk.width 640 in
      if neww > oldw then
        values <- Array.append (Array.make (neww - oldw) 0.) (Array.sub values 0 oldw)
      else if neww < oldw then begin
        Array.blit values (oldw - neww) values 0 neww
      end;
      width <- float_of_int neww;
      height <- float_of_int (min rect.Gtk.height 200);
      area#misc#queue_draw ()

    method redraw cr =
      scale := min_scale;
      while !maxim > !scale do
        scale := !scale *. 1.5
      done;
      Cairo.set_source_rgb cr 1. 1. 1.;
      Cairo.rectangle cr 0. 0. ~w:width ~h:height;
      Cairo.fill cr;
      for i = 0 to truncate width - 1 do
        self#rect cr i values.(max 0 (i - 1)) values.(i)
      done;
      true

    method activate a = active <- a; if a then area#misc#queue_draw ()

    method scale h = height *. h /. !scale

    method private rect cr i v' v =
      let h = self#scale v in
      let h' = self#scale v' in
      let h1 = min h' h in
      let h2 = max h' h in
      Cairo.set_source_rgb cr 0. 0. 0.;
      Cairo.rectangle cr (float_of_int i) (height -. h1) ~w:1. ~h:h1;
      Cairo.fill cr;
      for h = (truncate h1) + 1 to (truncate h2) do
        let v = ((float h -. h1) /. (h2 -. h1)) in
        Cairo.set_source_rgb cr v v v;
        Cairo.rectangle cr (float_of_int i) (height -. float h) ~w:1. ~h:1.;
        Cairo.fill cr;
        ()
      done

    method push v =
      let width = truncate width in
      let need_max = values.(0) = !maxim in
      for i = 0 to width - 2 do
        values.(i) <- values.(i + 1)
      done;
      values.(width - 1) <- v;
      if need_max then begin
        maxim := 0.;
        for i = 0 to width - 1 do maxim := max !maxim values.(i) done
      end else
        maxim := max !maxim v;
      if active then begin
        area#misc#queue_draw ()
      end
  end

let clientWritten = ref 0.
let serverWritten = ref 0.
let emitRate2 = ref 0.
let receiveRate2 = ref 0.

let rate2str v =
  if v > 9.9e3 then begin
    if v > 9.9e6 then
      Format.sprintf "%1.0f MiB/s" (v /. 1e6)
    else if v > 999e3 then
      Format.sprintf "%1.1f MiB/s" (v /. 1e6)
    else
      Format.sprintf "%1.0f KiB/s" (v /. 1e3)
  end else begin
    if v > 990. then
      Format.sprintf "%1.1f KiB/s" (v /. 1e3)
    else if v > 99. then
      Format.sprintf "%1.2f KiB/s" (v /. 1e3)
    else
      " "
  end

let mib = 1024. *. 1024.
let kib2str v =
  if v > 100_000_000. then
    Format.sprintf "%.0f MiB" (v /. mib)
  else if v > 1_000_000. then
    Format.sprintf "%.1f MiB" (v /. mib)
  else if v > 1024. then
    Format.sprintf "%.1f KiB" (v /. 1024.)
  else
    Format.sprintf "%.0f B" v

let statistics () =
  let title = "Statistics" in
  let t = GWindow.dialog ~title ~parent:(toplevelWindow ()) () in
  let t_dismiss = GButton.button ~stock:`CLOSE ~packing:t#action_area#add () in
  t_dismiss#grab_default ();
  let dismiss () = t#misc#hide () in
  ignore (t_dismiss#connect#clicked ~callback:dismiss);
  ignore (t#event#connect#delete ~callback:(fun _ -> dismiss (); true));

  let emission = new stats 320 50 in
  t#vbox#pack ~expand:false ~padding:4 (emission :> GObj.widget);
  let reception = new stats 320 50 in
  t#vbox#pack ~expand:false ~padding:4 (reception :> GObj.widget);

  let cols = new GTree.column_list in
  let c_1 = cols#add Gobject.Data.string in
  let c_client = cols#add Gobject.Data.string in
  let c_server = cols#add Gobject.Data.string in
  let c_total = cols#add Gobject.Data.string in
  let lst = GTree.list_store cols in
  let l = GTree.view ~model:lst ~enable_search:false ~packing:(t#vbox#add) () in
  l#selection#set_mode `NONE;
  ignore (l#append_column (GTree.view_column ~title:""
    ~renderer:(GTree.cell_renderer_text [], ["text", c_1]) ()));
  ignore (l#append_column (GTree.view_column ~title:"Client"
    ~renderer:(GTree.cell_renderer_text [`XALIGN 1.0], ["text", c_client]) ()));
  ignore (l#append_column (GTree.view_column ~title:"Server"
    ~renderer:(GTree.cell_renderer_text [`XALIGN 1.0], ["text", c_server]) ()));
  ignore (l#append_column (GTree.view_column ~title:"Total"
    ~renderer:(GTree.cell_renderer_text [`XALIGN 1.0], ["text", c_total]) ()));
  let rate_row = lst#append () in
  ignore (lst#set ~row:rate_row ~column:c_1 "Reception rate");
  let receive_row = lst#append () in
  ignore (lst#set ~row:receive_row ~column:c_1 "Data received");
  let data_row = lst#append () in
  ignore (lst#set ~row:data_row ~column:c_1 "File data written");

  ignore (t#event#connect#map ~callback:(fun _ ->
    emission#activate true;
    reception#activate true;
    false));
  ignore (t#event#connect#unmap ~callback:(fun _ ->
    emission#activate false;
    reception#activate false;
    false));

  let delay = 0.5 in
  let a = 0.5 in
  let b = 0.8 in

  let emittedBytes = ref 0. in
  let emitRate = ref 0. in
  let receivedBytes = ref 0. in
  let receiveRate = ref 0. in

  let stopCounter = ref 0 in

  let updateTable () =
    let row = rate_row in
    lst#set ~row ~column:c_client (rate2str !receiveRate2);
    lst#set ~row ~column:c_server (rate2str !emitRate2);
    lst#set ~row ~column:c_total (rate2str (!receiveRate2 +. !emitRate2));
    let row = receive_row in
    lst#set ~row ~column:c_client (kib2str !receivedBytes);
    lst#set ~row ~column:c_server (kib2str !emittedBytes);
    lst#set ~row ~column:c_total (kib2str (!receivedBytes +. !emittedBytes));
    let row = data_row in
    lst#set ~row ~column:c_client (kib2str !clientWritten);
    lst#set ~row ~column:c_server (kib2str !serverWritten);
    lst#set ~row ~column:c_total (kib2str (!clientWritten +. !serverWritten))
  in
  let timeout _ =
    emitRate :=
      a *. !emitRate +.
      (1. -. a) *. (!Remote.emittedBytes -. !emittedBytes) /. delay;
    emitRate2 :=
      b *. !emitRate2 +.
      (1. -. b) *. (!Remote.emittedBytes -. !emittedBytes) /. delay;
    emission#push !emitRate;
    receiveRate :=
      a *. !receiveRate +.
      (1. -. a) *. (!Remote.receivedBytes -. !receivedBytes) /. delay;
    receiveRate2 :=
      b *. !receiveRate2 +.
      (1. -. b) *. (!Remote.receivedBytes -. !receivedBytes) /. delay;
    reception#push !receiveRate;
    emittedBytes := !Remote.emittedBytes;
    receivedBytes := !Remote.receivedBytes;
    if !stopCounter > 0 then decr stopCounter;
    if !stopCounter = 0 then begin
      emitRate2 := 0.; receiveRate2 := 0.;
    end;
    updateTable ();
    !stopCounter <> 0
  in
  let startStats () =
    if !stopCounter = 0 then begin
      emittedBytes := !Remote.emittedBytes;
      receivedBytes := !Remote.receivedBytes;
      stopCounter := -1;
      ignore (GMain.Timeout.add ~ms:(truncate (delay *. 1000.))
                ~callback:timeout)
    end else
      stopCounter := -1
  in
  let stopStats () = stopCounter := 10 in
  (t, startStats, stopStats)

(* ------ *)

let gui_safe_eprintf fmt =
  Printf.ksprintf (fun s ->
    if System.has_stderr ~info:s then Printf.eprintf "%s%!" s) fmt

let fatalError ?(quit=false) message =
  let () =
    Trace.sendLogMsgsToStderr := false; (* We don't know if stderr is available *)
    try Trace.log (message ^ "\n")
    with Util.Fatal _ -> () in (* Can't allow fatal errors in fatal error handler *)
  let title = "Fatal error" in
  let toplevelWindow =
    try toplevelWindow ()
    with Util.Fatal err ->
      begin
        gui_safe_eprintf "\n%s:\n%s\n\n%s\n\n" title err message;
        exit 1
      end
  in
  let t =
    GWindow.dialog ~parent:toplevelWindow
      ~border_width:6 ~modal:true ~resizable:false () in
  t#vbox#set_spacing 12;
  let h1 = GPack.hbox ~border_width:6 ~spacing:12 ~packing:t#vbox#pack () in
  ignore (GMisc.image ~stock:`DIALOG_ERROR ~icon_size:`DIALOG
            ~yalign:0. ~packing:h1#pack ());
  let v1 = GPack.vbox ~spacing:12 ~packing:h1#pack () in
  ignore (GMisc.label
            ~markup:(primaryText title ^ "\n\n" ^
                     escapeMarkup (transcode message))
            ~line_wrap:true ~selectable:true ~yalign:0. ~packing:v1#add ());
  t#add_button_stock `QUIT `QUIT;
  if not quit then t#add_button_stock `CLOSE `CLOSE;
  t#set_default_response (if quit then `QUIT else `CLOSE);
  ignore (t#connect#response
            ~callback:(function `QUIT -> exit 1 | _ -> ()));
  t#show(); ignore (t#run ()); t#destroy ();
  if quit then exit 1

let fatalErrorHandler = ref (fatalError ~quit:true)

(* ------ *)

let getFirstRoot () =
  let t = GWindow.dialog ~parent:(toplevelWindow ()) ~title:"Root selection"
      ~modal:true ~resizable:true () in
  t#misc#grab_focus ();

  let hb = GPack.hbox
      ~packing:(t#vbox#pack ~expand:false ~padding:15) () in
  ignore(GMisc.label ~text:tryAgainMessage
           ~justify:`LEFT
           ~packing:(hb#pack ~expand:false ~padding:15) ());

  let f1 = GPack.hbox ~spacing:4
      ~packing:(t#vbox#pack ~expand:true ~padding:4) () in
  ignore (GMisc.label ~text:"Dir:" ~packing:(f1#pack ~expand:false) ());
  let fileE = GEdit.entry ~packing:f1#add () in
  fileE#misc#grab_focus ();
  let b = GFile.chooser_button ~action:`SELECT_FOLDER
    ~title:"Select a local directory"
    ~packing:(f1#pack ~expand:false) () in
  ignore (b#connect#selection_changed ~callback:(fun () ->
            if not fileE#is_focus then
              fileE#set_text (match b#filename with None -> "" | Some s -> s)));
  ignore (fileE#connect#changed ~callback:(fun () ->
            if fileE#is_focus then ignore (b#set_filename fileE#text)));

  let f3 = t#action_area in
  let result = ref None in
  let contCommand() =
    result := Some (Util.trimWhitespace fileE#text);
    t#destroy () in
  let cancelButton = GButton.button ~stock:`CANCEL ~packing:f3#add () in
  ignore (cancelButton#connect#clicked
            ~callback:(fun () -> result := None; t#destroy()));
  let contButton = GButton.button ~stock:`OK ~packing:f3#add () in
  ignore (contButton#connect#clicked ~callback:contCommand);
  ignore (fileE#connect#activate ~callback:contCommand);
  contButton#grab_default ();
  t#show ();
  ignore (t#connect#destroy ~callback:GMain.Main.quit);
  GMain.Main.main ();
  match !result with None -> None
  | Some file ->
      Some(Clroot.clroot2string(Clroot.ConnectLocal(Some file)))

(* ------ *)

let getSecondRoot () =
  let t = GWindow.dialog ~parent:(toplevelWindow ()) ~title:"Root selection"
      ~modal:true ~resizable:true () in
  t#misc#grab_focus ();

  let message = "Please enter the second directory you want to synchronize." in

  let vb = t#vbox in
  let hb = GPack.hbox ~packing:(vb#pack ~expand:false ~padding:15) () in
  ignore(GMisc.label ~text:message
           ~justify:`LEFT
           ~packing:(hb#pack ~expand:false ~padding:15) ());
  let helpB = GButton.button ~stock:`HELP ~packing:hb#add () in
  ignore (helpB#connect#clicked
            ~callback:(fun () -> okBox ~parent:t ~title:"Picking roots" ~typ:`INFO
                ~message:helpmessage));

  let result = ref None in

  let f = GPack.vbox ~packing:(vb#pack ~expand:false) () in

  let f1 = GPack.hbox ~spacing:4 ~packing:f#add () in
  ignore (GMisc.label ~text:"Directory:" ~packing:(f1#pack ~expand:false) ());
  let fileE = GEdit.entry ~packing:f1#add () in
  fileE#misc#grab_focus ();
  let b = GFile.chooser_button ~action:`SELECT_FOLDER
    ~title:"Select a local directory"
    ~packing:(f1#pack ~expand:false) () in
  ignore (b#connect#selection_changed ~callback:(fun () ->
            if not fileE#is_focus then
              fileE#set_text (match b#filename with None -> "" | Some s -> s)));
  ignore (fileE#connect#changed ~callback:(fun () ->
            if fileE#is_focus then ignore (b#set_filename fileE#text)));

  let f0 = GPack.hbox ~spacing:4 ~packing:f#add () in
  let localB = GButton.radio_button ~packing:(f0#pack ~expand:false)
      ~label:"Local" () in
  let sshB = GButton.radio_button ~group:localB#group
      ~packing:(f0#pack ~expand:false)
      ~label:"SSH" () in
  let socketB = GButton.radio_button ~group:sshB#group
      ~packing:(f0#pack ~expand:false) ~label:"Socket" () in

  let f2 = GPack.hbox ~spacing:4 ~packing:f#add () in
  ignore (GMisc.label ~text:"Host:" ~packing:(f2#pack ~expand:false) ());
  let hostE = GEdit.entry ~packing:f2#add () in

  ignore (GMisc.label ~text:"(Optional) User:"
            ~packing:(f2#pack ~expand:false) ());
  let userE = GEdit.entry ~packing:f2#add () in

  ignore (GMisc.label ~text:"Port:"
            ~packing:(f2#pack ~expand:false) ());
  let portE = GEdit.entry ~packing:f2#add () in

  let varLocalRemote = ref (`Local : [`Local|`SSH|`SOCKET]) in
  let localState() =
    varLocalRemote := `Local;
    hostE#misc#set_sensitive false;
    userE#misc#set_sensitive false;
    portE#misc#set_sensitive false;
    b#misc#set_sensitive true in
  let remoteState() =
    hostE#misc#set_sensitive true;
    b#misc#set_sensitive false;
    match !varLocalRemote with
      `SOCKET ->
        (portE#misc#set_sensitive true; userE#misc#set_sensitive false)
    | _ ->
        (portE#misc#set_sensitive false; userE#misc#set_sensitive true) in
  let protoState x =
    varLocalRemote := x;
    remoteState() in
  ignore (localB#connect#clicked ~callback:localState);
  ignore (sshB#connect#clicked ~callback:(fun () -> protoState(`SSH)));
  ignore (socketB#connect#clicked ~callback:(fun () -> protoState(`SOCKET)));
  localState();
  let getRoot() =
    let file = Util.trimWhitespace fileE#text in
    let user = Util.trimWhitespace userE#text in
    let host = Util.trimWhitespace hostE#text in
    let port = Util.trimWhitespace portE#text in
    match !varLocalRemote with
      `Local ->
        Clroot.clroot2string(Clroot.ConnectLocal(Some file))
    | `SSH ->
        Clroot.clroot2string(Clroot.fixHost(
        Clroot.ConnectByShell("ssh",
                              host,
                              (if user="" then None else Some user),
                              (if port="" then None else Some port),
                              Some file)))
    | `SOCKET ->
        Clroot.clroot2string(Clroot.fixHost(
        (* FIX: report an error if the port entry is not well formed *)
        Clroot.ConnectBySocket(host,
                               portE#text,
                               Some file))) in
  let contCommand() =
    try
      let root = getRoot() in
      result := Some root;
      t#destroy ()
    with Failure _ ->
      if portE#text="" then
        okBox ~parent:t ~title:"Error" ~typ:`ERROR ~message:"Please enter a port"
      else okBox ~parent:t ~title:"Error" ~typ:`ERROR
          ~message:"The port you specify must be an integer"
    | Util.Transient s | Util.Fatal s | Invalid_argument s | Prefs.IllegalValue s ->
      okBox ~parent:t ~title:"Error" ~typ:`ERROR
        ~message:("Something's wrong with the values you entered, try again.\n" ^ s) in
  let f3 = t#action_area in
  let cancelButton =
    GButton.button ~stock:`CANCEL ~packing:f3#add () in
  ignore (cancelButton#connect#clicked
            ~callback:(fun () -> result := None; t#destroy ()));
  let contButton =
    GButton.button ~stock:`OK ~packing:f3#add () in
  ignore (contButton#connect#clicked ~callback:contCommand);
  contButton#grab_default ();
  ignore (fileE#connect#activate ~callback:contCommand);

  t#show ();
  ignore (t#connect#destroy ~callback:GMain.Main.quit);
  GMain.Main.main ();
  !result

let promptForRoots () =
  match getFirstRoot () with
  | None -> None
  | Some r1 ->
      begin match getSecondRoot () with
      | None -> None
      | Some r2 -> Some (r1, r2)
      end

(* ------ *)

type 'a pwdDialog = {
  labelAppend : string -> unit;
  presentAndRun : unit -> unit;
  closeInput : unit -> unit;
}
let passwordDialogs = ref []

let createPasswordDialog passwordDialog rootName msg response =
  let t =
    GWindow.dialog ~parent:(toplevelWindow ())
      ~title:"Unison: SSH connection" ~position:`CENTER
      ~modal:true ~resizable:false ~border_width:6 () in
  t#misc#grab_focus ();

  t#vbox#set_spacing 12;

  let header =
    primaryText
      (Format.sprintf "Connecting to '%s'..." (Unicode.protect rootName)) in

  let h1 = GPack.hbox ~border_width:6 ~spacing:12 ~packing:t#vbox#pack () in
  ignore (GMisc.image ~stock:`DIALOG_AUTHENTICATION ~icon_size:`DIALOG
            ~yalign:0. ~packing:h1#pack ());
  let v1 = GPack.vbox ~spacing:12 ~packing:h1#pack () in
  let msgLbl = (GMisc.label ~markup:(header ^ "\n\n" ^
                              escapeMarkup (Unicode.protect msg))
           ~selectable:true ~yalign:0. ~packing:v1#pack ()) in

  let passwordE = GEdit.entry ~packing:v1#pack ~visibility:false () in
  passwordE#misc#grab_focus ();

  t#add_button_stock `QUIT `QUIT;
  t#add_button_stock `OK `OK;
  t#set_default_response `OK;
  ignore (passwordE#connect#activate ~callback:(fun _ -> t#response `OK));

  t#show();

  let labelAppend msg =
    msgLbl#set_label (msgLbl#label ^ escapeMarkup (Unicode.protect msg)) in
  let presentAndRun () =
    try t#present (); ignore (t#run ()) with Failure _ -> () in
  let closeInput () =
    passwordE#set_editable false; passwordE#set_visible false; passwordE#set_text "" in
  passwordDialog := Some { labelAppend; presentAndRun; closeInput };

  let callback res =
    passwordDialog := None;
    let pwd = passwordE#text in
    let editable = passwordE#editable in
    t#destroy ();
    gtk_sync true;
    match res with
    | `DELETE_EVENT | `QUIT -> safeExit ()
    | `OK -> if editable then response pwd
  in
  ignore (t#connect#response ~callback)

let getPassword passwordDialog rootName msg response =
  match !passwordDialog with
  | Some { labelAppend; _ } -> labelAppend msg
  | None -> createPasswordDialog passwordDialog rootName msg response

let disablePassword passwordDialog () =
  match !passwordDialog with
  | Some { closeInput; _ } -> closeInput ()
  | None -> ()

let waitForPasswordWindowClosing () =
  let present x =
    match !x with
    | Some { presentAndRun; _ } -> presentAndRun ()
    | None -> ()
  in
  passwordDialogs :=
    Safelist.filter (fun x -> present x; !x <> None) !passwordDialogs

let termInteract rootName =
  let d = ref None in
  passwordDialogs := d :: !passwordDialogs;
  { Terminal.userInput = getPassword d rootName; endInput = disablePassword d }

(* ------ *)

module React = struct
  type 'a t = { mutable state : 'a; mutable observers : ('a -> unit) list }

  let make v =
    let res = { state = v; observers = [] } in
    let update v =
      if res.state <> v then begin
        res.state <- v; List.iter (fun f -> f v) res.observers
      end
    in
    (res, update)

  let const v = fst (make v)

  let add_observer x f = x.observers <- f :: x.observers

  let state x = x.state

  let lift f x =
    let (res, update) = make (f (state x)) in
    add_observer x (fun v -> update (f v));
    res

  let lift2 f x y =
    let (res, update) = make (f (state x) (state y)) in
    add_observer x (fun v -> update (f v (state y)));
    add_observer y (fun v -> update (f (state x) v));
    res

  let lift3 f x y z =
    let (res, update) = make (f (state x) (state y) (state z)) in
    add_observer x (fun v -> update (f v (state y) (state z)));
    add_observer y (fun v -> update (f (state x) v (state z)));
    add_observer z (fun v -> update (f (state x) (state y) v));
    res

  let iter f x = f (state x); add_observer x f

  type 'a event = { mutable ev_observers : ('a -> unit) list }

  let make_event () =
    let res = { ev_observers = [] } in
    let trigger v = List.iter (fun f -> f v) res.ev_observers in
    (res, trigger)

  let add_ev_observer x f = x.ev_observers <- f :: x.ev_observers

  let hold v e =
    let (res, update) = make v in
    add_ev_observer e update;
    res

  let iter_ev f e = add_ev_observer e f

  let lift_ev f e =
    let (res, trigger) = make_event () in
    add_ev_observer e (fun x -> trigger (f x));
    res

  module Ops = struct
    let (>>) x f = lift f x
    let (>|) x f = iter f x

    let (>>>) x f = lift_ev f x
    let (>>|) x f = iter_ev f x
  end
end

module GtkReact = struct
  let entry (e : #GEdit.entry) =
    let (res, update) = React.make e#text in
    ignore (e#connect#changed ~callback:(fun () -> update (e#text)));
    res

  let text_combo ((c, _) : _ GEdit.text_combo) =
    let (res, update) = React.make c#active in
    ignore (c#connect#changed ~callback:(fun () -> update (c#active)));
    res

  let toggle_button (b : #GButton.toggle_button) =
    let (res, update) = React.make b#active in
    ignore (b#connect#toggled ~callback:(fun () -> update (b#active)));
    res

  let file_chooser (c : #GFile.chooser) =
    let (res, update) = React.make c#filename in
    ignore (c#connect#selection_changed
              ~callback:(fun () -> update (c#filename)));
    res

  let current_tree_view_selection (t : #GTree.view) =
    let m =t#model in
    Safelist.map (fun p -> m#get_row_reference p) t#selection#get_selected_rows

  let tree_view_selection_changed t =
    let (res, trigger) = React.make_event () in
    ignore (t#selection#connect#changed
              ~callback:(fun () -> trigger (current_tree_view_selection t)));
    res

  let tree_view_selection t =
    React.hold (current_tree_view_selection t) (tree_view_selection_changed t)

  let label (l : #GMisc.label) x = React.iter (fun v -> l#set_text v) x

  let label_underlined (l : #GMisc.label) x =
    React.iter (fun v -> l#set_text v; l#set_use_underline true) x

  let label_markup (l : #GMisc.label) x =
    React.iter (fun v -> l#set_text v; l#set_use_markup true) x

  let show w x =
    React.iter (fun b -> if b then w#misc#show () else w#misc#hide ()) x
  let set_sensitive w x = React.iter (fun b -> w#misc#set_sensitive b) x
end

open React.Ops

(* ------ *)

(* Resize an object (typically, a label with line wrapping) so that it
   use all its available space *)
let adjustSize (w : #GObj.widget) =
  let notYet = ref true in
  ignore
    (w#misc#connect#size_allocate ~callback:(fun r ->
       if !notYet then begin
         notYet := false;
         (* JV: I have no idea where the 12 comes from.  Without it,
            a window resize may happen. *)
         w#misc#set_size_request ~width:(max 10 (r.Gtk.width - 12)) ()
       end))

let createProfile parent =
  let assistant = GAssistant.assistant ~modal:true () in
  assistant#set_transient_for parent#as_window;
  assistant#set_modal true;
  assistant#set_title "Profile Creation";

  let empty s = s = "" in
  let nonEmpty s = s <> "" in
(*
  let integerRe =
    Str.regexp "\\([+-]?[0-9]+\\|0o[0-7]+\\|0x[0-9a-zA-Z]+\\)" in
*)
  let integerRe = Str.regexp "[0-9]+" in
  let isInteger s =
    Str.string_match integerRe s 0 && Str.matched_string s = s in

  (* Introduction *)
  let intro =
    GMisc.label
      ~xpad:12 ~ypad:12
      ~text:"Welcome to the Unison Profile Creation Assistant.\n\n\
             Click \"Next\" to begin."
    () in
  ignore
    (assistant#append_page
       ~title:"Profile Creation"
       ~page_type:`INTRO
       ~complete:true
      intro#as_widget);

  (* Profile name and description *)
  let description = GPack.vbox ~border_width:12 ~spacing:6 () in
  adjustSize
    (GMisc.label ~xalign:0. ~line_wrap:true ~justify:`LEFT
       ~text:"Please enter the name of the profile and \
              possibly a short description."
       ~packing:(description#pack ~expand:false) ());
  let tbl =
    let al = GBin.alignment ~packing:(description#pack ~expand:false) () in
    al#set_left_padding 12;
    GPack.table ~rows:2 ~columns:2 ~col_spacings:12 ~row_spacings:6
      ~packing:(al#add) () in
  let nameEntry =
    GEdit.entry ~activates_default:true
      ~packing:(tbl#attach ~left:1 ~top:0 ~expand:`X) () in
  let name = GtkReact.entry nameEntry in
  ignore (GMisc.label ~text:"Profile _name:" ~xalign:0.
            ~use_underline:true ~mnemonic_widget:nameEntry
            ~packing:(tbl#attach ~left:0 ~top:0 ~expand:`NONE) ());
  let labelEntry =
    GEdit.entry ~activates_default:true
       ~packing:(tbl#attach ~left:1 ~top:1 ~expand:`X) () in
  let label = GtkReact.entry labelEntry in
  ignore (GMisc.label ~text:"_Description:" ~xalign:0.
            ~use_underline:true ~mnemonic_widget:labelEntry
            ~packing:(tbl#attach ~left:0 ~top:1 ~expand:`NONE) ());
  let existingProfileLabel =
    GMisc.label ~xalign:1. ~packing:(description#pack ~expand:false) ()
  in
  adjustSize existingProfileLabel;
  GtkReact.label_markup existingProfileLabel
    (name >> fun s -> Format.sprintf " <i>Profile %s already exists.</i>"
                        (escapeMarkup s));
  let profileExists =
    name >> fun s -> s <> "" && System.file_exists (Prefs.profilePathname s)
  in
  GtkReact.show existingProfileLabel profileExists;

  ignore
    (assistant#append_page
       ~title:"Profile Description"
       ~page_type:`CONTENT
       description#as_widget);
  let setPageComplete page b = assistant#set_page_complete page#as_widget b in
  React.lift2 (&&) (name >> nonEmpty) (profileExists >> not)
    >| setPageComplete description;

  let connection = GPack.vbox ~border_width:12 ~spacing:18 () in
  let al = GBin.alignment ~packing:(connection#pack ~expand:false) () in
  al#set_left_padding 12;
  let vb =
    GPack.vbox ~spacing:6 ~packing:(al#add) () in
  adjustSize
    (GMisc.label ~xalign:0. ~line_wrap:true ~justify:`LEFT
       ~text:"You can use Unison to synchronize a local directory \
              with another local directory, or with a remote directory."
       ~packing:(vb#pack ~expand:false) ());
  adjustSize
    (GMisc.label ~xalign:0. ~line_wrap:true ~justify:`LEFT
       ~text:"Please select the kind of synchronization \
              you want to perform."
       ~packing:(vb#pack ~expand:false) ());
  let tbl =
    let al = GBin.alignment ~packing:(vb#pack ~expand:false) () in
    al#set_left_padding 12;
    GPack.table ~rows:2 ~columns:2 ~col_spacings:12 ~row_spacings:6
      ~packing:(al#add) () in
  ignore (GMisc.label ~text:"Description:" ~xalign:0. ~yalign:0.
            ~packing:(tbl#attach ~left:0 ~top:1 ~expand:`NONE) ());
  let kindCombo =
    let al =
      GBin.alignment ~xscale:0. ~xalign:0.
        ~packing:(tbl#attach ~left:1 ~top:0) () in
    GEdit.combo_box_text
      ~strings:["Local"; "Using SSH";
                "Through a plain TCP connection"]
      ~active:0 ~packing:(al#add) ()
  in
  ignore (GMisc.label ~text:"Synchronization _kind:" ~xalign:0.
            ~use_underline:true ~mnemonic_widget:(fst kindCombo)
            ~packing:(tbl#attach ~left:0 ~top:0 ~expand:`NONE) ());
  let kind =
    GtkReact.text_combo kindCombo
      >> fun i -> List.nth [`Local; `SSH; `SOCKET] i
  in
  let isLocal = kind >> fun k -> k = `Local in
  let isSSH = kind >> fun k -> k = `SSH in
  let isSocket = kind >> fun k -> k = `SOCKET in
  let descrLabel =
    GMisc.label ~xalign:0. ~line_wrap:true
       ~packing:(tbl#attach ~left:1 ~top:1 ~expand:`X) ()
  in
  adjustSize descrLabel;
  GtkReact.label descrLabel
    (kind >> fun k ->
     match k with
       `Local ->
          "Local synchronization."
     | `SSH ->
          "This is the recommended way to synchronize \
           with a remote machine.  A\xc2\xa0remote instance of Unison is \
           automatically started via SSH."
     | `SOCKET ->
          "Synchronization with a remote machine by connecting \
           to an instance of Unison already listening \
           on a specific TCP port.");
  let vb = GPack.vbox ~spacing:6 ~packing:(connection#add) () in
  GtkReact.show vb (isLocal >> not);
  ignore (GMisc.label ~markup:"<b>Configuration</b>" ~xalign:0.
            ~packing:(vb#pack ~expand:false) ());
  let al = GBin.alignment ~packing:(vb#add) () in
  al#set_left_padding 12;
  let vb = GPack.vbox ~spacing:6 ~packing:(al#add) () in
  let requirementLabel =
    GMisc.label ~xalign:0. ~line_wrap:true
       ~packing:(vb#pack ~expand:false) ()
  in
  adjustSize requirementLabel;
  GtkReact.label requirementLabel
    (kind >> fun k ->
     match k with
       `Local ->
          ""
     | `SSH ->
          "There must be an SSH client installed on this machine, \
           and Unison and an SSH server installed on the remote machine."
     | `SOCKET ->
          "There must be a Unison server running on the remote machine, \
           listening on the port that you specify here.  \
           (Use \"Unison -socket xxx\" on the remote machine to start \
           the Unison server.)");
  let connDescLabel =
    GMisc.label ~xalign:0. ~line_wrap:true
       ~packing:(vb#pack ~expand:false) ()
  in
  adjustSize connDescLabel;
  GtkReact.label connDescLabel
    (kind >> fun k ->
     match k with
       `Local  -> ""
     | `SSH    -> "Please enter the host to connect to and a user name, \
                   if different from your user name on this machine."
     | `SOCKET -> "Please enter the host and port to connect to.");
  let tbl =
    let al = GBin.alignment ~packing:(vb#pack ~expand:false) () in
    al#set_left_padding 12;
    GPack.table ~rows:2 ~columns:2 ~col_spacings:12 ~row_spacings:6
      ~packing:(al#add) () in
  let hostEntry =
    GEdit.entry ~packing:(tbl#attach ~left:1 ~top:0 ~expand:`X) () in
  let host = GtkReact.entry hostEntry in
  ignore (GMisc.label ~text:"_Host:" ~xalign:0.
            ~use_underline:true ~mnemonic_widget:hostEntry
            ~packing:(tbl#attach ~left:0 ~top:0 ~expand:`NONE) ());
  let userEntry =
    GEdit.entry ~packing:(tbl#attach ~left:1 ~top:1 ~expand:`X) ()
  in
  GtkReact.show userEntry (isSocket >> not);
  let user = GtkReact.entry userEntry in
  GtkReact.show
    (GMisc.label ~text:"_User:" ~xalign:0. ~yalign:0.
       ~use_underline:true ~mnemonic_widget:userEntry
       ~packing:(tbl#attach ~left:0 ~top:1 ~expand:`NONE) ())
    (isSocket >> not);
  let portEntry =
    GEdit.entry ~packing:(tbl#attach ~left:1 ~top:1 ~expand:`X) ()
  in
  GtkReact.show portEntry isSocket;
  let port = GtkReact.entry portEntry in
  GtkReact.show
    (GMisc.label ~text:"_Port:" ~xalign:0. ~yalign:0.
       ~use_underline:true ~mnemonic_widget:portEntry
       ~packing:(tbl#attach ~left:0 ~top:1 ~expand:`NONE) ())
    isSocket;
  let compressLabel =
    GMisc.label ~xalign:0. ~line_wrap:true
      ~text:"Data compression can greatly improve performance \
             on slow connections.  However, it may slow down \
             things on (fast) local networks."
      ~packing:(vb#pack ~expand:false) ()
  in
  adjustSize compressLabel;
  GtkReact.show compressLabel isSSH;
  let compressButton =
    let al = GBin.alignment ~packing:(vb#pack ~expand:false) () in
    al#set_left_padding 12;
    (GButton.check_button ~label:"Enable _compression" ~use_mnemonic:true
       ~active:true ~packing:(al#add) ())
  in
  GtkReact.show compressButton isSSH;
  let compress = GtkReact.toggle_button compressButton in
(*XXX Disabled for now... *)
(*
  adjustSize
    (GMisc.label ~xalign:0. ~line_wrap:true
       ~text:"If this is possible, it is recommended that Unison \
              attempts to connect immediately to the remote machine, \
              so that it can perform some auto-detections."
       ~packing:(vb#pack ~expand:false) ());
  let connectImmediately =
    let al = GBin.alignment ~packing:(vb#pack ~expand:false) () in
    al#set_left_padding 12;
    GtkReact.toggle_button
      (GButton.check_button ~label:"Connect _immediately" ~use_mnemonic:true
         ~active:true ~packing:(al#add) ())
  in
  let connectImmediately =
    React.lift2 (&&) connectImmediately (isLocal >> not) in
*)
  let isNotUnixPath s = String.length s > 0 && s.[0] <> '{' in
  let isTCPsocket = React.lift2 (&&) isSocket (host >> isNotUnixPath) in
  let pageComplete =
    React.lift2 (||) isLocal
      (React.lift2 (&&) (host >> nonEmpty)
          (React.lift2 (||)
              (React.lift2 (&&) isTCPsocket (port >> isInteger))
              (React.lift2 (&&) (isTCPsocket >> not) (port >> empty))))
  in
  ignore
    (assistant#append_page
       ~title:"Connection Setup"
       ~page_type:`CONTENT
       connection#as_widget);
  pageComplete >| setPageComplete connection;

  (* Connection to server *)
(*XXX Disabled for now... Fill in this page
  let connectionInProgress = GMisc.label ~text:"..." () in
  let p =
    assistant#append_page
      ~title:"Connecting to Server..."
      ~page_type:`PROGRESS
      connectionInProgress#as_widget
  in
  ignore
    (assistant#connect#prepare (fun () ->
       if assistant#current_page = p then begin
         if React.state connectImmediately then begin
           (* XXXX start connection... *)
           assistant#set_page_complete connectionInProgress#as_widget true
         end else
           assistant#set_current_page (p + 1)
       end));
*)

  (* Directory selection *)
  let directorySelection = GPack.vbox ~border_width:12 ~spacing:6 () in
  adjustSize
    (GMisc.label ~xalign:0. ~line_wrap:true ~justify:`LEFT
       ~text:"Please select the two directories that you want to synchronize."
       ~packing:(directorySelection#pack ~expand:false) ());
  let secondDirLabel1 =
    GMisc.label ~xalign:0. ~line_wrap:true ~justify:`LEFT
      ~text:"The second directory is relative to your home \
             directory on the remote machine."
      ~packing:(directorySelection#pack ~expand:false) ()
  in
  adjustSize secondDirLabel1;
  GtkReact.show secondDirLabel1 ((React.lift2 (||) isLocal isSocket) >> not);
  let secondDirLabel2 =
    GMisc.label ~xalign:0. ~line_wrap:true ~justify:`LEFT
      ~text:"The second directory is relative to \
             the working directory of the Unison server \
             running on the remote machine."
      ~packing:(directorySelection#pack ~expand:false) ()
  in
  adjustSize secondDirLabel2;
  GtkReact.show secondDirLabel2 isSocket;
  let tbl =
    let al =
      GBin.alignment ~packing:(directorySelection#pack ~expand:false) () in
    al#set_left_padding 12;
    GPack.table ~rows:2 ~columns:2 ~col_spacings:12 ~row_spacings:6
      ~packing:(al#add) () in
(*XXX Should focus on this button when becomes visible... *)
  let firstDirButton =
    GFile.chooser_button ~action:`SELECT_FOLDER ~title:"First Directory"
       ~packing:(tbl#attach ~left:1 ~top:0 ~expand:`X) ()
  in
  isLocal >| (fun b -> firstDirButton#set_title
                         (if b then "First Directory" else "Local Directory"));
  GtkReact.label_underlined
    (GMisc.label ~xalign:0.
       ~mnemonic_widget:firstDirButton
       ~packing:(tbl#attach ~left:0 ~top:0 ~expand:`NONE) ())
    (isLocal >> fun b ->
       if b then "_First directory:" else "_Local directory:");
  let noneToEmpty o = match o with None -> "" | Some s -> s in
  let firstDir = GtkReact.file_chooser firstDirButton >> noneToEmpty in
  let secondDirButton =
    GFile.chooser_button ~action:`SELECT_FOLDER ~title:"Second Directory"
       ~packing:(tbl#attach ~left:1 ~top:1 ~expand:`X) () in
  let secondDirLabel =
    GMisc.label ~xalign:0.
      ~text:"Se_cond directory:"
      ~use_underline:true ~mnemonic_widget:secondDirButton
      ~packing:(tbl#attach ~left:0 ~top:1 ~expand:`NONE) () in
  GtkReact.show secondDirButton isLocal;
  GtkReact.show secondDirLabel isLocal;
  let remoteDirEdit =
    GEdit.entry ~packing:(tbl#attach ~left:1 ~top:1 ~expand:`X) ()
  in
  let remoteDirLabel =
    GMisc.label ~xalign:0.
      ~text:"_Remote directory:"
      ~use_underline:true ~mnemonic_widget:remoteDirEdit
      ~packing:(tbl#attach ~left:0 ~top:1 ~expand:`NONE) ()
  in
  GtkReact.show remoteDirEdit (isLocal >> not);
  GtkReact.show remoteDirLabel (isLocal >> not);
  let secondDir =
    React.lift3 (fun b l r -> if b then l else r) isLocal
      (GtkReact.file_chooser secondDirButton >> noneToEmpty)
      (GtkReact.entry remoteDirEdit)
  in
  ignore
    (assistant#append_page
       ~title:"Directory Selection"
       ~page_type:`CONTENT
       directorySelection#as_widget);
  React.lift2 (||) (isLocal >> not) (React.lift2 (<>) firstDir secondDir)
    >| setPageComplete directorySelection;

  (* Specific options *)
  let options = GPack.vbox ~border_width:18 ~spacing:12 () in
  (* Do we need to set specific options for FAT partitions?
     If under Windows, then all the options are set properly, except for
     ignoreinodenumbers in case one replica is on a FAT partition on a
     remote non-Windows machine.  As this is unlikely, we do not
     handle this case. *)
  let fat =
    if Util.osType = `Win32 then
      React.const false
    else begin
      let vb =
        GPack.vbox ~spacing:6 ~packing:(options#pack ~expand:false) () in
      let fatLabel =
        GMisc.label ~xalign:0. ~line_wrap:true ~justify:`LEFT
          ~text:"Select the following option if one of your \
                 directory is on a FAT partition.  This is typically \
                 the case for a USB stick."
          ~packing:(vb#pack ~expand:false) ()
      in
      adjustSize fatLabel;
      let fatButton =
        let al = GBin.alignment ~packing:(vb#pack ~expand:false) () in
        al#set_left_padding 12;
        (GButton.check_button
           ~label:"Synchronization involving a _FAT partition"
           ~use_mnemonic:true ~active:false ~packing:(al#add) ())
      in
      GtkReact.toggle_button fatButton
    end
  in
  (* Fastcheck is safe except on FAT partitions and on Windows when
     not in Unicode mode where there is a very slight chance of
     missing an update when a file is moved onto another with the same
     modification time.  Nowadays, FAT is rarely used on working
     partitions.  In most cases, we should be in Unicode mode.
     Thus, it seems sensible to always enable fastcheck. *)
(*
  let fastcheck = isLocal >> not >> (fun b -> b || Util.osType = `Win32) in
*)
  (* Unicode mode can be problematic when the source machine is under
     Windows and the remote machine is not, as Unison may have already
     been used using the legacy Latin 1 encoding.  Cygwin also did not
     handle Unicode before version 1.7. *)
  let vb = GPack.vbox ~spacing:6 ~packing:(options#pack ~expand:false) () in
  let askUnicode = React.const false in
(* isLocal >> not >> fun b -> (b || Util.isCygwin) && Util.osType = `Win32 in*)
  GtkReact.show vb askUnicode;
  adjustSize
    (GMisc.label ~xalign:0. ~line_wrap:true ~justify:`LEFT
       ~text:"When synchronizing in case insensitive mode, \
              Unison has to make some assumptions regarding \
              filename encoding.  If ensure, use Unicode."
       ~packing:(vb#pack ~expand:false) ());
  let vb =
    let al = GBin.alignment
      ~xscale:0. ~xalign:0. ~packing:(vb#pack ~expand:false) () in
    al#set_left_padding 12;
    GPack.vbox ~spacing:0 ~packing:(al#add) ()
  in
  ignore
    (GMisc.label ~xalign:0. ~text:"Filename encoding:"
       ~packing:(vb#pack ~expand:false) ());
  let hb =
    let al = GBin.alignment
      ~xscale:0. ~xalign:0. ~packing:(vb#pack ~expand:false) () in
    al#set_left_padding 12;
    GPack.button_box `VERTICAL ~layout:`START
      ~spacing:0 ~packing:(al#add) ()
  in
  let unicodeButton =
    GButton.radio_button ~label:"_Unicode" ~use_mnemonic:true ~active:true
      ~packing:(hb#add) ()
  in
  ignore
    (GButton.radio_button ~label:"_Latin 1" ~use_mnemonic:true
       ~group:unicodeButton#group ~packing:(hb#add) ());
(*
  let unicode =
    React.lift2 (||) (askUnicode >> not) (GtkReact.toggle_button unicodeButton)
  in
*)
  let p =
    assistant#append_page
      ~title:"Specific Options" ~complete:true
      ~page_type:`CONTENT
      options#as_widget
  in
  ignore
    (assistant#connect#prepare ~callback:(fun () ->
       if assistant#current_page = p &&
          not (Util.osType <> `Win32 || React.state askUnicode)
       then
         assistant#set_current_page (p + 1)));

  let conclusionOk = "You have now finished filling in the profile.\n\n\
             Click \"Apply\" to create it."
  and conclusionFail = "There was an error when preparing the profile.\n\n\
             Click \"Back\" to review what you entered." in
  let conclusion =
    GMisc.label
      ~xpad:12 ~ypad:12
      ~text:conclusionOk
    () in
  let conclusionp =
    (assistant#append_page
       ~title:"Done" ~complete:true
       ~page_type:`CONFIRM
       conclusion#as_widget) in

  let makeRemoteRoot () =
    let secondDir = Util.trimWhitespace (React.state secondDir) in
    let host = Util.trimWhitespace (React.state host) in
    let user = match React.state user with "" -> None | u -> Some (Util.trimWhitespace u) in
    let secondRoot =
      match React.state kind with
        `Local  -> Clroot.ConnectLocal (Some secondDir)
      | `SSH    -> Clroot.ConnectByShell
                     ("ssh", host, user, None, Some secondDir)
      | `SOCKET -> Clroot.ConnectBySocket
                     (host, React.state port, Some secondDir)
    in
    try
      let root = Clroot.clroot2string (Clroot.fixHost secondRoot) in
      ignore (Clroot.parseRoot root);
      Some root
    with
    | Util.Transient s | Util.Fatal s | Invalid_argument s | Prefs.IllegalValue s ->
        begin
          okBox ~parent ~title:"Error" ~typ:`ERROR
            ~message:("There was a problem with the remote root "
              ^ "data you entered.\n\n" ^ s);
          None
        end
  in
  ignore (assistant#connect#prepare ~callback:(fun () ->
    if assistant#current_page = conclusionp then
    let ok = (React.state kind = `Local) || (makeRemoteRoot () <> None) in
    let () = setPageComplete conclusion ok in
    if ok then conclusion#set_text conclusionOk
    else conclusion#set_text conclusionFail));

  let profileName = ref None in
  let saveProfile () =
    let filename = Prefs.profilePathname (React.state name) in
    begin try
      let ch =
        System.open_out_gen [Open_wronly; Open_creat; Open_excl] 0o600 filename
      in
      let close_on_error f =
        try f () with e -> close_out_noerr ch; raise e
      in
      close_on_error (fun () ->
      Printf.fprintf ch "# Unison preferences\n";
      let label = React.state label in
      if label <> "" then Printf.fprintf ch "label = %s\n" label;
      Printf.fprintf ch "root = %s\n" (React.state firstDir);
      let secondRoot =
        match makeRemoteRoot () with
        | None -> assert false (* We should never reach here due to validation above *)
        | Some s -> s
      in
      Printf.fprintf ch "root = %s\n" secondRoot;
      if React.state compress && React.state kind = `SSH then
        Printf.fprintf ch "sshargs = -C\n";
(*
      if React.state fastcheck then
        Printf.fprintf ch "fastcheck = true\n";
      if React.state unicode then
        Printf.fprintf ch "unicode = true\n";
*)
      if React.state fat then Printf.fprintf ch "fat = true\n";
      close_out ch);
      profileName := Some (React.state name)
    with Sys_error _ as e ->
      okBox ~parent:assistant ~typ:`ERROR ~title:"Could not save profile"
        ~message:(Uicommon.exn2string e)
    end;
    assistant#destroy ();
  in
  ignore (assistant#connect#close ~callback:saveProfile);
  ignore (assistant#connect#destroy ~callback:GMain.Main.quit);
  ignore (assistant#connect#cancel ~callback:assistant#destroy);
  assistant#show ();
  GMain.Main.main ();
  !profileName

(* ------ *)

let nameOfType t =
  match t with
    `BOOL        -> "boolean"
  | `BOOLDEF     -> "boolean"
  | `INT         -> "integer"
  | `STRING      -> "text"
  | `STRING_LIST -> "text list"
  | `CUSTOM      -> "custom"
  | `UNKNOWN     -> "unknown"

let defaultValue t =
  match t with
    `BOOL        -> ["true"]
  | `BOOLDEF     -> ["true"]
  | `INT         -> ["0"]
  | `STRING      -> [""]
  | `STRING_LIST -> []
  | `CUSTOM      -> []
  | `UNKNOWN     -> []

let editPreference parent nm ty vl =
  let t =
    GWindow.dialog ~parent ~border_width:12
      ~title:"Edit the Preference"
      ~modal:true () in
  let vb = t#vbox in
  vb#set_spacing 6;

  let isList =
    match ty with
      `STRING_LIST | `CUSTOM | `UNKNOWN -> true
    | _ -> false
  in
  let columns = if isList then 5 else 4 in
  let rows = if isList then 3 else 2 in
  let tbl =
    GPack.table ~rows ~columns ~col_spacings:12 ~row_spacings:6
      ~packing:(vb#pack ~expand:false) () in
  ignore (GMisc.label ~text:"Preference:" ~xalign:0.
            ~packing:(tbl#attach ~left:0 ~top:0 ~expand:`NONE) ());
  ignore (GMisc.label ~text:"Description:" ~xalign:0.
            ~packing:(tbl#attach ~left:0 ~top:1 ~expand:`NONE) ());
  ignore (GMisc.label ~text:"Type:" ~xalign:0.
            ~packing:(tbl#attach ~left:0 ~top:2 ~expand:`NONE) ());
  ignore (GMisc.label ~text:(Unicode.protect nm) ~xalign:0. ~selectable:true ()
            ~packing:(tbl#attach ~left:1 ~top:0 ~expand:`X));
  let (doc, _) = Prefs.documentation nm in
  ignore (GMisc.label ~text:doc ~xalign:0. ~selectable:true ()
            ~packing:(tbl#attach ~left:1 ~top:1 ~expand:`X));
  ignore (GMisc.label ~text:(nameOfType ty) ~xalign:0. ~selectable:true ()
            ~packing:(tbl#attach ~left:1 ~top:2 ~expand:`X));
  let newValue =
    if isList then begin
      let valueLabel =
        GMisc.label ~text:"V_alue:" ~use_underline:true ~xalign:0. ~yalign:0.
          ~packing:(tbl#attach ~left:0 ~top:3 ~expand:`NONE) ()
      in
      let cols = new GTree.column_list in
      let c_value = cols#add Gobject.Data.string in
      let c_ml = cols#add Gobject.Data.caml in
      let lst_store = GTree.list_store cols in
      let lst =
        let sw =
          GBin.scrolled_window ~packing:(tbl#attach ~left:1 ~top:3 ~expand:`X)
            ~shadow_type:`IN ~height:200 ~width:400
            ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC () in
        GTree.view ~model:lst_store ~headers_visible:false
          ~reorderable:true ~packing:sw#add () in
      valueLabel#set_mnemonic_widget (Some (lst :> GObj.widget));
      let column =
        GTree.view_column
          ~renderer:(GTree.cell_renderer_text [], ["text", c_value]) ()
      in
      ignore (lst#append_column column);
      let vb =
        GPack.button_box
          `VERTICAL ~layout:`START ~spacing:6
          ~packing:(tbl#attach ~left:2 ~top:3 ~expand:`NONE) ()
      in
      let selection = GtkReact.tree_view_selection lst in
      let hasSel = selection >> fun l -> l <> [] in
      let addB =
        GButton.button ~stock:`ADD ~packing:(vb#pack ~expand:false) () in
      let removeB =
        GButton.button ~stock:`REMOVE ~packing:(vb#pack ~expand:false) () in
      let editB =
        GButton.button ~stock:`EDIT ~packing:(vb#pack ~expand:false) () in
      let upB =
        GButton.button ~stock:`GO_UP ~packing:(vb#pack ~expand:false) () in
      let downB =
        GButton.button ~stock:`GO_DOWN ~packing:(vb#pack ~expand:false) () in
      List.iter (fun b -> b#set_xalign 0.) [addB; removeB; editB; upB; downB];
      GtkReact.set_sensitive removeB hasSel;
      let editLabel =
        GMisc.label ~text:"Edited _item:"
          ~use_underline:true ~xalign:0.
          ~packing:(tbl#attach ~left:0 ~top:4 ~expand:`NONE) ()
      in
      let editEntry =
        GEdit.entry ~packing:(tbl#attach ~left:1 ~top:4 ~expand:`X) () in
      editLabel#set_mnemonic_widget (Some (editEntry :> GObj.widget));
      let edit = GtkReact.entry editEntry in
      let edited =
        React.lift2
          (fun l txt ->
             match l with
               [rf] -> lst_store#get ~row:rf#iter ~column:c_ml <> txt
             | _    -> false)
          selection edit
      in
      GtkReact.set_sensitive editB edited;
      let selectionChange = GtkReact.tree_view_selection_changed lst in
      selectionChange >>| (fun s ->
        match s with
          [rf] -> editEntry#set_text
                    (lst_store#get ~row:rf#iter ~column:c_value)
        | _    -> ());
      let add () =
        let txt = editEntry#text in
        let row = lst_store#append () in
        lst_store#set ~row ~column:c_value txt;
        lst_store#set ~row ~column:c_ml txt;
        lst#selection#select_iter row;
        lst#scroll_to_cell (lst_store#get_path row) column
      in
      ignore (addB#connect#clicked ~callback:add);
      ignore (editEntry#connect#activate ~callback:add);
      let remove () =
        match React.state selection with
          [rf] -> let i = rf#iter in
                  if lst_store#iter_next i then
                    lst#selection#select_iter i
                  else begin
                    let p = rf#path in
                    if GTree.Path.prev p then
                      lst#selection#select_path p
                  end;
                  ignore (lst_store#remove rf#iter)
        | _    -> ()
      in
      ignore (removeB#connect#clicked ~callback:remove);
      let edit () =
        match React.state selection with
          [rf] -> let row = rf#iter in
                  let txt = editEntry#text in
                  lst_store#set ~row ~column:c_value txt;
                  lst_store#set ~row ~column:c_ml txt
        | _    -> ()
      in
      ignore (editB#connect#clicked ~callback:edit);
      let updateUpDown l =
        let (upS, downS) =
          match l with
              [rf] -> (GTree.Path.prev rf#path, lst_store#iter_next rf#iter)
          | _      -> (false, false)
        in
        upB#misc#set_sensitive upS;
        downB#misc#set_sensitive downS
      in
      selectionChange >>| updateUpDown;
      ignore (lst_store#connect#after#row_deleted
                ~callback:(fun _ -> updateUpDown (React.state selection)));
      let go_up () =
        match React.state selection with
          [rf] -> let p = rf#path in
                  if GTree.Path.prev p then begin
                    let i = rf#iter in
                    let i' = lst_store#get_iter p in
                    ignore (lst_store#swap i i');
                    lst#scroll_to_cell (lst_store#get_path i) column
                  end;
                  updateUpDown (React.state selection)
        | _    -> ()
      in
      ignore (upB#connect#clicked ~callback:go_up);
      let go_down () =
        match React.state selection with
          [rf] -> let i = rf#iter in
                  if lst_store#iter_next i then begin
                    let i' = rf#iter in
                    ignore (lst_store#swap i i');
                    lst#scroll_to_cell (lst_store#get_path i') column
                  end;
                  updateUpDown (React.state selection)
        | _    -> ()
      in
      ignore (downB#connect#clicked ~callback:go_down);
      List.iter
        (fun v ->
           let row = lst_store#append () in
           lst_store#set ~row ~column:c_value (Unicode.protect v);
           lst_store#set ~row ~column:c_ml v)
        vl;
     (fun () ->
        let l = ref [] in
        lst_store#foreach
          (fun _ row -> l := lst_store#get ~row ~column:c_ml :: !l; false);
        List.rev !l)
    end else begin
      let v = List.hd vl in
      begin match ty with
        `BOOL | `BOOLDEF ->
          let hb =
            GPack.button_box `HORIZONTAL ~layout:`START
              ~packing:(tbl#attach ~left:1 ~top:3 ~expand:`X) ()
          in
          let isTrue = v = "true" || v = "yes" in
          let trueB =
            GButton.radio_button ~label:"_True" ~use_mnemonic:true
              ~active:isTrue ~packing:(hb#add) ()
          in
          ignore
            (GButton.radio_button ~label:"_False" ~use_mnemonic:true
               ~group:trueB#group ~active:(not isTrue) ~packing:(hb#add) ());
           ignore
             (GMisc.label ~text:"Value:" ~xalign:0.
                ~packing:(tbl#attach ~left:0 ~top:3 ~expand:`NONE) ());
          (fun () -> [if trueB#active then "true" else "false"])
      | `INT | `STRING ->
           let valueEntry =
             GEdit.entry ~text:v ~width_chars: 40
               ~activates_default:true
               ~packing:(tbl#attach ~left:1 ~top:3 ~expand:`X) ()
           in
           ignore
             (GMisc.label ~text:"V_alue:" ~use_underline:true ~xalign:0.
                ~mnemonic_widget:valueEntry
                ~packing:(tbl#attach ~left:0 ~top:3 ~expand:`NONE) ());
           (fun () -> [valueEntry#text])
      | `STRING_LIST | `CUSTOM | `UNKNOWN ->
           assert false
      end
    end
  in

  let res = ref None in
  let cancelCommand () = t#destroy () in
  let cancelButton =
    GButton.button ~stock:`CANCEL ~packing:t#action_area#add () in
  ignore (cancelButton#connect#clicked ~callback:cancelCommand);
  let okCommand _ = res := Some (newValue ()); t#destroy () in
  let okButton =
    GButton.button ~stock:`OK ~packing:t#action_area#add () in
  ignore (okButton#connect#clicked ~callback:okCommand);
  okButton#grab_default ();
  ignore (t#connect#destroy ~callback:GMain.Main.quit);
  t#show ();
  GMain.Main.main ();
  !res


let markupRe = Str.regexp "<\\([a-z]+\\)>\\|</\\([a-z]+\\)>\\|&\\([a-z]+\\);"
let entities =
  [("amp", "&"); ("lt", "<"); ("gt", ">"); ("quot", "\""); ("apos", "'")]

let rec insertMarkupRec tags (t : #GText.view) s i tl =
  try
    let j = Str.search_forward markupRe s i in
    if j > i then
      t#buffer#insert ~tags:(List.flatten tl) (String.sub s i (j - i));
    let tag = try Some (Str.matched_group 1 s) with Not_found -> None in
    match tag with
      Some tag ->
        insertMarkupRec tags t s (Str.group_end 0)
          ((try [List.assoc tag tags] with Not_found -> []) :: tl)
    | None ->
        let entity = try Some (Str.matched_group 3 s) with Not_found -> None in
        match entity with
          None ->
            insertMarkupRec tags t s (Str.group_end 0) (List.tl tl)
        | Some ent ->
            begin try
              t#buffer#insert ~tags:(List.flatten tl) (List.assoc ent entities)
            with Not_found -> () end;
            insertMarkupRec tags t s (Str.group_end 0) tl
  with Not_found ->
    let j = String.length s in
    if j > i then
      t#buffer#insert ~tags:(List.flatten tl) (String.sub s i (j - i))

let insertMarkup tags t s =
  t#buffer#set_text ""; insertMarkupRec tags t s 0 []

let documentPreference ~compact ~packing =
  let vb = GPack.vbox ~spacing:6 ~packing () in
  ignore (GMisc.label ~markup:"<b>Documentation</b>" ~xalign:0.
            ~packing:(vb#pack ~expand:false) ());
  let al = GBin.alignment ~packing:(vb#pack ~expand:true ~fill:true) () in
  al#set_left_padding 12;
  let columns = if compact then 3 else 2 in
  let tbl =
    GPack.table ~rows:2 ~columns ~col_spacings:12 ~row_spacings:6
      ~packing:(al#add) () in
  tbl#misc#set_sensitive false;
  ignore (GMisc.label ~text:"Short description:" ~xalign:0.
            ~packing:(tbl#attach ~left:0 ~top:0 ~expand:`NONE) ());
  ignore (GMisc.label ~text:"Long description:" ~xalign:0. ~yalign:0.
            ~packing:(tbl#attach ~left:0 ~top:1 ~expand:`NONE) ());
  let shortDescr =
    GMisc.label ~packing:(tbl#attach ~left:1 ~top:0 ~expand:`X)
      ~xalign:0. ~selectable:true () in
  let longDescr =
    let sw =
      if compact then
        GBin.scrolled_window ~height:128 ~width:640
          ~packing:(tbl#attach ~left:0 ~top:2 ~right:2 ~expand:`BOTH)
          ~shadow_type:`IN ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ()
      else
        GBin.scrolled_window ~height:128 ~width:640
          ~packing:(tbl#attach ~left:1 ~top:1 ~expand:`BOTH)
          ~shadow_type:`IN ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ()
    in
    GText.view ~editable:false ~packing:sw#add ~wrap_mode:`WORD ()
  in
  let () = longDescr#set_left_margin 4
  and () = longDescr#set_right_margin 4
  and () = longDescr#set_top_margin 1
  and () = longDescr#set_bottom_margin 2 in
  let (>>>) x f = f x in
  let newlineRe = Str.regexp "\n *" in
  let styleRe = Str.regexp "{\\\\\\([a-z]+\\) \\([^{}]*\\)}" in
  let verbRe = Str.regexp "\\\\verb|\\([^|]*\\)|" in
  let argRe = Str.regexp "\\\\ARG{\\([^{}]*\\)}" in
  let textttRe = Str.regexp "\\\\texttt{\\([^{}]*\\)}" in
  let emphRe = Str.regexp "\\\\emph{\\([^{}]*\\)}" in
  let sectionRe = Str.regexp "\\\\sectionref{\\([^{}]*\\)}{\\([^{}]*\\)}" in
  let emdash = Str.regexp_string "---" in
  let parRe = Str.regexp "\\\\par *" in
  let underRe = Str.regexp "\\\\_ *" in
  let dollarRe = Str.regexp "\\\\\\$ *" in
  let formatDoc doc =
    doc >>>
    Str.global_replace newlineRe " " >>>
    escapeMarkup >>>
    Str.global_substitute styleRe
      (fun s ->
         try
           let tag =
             match Str.matched_group 1 s with
               "em" -> "i"
             | "tt" -> "tt"
             | _ -> raise Exit
           in
           Format.sprintf "<%s>%s</%s>" tag (Str.matched_group 2 s) tag
         with Exit ->
           Str.matched_group 0 s) >>>
    Str.global_replace verbRe "<tt>\\1</tt>" >>>
    Str.global_replace argRe "<tt>\\1</tt>" >>>
    Str.global_replace textttRe "<tt>\\1</tt>" >>>
    Str.global_replace emphRe "<i>\\1</i>" >>>
    Str.global_replace sectionRe "Section '\\2'" >>>
    Str.global_replace emdash "\xe2\x80\x94" >>>
    Str.global_replace parRe "\n" >>>
    Str.global_replace underRe "_" >>>
    Str.global_replace dollarRe "_"
  in
  let tags =
    let create = longDescr#buffer#create_tag in
    [("i", create [`FONT_DESC (Lazy.force fontItalic)]);
     ("tt", create [`FONT_DESC (Lazy.force fontMonospace)])]
  in
  fun nm ->
    let (short, long) =
      match nm with
        Some nm ->
          tbl#misc#set_sensitive true;
          Prefs.documentation nm
      | _ ->
          tbl#misc#set_sensitive false;
          ("", "")
    in
    shortDescr#set_text (String.capitalize_ascii short);
    insertMarkup tags longDescr (formatDoc long)
(*    longDescr#buffer#set_text (formatDoc long)*)

let addPreference parent =
  let t =
    GWindow.dialog ~parent ~border_width:12
      ~title:"Add a Preference"
      ~modal:true () in
  t#set_default_height 575;
  let vb = t#vbox in
(*  vb#set_spacing 18;*)
  let paned = GPack.paned `VERTICAL ~packing:vb#add () in

  let lvb = GPack.vbox ~spacing:6 ~packing:(paned#pack1 ~resize:true) () in
  let preferenceLabel =
    GMisc.label
      ~text:"_Preferences:" ~use_underline:true
      ~xalign:0. ~packing:(lvb#pack ~expand:false) ()
  in
  let cols = new GTree.column_list in
  let c_name = cols#add Gobject.Data.string in
  let c_font = cols#add Gobject.Data.string in
  let store = GTree.tree_store cols in
  let lst =
    let sw =
      GBin.scrolled_window ~packing:(lvb#pack ~expand:true)
        ~shadow_type:`IN ~height:200 ~width:400
        ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC () in
    GTree.view ~headers_visible:false ~packing:sw#add () in
  preferenceLabel#set_mnemonic_widget (Some (lst :> GObj.widget));

  let cell_r = GTree.cell_renderer_text [] in
  let view_col = (GTree.view_column ~renderer:(cell_r, ["text", c_name]) ()) in
  view_col#add_attribute cell_r "font" c_font;
  ignore (lst#append_column view_col);
  (*let hiddenPrefs =
    ["auto"; "silent"; "terse"] in*)
  let shownPrefs =
    ["label"; "key"] in

  let createGroup n =
    let row = store#append () in
    store#set ~row ~column:c_name n;
    store#set ~row ~column:c_font "bold";
    row
  in
  let createTopic parent n =
    let row = store#append ~parent () in
    store#set ~row ~column:c_name n;
    store#set ~row ~column:c_font "italic";
    row
  in
  let createTopics parent g =
    Safelist.map (fun t ->
      let topic = g t in
      (topic, (createTopic parent (Prefs.topic_title topic))))
  in

  let topicsInOrder = [ `Sync; `Syncprocess; `Syncprocess_CLI; `CLI; `GUI; `Remote; `Archive ] in

  let basic = createGroup "1 — Basic preferences" in
  let l = createTopics basic (fun t -> `Basic t) (`General :: topicsInOrder) in

  let adv = createGroup "2 — Advanced preferences" in
  let l = l @ createTopics adv (fun t -> `Advanced t) (topicsInOrder @ [`General]) in

  let l = (`Expert, createGroup "3 — Expert preferences") :: l in

  let parents = l in
  let purgeParents () =
    Safelist.iter (fun (_, row) ->
        if not (store#iter_has_child row) then begin
          let parent = store#iter_parent row in
          ignore (store#remove row);
          match parent with
          | None -> ()
          | Some parent -> if not (store#iter_has_child parent) then
                             ignore (store#remove parent)
        end
      ) parents
  in
  let categoryParent nm =
    match Prefs.category nm with
    | None -> None
    | Some _ when List.mem nm shownPrefs -> Some basic
    | Some cat -> begin
        try Some (Safelist.assoc cat parents) with
        | Not_found -> None
      end
  in
  let isParent r = store#iter_has_child r in

  let () =
    List.iter
      (fun nm ->
         let row =
           match categoryParent nm with
           | None -> store#append ()
           | Some parent -> store#append ~parent ()
         in
         store#set ~row ~column:c_name nm
      )
      (Prefs.list false);
  in
  purgeParents ();

  lst#set_model (Some store#coerce);

  let getSelectedPref rf =
    let row = rf#iter in
    if isParent row then
      None
    else
      Some (store#get ~row ~column:c_name)
  in
  let selection = GtkReact.tree_view_selection lst in
  let updateDoc = documentPreference ~compact:true ~packing:paned#pack2 in
  let prefSelection = selection >> (function
    | [rf] -> getSelectedPref rf
    | _ -> None)
  in
  prefSelection >| updateDoc;

  let cancelCommand () = t#destroy () in
  let cancelButton =
    GButton.button ~stock:`CANCEL ~packing:t#action_area#add () in
  ignore (cancelButton#connect#clicked ~callback:cancelCommand);
  ignore (t#event#connect#delete ~callback:(fun _ -> cancelCommand (); true));
  let ok = ref false in
  let addCommand _ = ok := true; t#destroy () in
  let addButton =
    GButton.button ~stock:`ADD ~packing:t#action_area#add () in
  ignore (addButton#connect#clicked ~callback:addCommand);
  GtkReact.set_sensitive addButton (prefSelection >> fun nm -> nm <> None);
  ignore (lst#connect#row_activated ~callback:(fun _ _ -> addCommand ()));
  addButton#grab_default ();

  ignore (t#connect#destroy ~callback:GMain.Main.quit);
  t#show ();
  GMain.Main.main ();
  if not !ok then None else
    match React.state selection with
    | [rf] ->
        getSelectedPref rf
    | _ ->
        None

let editProfile parent name =
  let t =
    GWindow.dialog ~parent ~border_width:12
      ~title:(Format.sprintf "%s - Profile Editor" name)
      ~modal:true () in
  let vb = t#vbox in
(*  t#vbox#set_spacing 18;*)
  let paned = GPack.paned `VERTICAL ~packing:vb#add () in

  let lvb = GPack.vbox ~spacing:6 ~packing:paned#pack1 () in
  let preferenceLabel =
    GMisc.label
      ~text:"_Preferences:" ~use_underline:true
      ~xalign:0. ~packing:(lvb#pack ~expand:false) ()
  in
  let hb = GPack.hbox ~spacing:12 ~packing:(lvb#add) () in
  let cols = new GTree.column_list in
  let c_name = cols#add Gobject.Data.string in
  let c_type = cols#add Gobject.Data.string in
  let c_value = cols#add Gobject.Data.string in
  let c_ml = cols#add Gobject.Data.caml in
  let lst_store = GTree.list_store cols in
  let lst_sorted_store = GTree.model_sort lst_store in
  lst_sorted_store#set_sort_column_id 0 `ASCENDING;
  let lst =
    let sw =
      GBin.scrolled_window ~packing:(hb#pack ~expand:true)
        ~shadow_type:`IN ~height:300 ~width:600
        ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC () in
    GTree.view ~model:lst_sorted_store ~packing:sw#add
      ~headers_clickable:true () in
  preferenceLabel#set_mnemonic_widget (Some (lst :> GObj.widget));
  let vc_name =
    GTree.view_column
      ~title:"Name"
      ~renderer:(GTree.cell_renderer_text [], ["text", c_name]) () in
  vc_name#set_sort_column_id 0;
  ignore (lst#append_column vc_name);
  ignore (lst#append_column
    (GTree.view_column
       ~title:"Type"
       ~renderer:(GTree.cell_renderer_text [], ["text", c_type]) ()));
  ignore (lst#append_column
    (GTree.view_column
       ~title:"Value"
       ~renderer:(GTree.cell_renderer_text [], ["text", c_value]) ()));
  let vb =
    GPack.button_box
      `VERTICAL ~layout:`START ~spacing:6 ~packing:(hb#pack ~expand:false) ()
  in
  let selection = GtkReact.tree_view_selection lst in
  let hasSel = selection >> fun l -> l <> [] in
  let addB =
    GButton.button ~stock:`ADD ~packing:(vb#pack ~expand:false) () in
  let editB =
    GButton.button ~stock:`EDIT ~packing:(vb#pack ~expand:false) () in
  let deleteB =
    GButton.button ~stock:`DELETE ~packing:(vb#pack ~expand:false) () in
  List.iter (fun b -> b#set_xalign 0.) [addB; editB; deleteB];
  GtkReact.set_sensitive editB hasSel;
  GtkReact.set_sensitive deleteB hasSel;

  let (modified, setModified) = React.make false in
  let formatValue vl = Unicode.protect (String.concat ", " vl) in
  let deletePref () =
    match React.state selection with
      [rf] ->
        let row = lst_sorted_store#convert_iter_to_child_iter rf#iter in
        let (nm, ty, vl) = lst_store#get ~row ~column:c_ml in
        if
          twoBox ~kind:`DIALOG_QUESTION ~parent:t ~title:"Preference Deletion"
            ~bstock:`CANCEL ~astock:`DELETE
            (Format.sprintf "Do you really want to delete preference %s?"
               (Unicode.protect nm))
        then begin
          ignore (lst_store#remove row);
          setModified true
        end
    | _ ->
        ()
  in
  let editPref path =
    let row =
      lst_sorted_store#convert_iter_to_child_iter
        (lst_sorted_store#get_iter path) in
    let (nm, ty, vl) = lst_store#get ~row ~column:c_ml in
    match editPreference t nm ty vl with
      Some [] ->
        deletePref ()
    | Some vl' when vl <> vl' ->
        lst_store#set ~row ~column:c_ml (nm, ty, vl');
        lst_store#set ~row ~column:c_value (formatValue vl');
        setModified true
    | _ ->
        ()
  in
  let add () =
    match addPreference t with
      None ->
        ()
    | Some nm ->
        let existing = ref false in
        lst_store#foreach
          (fun path row ->
             let (nm', _, _) = lst_store#get ~row ~column:c_ml in
             if nm = nm' then begin
               existing := true; editPref path; true
             end else
               false);
        if not !existing then begin
          let ty = Prefs.typ nm in
          match editPreference parent nm ty (defaultValue ty) with
            Some vl when vl <> [] ->
              let row = lst_store#append () in
              lst_store#set ~row ~column:c_name (Unicode.protect nm);
              lst_store#set ~row ~column:c_type (nameOfType ty);
              lst_store#set ~row ~column:c_ml (nm, ty, vl);
              lst_store#set ~row ~column:c_value (formatValue vl);
              setModified true
          | _ ->
              ()
        end
  in
  ignore (addB#connect#clicked ~callback:add);
  ignore (editB#connect#clicked
            ~callback:(fun () ->
                         match React.state selection with
                           [p] -> editPref p#path
                         | _   -> ()));
  ignore (deleteB#connect#clicked ~callback:deletePref);

  let updateDoc = documentPreference ~compact:true ~packing:paned#pack2 in
  selection >|
    (fun l ->
       let nm =
         match l with
           [rf] ->
             let row = rf#iter in
             Some (lst_sorted_store#get ~row ~column:c_name)
         | _ ->
             None
       in
       updateDoc nm);
  ignore (lst#connect#row_activated ~callback:(fun path _ -> editPref path));

  let group l =
    let rec groupRec l k vl l' =
      match l with
        (k', v) :: r ->
          if k = k' then
            groupRec r k (v :: vl) l'
          else
            groupRec r k' [v] ((k, vl) :: l')
      | [] ->
          Safelist.fold_left
            (fun acc (k, l) -> (k, List.rev l) :: acc) [] ((k, vl) :: l')
    in
    match l with
      (k, v) :: r -> groupRec r k [v] []
    | []          -> []
  in
  let lastOne l = [List.hd (Safelist.rev l)] in
  let normalizeValue t vl =
    match t with
      `BOOL | `INT | `STRING            -> lastOne vl
    | `STRING_LIST | `CUSTOM | `UNKNOWN -> vl
    | `BOOLDEF ->
         let l = lastOne vl in
         if l = ["default"] || l = ["auto"] then [] else l
  in
  let (>>>) x f = f x in
  Prefs.readAFile name
  >>> List.map (fun (_, nm, v) -> Prefs.canonicalName nm, v)
  >>> List.stable_sort (fun (nm, _) (nm', _) -> compare nm nm')
  >>> group
  >>> List.iter
        (fun (nm, vl) ->
           let nm = Prefs.canonicalName nm in
           let ty = Prefs.typ nm in
           let vl = normalizeValue ty vl in
           if vl <> [] then begin
             let row = lst_store#append () in
             lst_store#set ~row ~column:c_name (Unicode.protect nm);
             lst_store#set ~row ~column:c_type (nameOfType ty);
             lst_store#set ~row ~column:c_value (formatValue vl);
             lst_store#set ~row ~column:c_ml (nm, ty, vl)
           end);

  let applyCommand _ =
    if React.state modified then begin
      let filename = Prefs.profilePathname name in
      try
        let ch =
          System.open_out_gen [Open_wronly; Open_creat; Open_trunc] 0o600
            filename
        in
        let close_on_error f =
          try f () with e -> close_out_noerr ch; raise e
        in
        close_on_error (fun () ->
  (*XXX Should trim whitespaces and check for '\n' at some point  *)
        Printf.fprintf ch "# Unison preferences\n";
        lst_store#foreach
          (fun path row ->
             let (nm, _, vl) = lst_store#get ~row ~column:c_ml in
             List.iter (fun v -> Printf.fprintf ch "%s = %s\n" nm v) vl;
             false);
        close_out ch);
        setModified false
      with Sys_error _ as e ->
        okBox ~parent:t ~typ:`ERROR ~title:"Could not save profile"
          ~message:(Uicommon.exn2string e)
    end
  in
  let applyButton =
    GButton.button ~stock:`APPLY ~packing:t#action_area#add () in
  ignore (applyButton#connect#clicked ~callback:applyCommand);
  GtkReact.set_sensitive applyButton modified;
  let cancelCommand () = t#destroy () in
  let cancelButton =
    GButton.button ~stock:`CANCEL ~packing:t#action_area#add () in
  ignore (cancelButton#connect#clicked ~callback:cancelCommand);
  ignore (t#event#connect#delete ~callback:(fun _ -> cancelCommand (); true));
  let okCommand _ = applyCommand (); t#destroy () in
  let okButton =
    GButton.button ~stock:`OK ~packing:t#action_area#add () in
  ignore (okButton#connect#clicked ~callback:okCommand);
  okButton#grab_default ();
(*
List.iter
  (fun (nm, _, long) ->
     try
       let long = formatDoc long in
       ignore (Str.search_forward (Str.regexp_string "\\") long 0);
       Format.eprintf "%s %s@." nm long
     with Not_found -> ())
(Prefs.listVisiblePrefs ());
*)

(*
TODO:
  - Extra tabs for common preferences
    (should keep track of any change, or blacklist some preferences)
  - Add, modify, delete
  - Keep track of whether there is any change (apply button)
*)
  ignore (t#connect#destroy ~callback:GMain.Main.quit);
  t#show ();
  GMain.Main.main ()

(* ------ *)

let documentationFn = ref (fun ~parent _ -> ())

let getProfile quit =
  let ok = ref false in
  let parent = toplevelWindow () in
  (* Make sure that a potentially open password window from a (failed) previous
     session is not hidden underneath this window. *)
  waitForPasswordWindowClosing ();

  (* Build the dialog *)
  let t =
    GWindow.dialog ~parent ~border_width:12
      ~title:"Profile Selection"
      ~modal:false () in
  t#set_default_width 550;
  (* Simulate modal dialog (allowing to open other windows, such as help) *)
  parent#set_sensitive false;
  ignore (t#connect#destroy ~callback:(fun () -> parent#set_sensitive true));

  let cancelCommand _ = t#destroy () in
  let cancelButton =
    GButton.button ~stock:(if quit then `QUIT else `CANCEL)
      ~packing:t#action_area#add () in
  ignore (cancelButton#connect#clicked ~callback:cancelCommand);
  ignore (t#event#connect#delete ~callback:(fun _ -> cancelCommand (); true));
  cancelButton#misc#set_can_default true;

  let okCommand() = ok := true; t#destroy () in
  let okButton =
    GButton.button ~stock:`OPEN ~packing:t#action_area#add () in
  ignore (okButton#connect#clicked ~callback:okCommand);
  okButton#misc#set_sensitive false;
  okButton#grab_default ();

  let vb = t#vbox in
  t#vbox#set_spacing 18;

  let al = GBin.alignment ~packing:(vb#add) () in
  al#set_left_padding 12;

  let lvb = GPack.vbox ~spacing:6 ~packing:(al#add) () in
  let selectLabel =
    GMisc.label
      ~text:"Select a _profile:" ~use_underline:true
      ~xalign:0. ~packing:(lvb#pack ~expand:false) ()
  in
  let hb = GPack.hbox ~spacing:12 ~packing:(lvb#add) () in
  let sw =
    GBin.scrolled_window ~packing:(hb#pack ~expand:true) ~height:300
      ~shadow_type:`IN ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC () in
  let cols = new GTree.column_list in
  let c_name = cols#add Gobject.Data.string in
  let c_label = cols#add Gobject.Data.string in
  let c_ml = cols#add Gobject.Data.caml in
  let lst_store = GTree.list_store cols in
  let lst = GTree.view ~model:lst_store ~packing:sw#add () in
  selectLabel#set_mnemonic_widget (Some (lst :> GObj.widget));
  let vc_name =
    GTree.view_column
       ~title:"Profile"
       ~renderer:(GTree.cell_renderer_text [], ["text", c_name]) ()
  in
  ignore (lst#append_column vc_name);
  ignore (lst#append_column
    (GTree.view_column
       ~title:"Description"
       ~renderer:(GTree.cell_renderer_text [], ["text", c_label]) ()));

  let vb = GPack.vbox ~spacing:6 ~packing:(vb#pack ~expand:false) () in
  ignore (GMisc.label ~markup:"<b>Summary</b>" ~xalign:0.
            ~packing:(vb#pack ~expand:false) ());
  let al = GBin.alignment ~packing:(vb#pack ~expand:false) () in
  al#set_left_padding 12;
  let tbl =
    GPack.table ~rows:2 ~columns:2 ~col_spacings:12 ~row_spacings:6
      ~packing:(al#add) () in
  tbl#misc#set_sensitive false;
  ignore (GMisc.label ~text:"First root:" ~xalign:0.
            ~packing:(tbl#attach ~left:0 ~top:0 ~expand:`NONE) ());
  ignore (GMisc.label ~text:"Second root:" ~xalign:0.
            ~packing:(tbl#attach ~left:0 ~top:1 ~expand:`NONE) ());
  let root1 =
    GMisc.label ~packing:(tbl#attach ~left:1 ~top:0 ~expand:`X)
      ~xalign:0. ~selectable:true ~ellipsize:`MIDDLE () in
  let root2 =
    GMisc.label ~packing:(tbl#attach ~left:1 ~top:1 ~expand:`X)
      ~xalign:0. ~selectable:true ~ellipsize:`MIDDLE () in

  let fillLst default =
    Uicommon.scanProfiles();
    lst_store#clear ();
    Safelist.iter
      (fun (profile, info) ->
         let labeltext =
           match info.Uicommon.label with None -> "" | Some l -> l in
         let row = lst_store#append () in
         lst_store#set ~row ~column:c_name (Unicode.protect profile);
         lst_store#set ~row ~column:c_label (Unicode.protect labeltext);
         lst_store#set ~row ~column:c_ml (profile, info);
         if Some profile = default then begin
           lst#selection#select_iter row;
           lst#scroll_to_cell (lst_store#get_path row) vc_name
         end)
      (Safelist.sort (fun (p, _) (p', _) -> compare p p') !Uicommon.profilesAndRoots)
  in
  let selection = GtkReact.tree_view_selection lst in
  let hasSel = selection >> fun l -> l <> [] in
  let selInfo =
    selection >> fun l ->
      match l with
        [rf] -> Some (lst_store#get ~row:rf#iter ~column:c_ml, rf)
      | _    -> None
  in
  selInfo >|
    (fun info ->
       match info with
         Some ((profile, info), _) ->
           begin match info.Uicommon.roots with
             [r1; r2] -> root1#set_text (Unicode.protect r1);
                         root2#set_text (Unicode.protect r2);
                         tbl#misc#set_sensitive true
           | _        -> root1#set_text ""; root2#set_text "";
                         tbl#misc#set_sensitive false
           end
       | None ->
           root1#set_text ""; root2#set_text "";
           tbl#misc#set_sensitive false);
  GtkReact.set_sensitive okButton hasSel;

  let box = GPack.vbox ~packing:(hb#pack ~expand:false) () in
  let vb =
    GPack.button_box
      `VERTICAL ~layout:`START ~spacing:6 ~packing:(box#pack ~expand:false) ()
  in
  let addButton =
    GButton.button ~stock:`ADD ~packing:(vb#pack ~expand:false) () in
  ignore (addButton#connect#clicked
     ~callback:(fun () ->
                  match createProfile t with
                    Some p -> fillLst (Some p) | None -> ()));
  let editButton =
    GButton.button ~stock:`EDIT ~packing:(vb#pack ~expand:false) () in
  ignore (editButton#connect#clicked
            ~callback:(fun () -> match React.state selInfo with
                                   None ->
                                     ()
                                 | Some ((p, _), _) ->
                                     editProfile t p; fillLst (Some p)));
  GtkReact.set_sensitive editButton hasSel;
  let deleteProfile () =
    match React.state selInfo with
      Some ((profile, _), rf) ->
       if
         twoBox ~kind:`DIALOG_QUESTION ~parent:t ~title:"Profile Deletion"
           ~bstock:`CANCEL ~astock:`DELETE
           (Format.sprintf "Do you really want to delete profile %s?"
              (transcode profile))
       then begin
         try
           System.unlink (Prefs.profilePathname profile);
           ignore (lst_store#remove rf#iter)
         with Unix.Unix_error _ -> ()
       end
    | None ->
       ()
  in
  let deleteButton =
    GButton.button ~stock:`DELETE ~packing:(vb#pack ~expand:false) () in
  ignore (deleteButton#connect#clicked ~callback:deleteProfile);
  GtkReact.set_sensitive deleteButton hasSel;
  List.iter (fun b -> b#set_xalign 0.) [addButton; editButton; deleteButton];

  ignore (GPack.vbox ~packing:(box#pack ~expand:true) ());
  let helpButton =
    GButton.button ~stock:`HELP ~packing:(box#pack ~expand:false) () in
  helpButton#set_xalign 0.;
  ignore (helpButton#connect#clicked
     ~callback:(fun () -> !documentationFn ~parent:t ""));

  ignore (lst#connect#row_activated ~callback:(fun _ _ -> okCommand ()));
  fillLst None;
  lst#misc#grab_focus ();
  ignore (t#connect#destroy ~callback:GMain.Main.quit);
  t#show ();
  GMain.Main.main ();
  match React.state selInfo with
    Some ((p, _), _) when !ok -> Some p
  | _                         -> None

(* ------ *)

let get_size_chars obj ?desc ?lang ~height ~width () =
  let metrics = obj#misc#pango_context#get_metrics ?desc ?lang () in
  (width * GPango.to_pixels metrics#approx_digit_width,
   height * GPango.to_pixels (metrics#ascent+metrics#descent))

let documentation ~parent sect =
  let title = "Documentation" in
  let t = GWindow.dialog ~title ~parent () in
  let t_dismiss =
    GButton.button ~stock:`CLOSE ~packing:t#action_area#add () in
  t_dismiss#grab_default ();
  let dismiss () = t#destroy () in
  ignore (t_dismiss#connect#clicked ~callback:dismiss);
  ignore (t#event#connect#delete ~callback:(fun _ -> dismiss (); true));

  let nb = GPack.notebook ~show_tabs:true ~tab_pos:`LEFT ~border_width:5
    ~packing:(t#vbox#pack ~expand:true) () in

  let sect_idx = ref 0 in
  let add_nb_page label active w =
    let i = nb#append_page ~tab_label:label#coerce w in
    if active then sect_idx := i
  in

  let lw = ref 1 in
  let addDocSection (shortname, (name, docstr)) =
    if shortname = "" || name = "" then () else
    let () = lw := max !lw (String.length name) in
    let label = GMisc.label ~markup:("<b>" ^ name ^ "</b>")
                  ~xalign:1. ~justify:`LEFT ~ellipsize:`NONE () in
    let box = GBin.frame ~border_width:8
                ~packing:(add_nb_page label (shortname = sect)) () in
    let text = new scrolled_text ~editable:false ~wrap_mode:`NONE
                 ~packing:box#add () in
    text#insert docstr
  in
  Safelist.iter addDocSection Strings.docs;

  nb#goto_page !sect_idx;

  let (width, height) = get_size_chars t ~width:(80 + !lw) ~height:25 () in
  t#set_default_size ~width ~height;

  t#show ()
let () = documentationFn := documentation

(* ------ *)

let messageBox ~title ?(action = fun t -> t#destroy) message =
  let utitle = transcode title in
  let t = GWindow.dialog ~title:utitle ~parent:(toplevelWindow ())
            ~position:`CENTER () in
  let t_dismiss = GButton.button ~stock:`CLOSE ~packing:t#action_area#add () in
  t_dismiss#grab_default ();
  ignore (t_dismiss#connect#clicked ~callback:(action t));
  let t_text =
    new scrolled_text ~editable:false ~wrap_mode:`NONE
      ~packing:(t#vbox#pack ~expand:true) ()
  in
  t_text#insert message;
  let (width, height) = get_size_chars t_text ~width:82 ~height:20 () in
  t#set_default_size ~width ~height;
  ignore (t#event#connect#delete ~callback:(fun _ -> action t (); true));
  t#show ()

(* twoBoxAdvanced: Display a message in a window and wait for the user
   to hit one of two buttons.  Return true if the first button is
   chosen, false if the second button is chosen. Also has a button for
   showing more details to the user in a messageBox dialog *)
let twoBoxAdvanced
      ~parent ~title ~message ~longtext ~advLabel ~astock ~bstock =
  let t =
    GWindow.dialog ~parent ~border_width:6 ~modal:true
      ~resizable:false () in
  t#vbox#set_spacing 12;
  let h1 = GPack.hbox ~border_width:6 ~spacing:12 ~packing:t#vbox#pack () in
  ignore (GMisc.image ~stock:`DIALOG_QUESTION ~icon_size:`DIALOG
            ~yalign:0. ~packing:h1#pack ());
  let v1 = GPack.vbox ~spacing:12 ~packing:h1#pack () in
  ignore (GMisc.label
            ~markup:(primaryText title ^ "\n\n" ^ escapeMarkup message)
            ~selectable:true ~yalign:0. ~packing:v1#add ());
  t#add_button_stock `CANCEL `NO;
  let cmd () =
    messageBox ~title:"Details" longtext
  in
  t#add_button advLabel `HELP;
  t#add_button_stock `APPLY `YES;
  t#set_default_response `NO;
  let res = ref false in
  let setRes signal =
    match signal with
      `YES -> res := true; t#destroy ()
    | `NO -> res := false; t#destroy ()
    | `HELP -> cmd ()
    | _ -> ()
  in
  ignore (t#connect#response ~callback:setRes);
  ignore (t#connect#destroy ~callback:GMain.Main.quit);
  t#show();
  GMain.Main.main();
  !res

let summaryBox ~parent ~title ~message ~f =
  let t =
    GWindow.dialog ~parent ~border_width:6 ~modal:true
      ~resizable:true ~focus_on_map:true () in
  t#vbox#set_spacing 12;
  let h1 = GPack.hbox ~border_width:6 ~spacing:12 ~packing:t#vbox#pack () in
  ignore (GMisc.image ~stock:`DIALOG_INFO ~icon_size:`DIALOG
            ~yalign:0. ~packing:h1#pack ());
  let v1 = GPack.vbox ~spacing:12 ~packing:h1#pack () in
  ignore (GMisc.label
            ~markup:(primaryText title ^ "\n\n" ^ escapeMarkup message)
            ~selectable:true ~xalign:0. ~yalign:0. ~packing:(v1#pack ~expand:false) ());
  let exp = GBin.expander ~spacing:12 ~label:"Show details"
              ~packing:(v1#pack ~expand:true) () in
  let t_text =
    new scrolled_text ~editable:false ~shadow_type:`IN ~packing:exp#add () in
  t_text#set_expand true;
  let (width, height) = get_size_chars t_text ~width:60 ~height:10 () in
  t_text#set_width_request width;
  t_text#set_height_request height;
  f (t_text#text);
  t#add_button_stock `OK `OK;
  t#set_default_response `OK;
  let setRes signal = t#destroy () in
  ignore (t#connect#response ~callback:setRes);
  ignore (t#connect#destroy ~callback:GMain.Main.quit);
  t#show();
  GMain.Main.main()

(**********************************************************************
                             TOP-LEVEL WINDOW
 **********************************************************************)

let displayWaitMessage () =
  make_busy (toplevelWindow ());
  Trace.status (Uicommon.contactingServerMsg ())

let prepDebug () =
  if Sys.os_type = "Win32" then
    (* As a side-effect, this allocates a console if the process doesn't
       have one already. This call is here only for the side-effect,
       because debugging output is produced on stderr and the GUI will
       crash if there is no stderr. *)
    try ignore (System.terminalStateFunctions ())
    with Unix.Unix_error _ -> ()

(* ------ *)

type status = NoStatus | Done | Failed

let createToplevelWindow () =
  let toplevelWindow =
    GWindow.window ~kind:`TOPLEVEL ~position:`CENTER
      ~title:myNameCapitalized ()
  in
  setToplevelWindow toplevelWindow;
  (* There is already a default icon under Windows, and transparent
     icons are not supported by all version of Windows *)
  if Util.osType <> `Win32 then toplevelWindow#set_icon (Some (Lazy.force icon));
  let toplevelVBox = GPack.vbox ~packing:toplevelWindow#add () in

  (*******************************************************************
   Statistic window
   *******************************************************************)

  let (statWin, startStats, stopStats) = statistics () in

  (*******************************************************************
   Groups of things that are sensitive to interaction at the same time
   *******************************************************************)
  let grAction = ref [] in
  let grDiff = ref [] in
  let grGo = ref [] in
  let grRescan = ref [] in
  let grStop = ref [] in
  let grDetail = ref [] in
  let grAdd gr w = gr := w#misc::!gr in
  let grSet gr st = Safelist.iter (fun x -> x#set_sensitive st) !gr in
  let grDisactivateAll () =
    grSet grAction false;
    grSet grDiff false;
    grSet grGo false;
    grSet grRescan false;
    grSet grStop false;
    grSet grDetail false
  in

  (*********************************************************************
    Create the menu bar
   *********************************************************************)
  let topHBox = GPack.hbox ~packing:(toplevelVBox#pack ~expand:false) () in

  let menuBar =
    GMenu.menu_bar ~border_width:0
      ~packing:(topHBox#pack ~expand:true) () in
  let menus = new gMenuFactory ~accel_modi:[] menuBar in
  let accel_group = menus#accel_group in
  toplevelWindow#add_accel_group accel_group;
  let add_submenu ?(modi=[]) label =
    let (menu, item) = menus#add_submenu label in
    (new gMenuFactory ~accel_group:(menus#accel_group)
       ~accel_path:(menus#accel_path ^ label ^ "/")
       ~accel_modi:modi menu,
     item)
  in
  let replace_submenu ?(modi=[]) label item =
    let menu = menus#replace_submenu item in
    new gMenuFactory ~accel_group:(menus#accel_group)
      ~accel_path:(menus#accel_path ^ label ^ "/")
      ~accel_modi:modi menu
  in

  let profileLabel =
    GMisc.label ~text:"" ~packing:(topHBox#pack ~expand:false ~padding:2) () in

  let displayNewProfileLabel () =
    let p = match !Prefs.profileName with None -> "" | Some p -> p in
    let label = Prefs.read Uicommon.profileLabel in
    let s =
      match p, label with
        "",        _  -> ""
      | _,         "" -> p
      | "default", _  -> label
      | _             -> Format.sprintf "%s (%s)" p label
    in
    let roots = String.concat " ↔ " (Globals.rawRoots ()) in
    let roots = if roots = "" then "" else "   |   " ^ roots in
    toplevelWindow#set_title
      (if s = "" then myNameCapitalized else
       Format.sprintf "%s [%s]%s" myNameCapitalized s roots);
    let s = if s="" then "No profile" else "Profile: " ^ s in
    profileLabel#set_text (transcode s)
  in
  displayNewProfileLabel ();

  (*********************************************************************
    Create the menus
   *********************************************************************)
  let (fileMenu, _) = add_submenu "_Synchronization" in
  let (actionMenu, actionItem) = add_submenu "_Actions" in
  let (ignoreMenu, _) = add_submenu ~modi:[`SHIFT] "_Ignore" in
  let (sortMenu, _) = add_submenu "S_ort" in
  let (helpMenu, _) = add_submenu "_Help" in

  (*********************************************************************
    Action bar
   *********************************************************************)
  let actionBar =
    GButton.toolbar ~style:`BOTH
      (* 2003-0519 (stse): how to set space size in gtk 2.0? *)
      (* Answer from Jacques Garrigue: this can only be done in
         the user's.gtkrc, not programmatically *)
      ~orientation:`HORIZONTAL (* ~space_size:10 *)
      ~packing:(toplevelVBox#pack ~expand:false) () in

  (*********************************************************************
    Create the main window
   *********************************************************************)
  let mainWindowSW =
      GBin.scrolled_window ~packing:(toplevelVBox#pack ~expand:true)
        ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ()
  in
  let cols = new GTree.column_list in
  let c_replica1 = cols#add Gobject.Data.string in
  let c_action   = cols#add Gobject.Data.gobject in
  let c_replica2 = cols#add Gobject.Data.string in
  let c_status   = cols#add Gobject.Data.gobject_option in
  let c_statust  = cols#add Gobject.Data.string in
  let c_path     = cols#add Gobject.Data.string in
  (*let c_rowid    = cols#add Gobject.Data.uint in*)
  (* With current implementation the [list_store] view model and [theState]
     array have one-to-one correspondence, so that list_store's tree path index
     is the same as theState array index.
     This changes when, for example, [tree_store] would be used instead of
     list_store, or a separate view-only sorting is implemented without sorting
     the backing theState array. In that case, the column [c_rowid] must be
     used to store the index of [theState] array in the view model. Tree path
     index must not be used directly as [theState] array index and vice versa. *)
  let mainWindowModel = GTree.list_store cols in
  let mainWindow =
    GTree.view ~model:mainWindowModel ~packing:(mainWindowSW#add)
      ~headers_clickable:false ~enable_search:false () in
  mainWindow#selection#set_mode `MULTIPLE;
  ignore (mainWindow#append_column
    (GTree.view_column
       ~title:(" ")
       ~renderer:(GTree.cell_renderer_text [], ["text", c_replica1]) ()));
  ignore (mainWindow#append_column
    (GTree.view_column ~title:"  Action  "
       ~renderer:(GTree.cell_renderer_pixbuf [], ["pixbuf", c_action]) ()));
  ignore (mainWindow#append_column
    (GTree.view_column
       ~title:(" ")
       ~renderer:(GTree.cell_renderer_text [], ["text", c_replica2]) ()));
  let status_view_col = GTree.view_column ~title:"  Status  "
       ~renderer:(GTree.cell_renderer_pixbuf [], ["pixbuf", c_status]) () in
  let status_t_rend = GTree.cell_renderer_text [] in
  status_view_col#pack ~expand:false ~from:`END status_t_rend;
  status_view_col#add_attribute status_t_rend "text" c_statust;
  ignore (mainWindow#append_column status_view_col);
  ignore (mainWindow#append_column
    (GTree.view_column ~title:"  Path  "
       ~renderer:(GTree.cell_renderer_text [], ["text", c_path]) ()));

  let setMainWindowColumnHeaders s =
    Array.iteri
      (fun i data ->
         (mainWindow#get_column i)#set_title data)
      [| " " ^ Unicode.protect (String.sub s  0 12) ^ " "; "  Action  ";
         " " ^ Unicode.protect (String.sub s 15 12) ^ " "; "  Status  ";
         " Path" |];
  in

  (* See above for comment about tree path index and [theState] array index
     equivalence. *)
  let siOfRow f path =
    let row = mainWindowModel#get_iter path in
    let i = (GTree.Path.get_indices path).(0) in
    (*let i = mainWindowModel#get ~row ~column:c_rowid in*)
    f i !theState.(i) row
  in
  let rowOfSi i = GTree.Path.create [i] in
  let currentNumberRows () = mainWindow#selection#count_selected_rows in
  let currentRow () =
    match currentNumberRows () with
    | 1 -> siOfRow (fun i si row -> Some (i, !theState.(i), row))
             (List.hd mainWindow#selection#get_selected_rows)
    | _ -> None
  in
  let currentSelectedIter f =
    Safelist.iter (fun r -> siOfRow f r)
      mainWindow#selection#get_selected_rows
  in
  let currentSelectedFold f a =
    Safelist.fold_left (fun a r -> siOfRow (fun _ si _ -> f a si) r)
      a mainWindow#selection#get_selected_rows
  in
  let currentSelectedExists pred =
    Safelist.exists (fun r -> siOfRow (fun _ si _ -> pred si) r)
      mainWindow#selection#get_selected_rows
  in

  (*********************************************************************
    Create the details window
   *********************************************************************)

  let showDetCommand () =
    let details =
      match currentRow () with
        None ->
          None
      | Some (_, si, _) ->
          let path = Path.toString si.ri.path1 in
          match si.whatHappened with
            Some (Util.Failed _, Some det) ->
              Some ("Merge execution details for file" ^
                    transcodeFilename path,
                    det)
          | _ ->
              match si.ri.replicas with
                Problem err ->
                  Some ("Errors for file " ^ transcodeFilename path, err)
              | Different diff ->
                  let prefix s l =
                    Safelist.map (fun err -> Format.sprintf "%s%s\n" s err) l
                  in
                  let errors =
                    Safelist.append
                      (prefix "[root 1]: " diff.errors1)
                      (prefix "[root 2]: " diff.errors2)
                  in
                  let errors =
                    match si.whatHappened with
                       Some (Util.Failed err, _) -> err :: errors
                    |  _                         -> errors
                  in
                  Some ("Errors for file " ^ transcodeFilename path,
                        String.concat "\n" errors)
    in
    match details with
      None                  -> ((* Should not happen *))
    | Some (title, details) -> messageBox ~title (transcode details)
  in

  let detailsWindowSW =
    GBin.scrolled_window ~packing:(toplevelVBox#pack ~expand:false)
        ~shadow_type:`IN ~hpolicy:`AUTOMATIC ~vpolicy:`AUTOMATIC ()
  in
  let detailsWindow =
    GText.view ~editable:false ~packing:detailsWindowSW#add ()
  in
  let (width, height) = get_size_chars detailsWindow ~height:4 ~width:112 () in
  let () = detailsWindowSW#set_height_request height in
  (* width is set in [sizeMainWindow] *)

  let detailsWindowPath = detailsWindow#buffer#create_tag [] in
  let detailsWindowInfo =
    detailsWindow#buffer#create_tag [`FONT_DESC (Lazy.force fontMonospace)] in
  let detailsWindowError =
    detailsWindow#buffer#create_tag [`WRAP_MODE `WORD] in
  detailsWindow#misc#set_can_focus false;

  let updateButtons () =
    if not !busy then
      let actionPossible si =
        match si.whatHappened, si.ri.replicas with
          None, Different _ -> true
        | _                 -> false
      in
      match currentRow () with
        None ->
          grSet grAction (currentSelectedExists actionPossible);
          grSet grDiff false;
          grSet grDetail false
      | Some (_, si, _) ->
          let details =
            begin match si.ri.replicas with
              Different diff -> diff.errors1 <> [] || diff.errors2 <> []
            | Problem _      -> true
            end
              ||
            begin match si.whatHappened with
              Some (Util.Failed _, _) -> true
            | _                       -> false
            end
          in
          grSet grDetail details;
          let activateAction = actionPossible si in
          let activateDiff =
            activateAction &&
            match si.ri.replicas with
              Different {rc1 = {typ = `FILE}; rc2 = {typ = `FILE}} ->
                true
            | _ ->
                false
          in
          grSet grAction activateAction;
          grSet grDiff activateDiff
  in

  let makeRowVisible row =
    mainWindow#scroll_to_cell row status_view_col (* just a dummy column *)
  in

(*
  let makeFirstUnfinishedVisible pRiInFocus =
    let im = Array.length !theState in
    let rec find i =
      if i >= im then makeRowVisible im else
      match pRiInFocus (!theState.(i).ri), !theState.(i).whatHappened with
        true, None -> makeRowVisible i
      | _ -> find (i+1) in
    find 0
  in
*)

  let updateDetails () =
    begin match currentRow () with
      None ->
        detailsWindow#buffer#set_text ""
    | Some (_, si, _) ->
        let (formated, details) =
          match si.whatHappened with
          | Some(Util.Failed(s), _) ->
               (false, s)
          | None | Some(Util.Succeeded, _) ->
              match si.ri.replicas with
                Problem _ ->
                  (false, Uicommon.details2string si.ri "  ")
              | Different _ ->
                  (true, Uicommon.details2string si.ri "  ")
        in
        let path = Path.toString si.ri.path1 in
        detailsWindow#buffer#set_text "";
        detailsWindow#buffer#insert ~tags:[detailsWindowPath]
          (transcodeFilename path);
        let len = String.length details in
        let details =
          if details.[len - 1] = '\n' then String.sub details 0 (len - 1)
          else details
        in
        if details <> "" then
          detailsWindow#buffer#insert
             ~tags:[if formated then detailsWindowInfo else detailsWindowError]
             ("\n" ^ transcode details)
    end;
    (* Display text *)
    updateButtons () in

  (*********************************************************************
    Status window
   *********************************************************************)

  let statusHBox = GPack.hbox ~packing:(toplevelVBox#pack ~expand:false) () in

  let progressBar =
    GRange.progress_bar ~packing:(statusHBox#pack ~expand:false) () in

  progressBar#misc#modify_font detailsWindow#misc#pango_context#font_description;
  let (w, _) = get_size_chars progressBar ~width:28 ~height:1 () in
  progressBar#set_width_request w;
  progressBar#set_show_text true;
  progressBar#set_pulse_step 0.02;
  let progressBarPulse = ref false in

  let statusWindow =
    GMisc.statusbar ~packing:(statusHBox#pack ~expand:true) () in
  statusWindow#set_margin 0;
  let statusContext = statusWindow#new_context ~name:"status" in
  ignore (statusContext#push "");

  let displayStatus m =
    statusContext#pop ();
    if !progressBarPulse then progressBar#pulse ();
    ignore (statusContext#push (transcode m));
    (* Force message to be displayed immediately *)
    gtk_sync false
  in

  let formatStatus major minor = (Util.padto 30 (major ^ "  ")) ^ minor in

  (* Tell the Trace module about the status printer *)
  Trace.messageDisplayer := displayStatus;
  Trace.statusFormatter := formatStatus;
  Trace.sendLogMsgsToStderr := false;


  (* Window is created before initPrefs but we don't want the size to
     jump around after window has been shown (which is inevitable when
     height is specified in a profile). Scan the command line to check
     for height preference. *)
  begin try
    let prefName = List.hd (Prefs.name Uicommon.mainWindowHeight) in
    let clHeight = List.hd (Util.StringMap.find prefName (Prefs.scanCmdLine "")) in
    Prefs.set Uicommon.mainWindowHeight (int_of_string clHeight)
  with Not_found | Invalid_argument _ | Util.Fatal _ -> () end;

  let calcWinSize () =
    (* (Poor) approximation of row height. It is impossible to get real
       GTK TreeView row height (and it depends on theme). *)
    let row_height = (List.hd mainWindow#all_children)#misc#allocation.height in
    let height =
      if row_height < 2 then   (* Oops, sizes clearly not allocated yet *)
        let metrics = mainWindowSW#misc#pango_context#get_metrics () in
        let h = GPango.to_pixels (metrics#ascent + metrics#descent) in
        (h + 8) * (8 + (Prefs.read Uicommon.mainWindowHeight)) (* rought default *)
      else
          topHBox#misc#allocation.height
        + actionBar#misc#allocation.height
        + 2 * mainWindow#border_width  (* top and bottom *)
        + row_height  (* column headers *)
        + (row_height - 3) * (Prefs.read Uicommon.mainWindowHeight)
        + detailsWindowSW#misc#allocation.height
        + statusHBox#misc#allocation.height
    in
    let height = min height (Gdk.Screen.height ~screen:toplevelWindow#screen ()) in
    let width =
      let metrics = mainWindowSW#misc#pango_context#get_metrics () in
      let w = GPango.to_pixels metrics#approx_digit_width in
      max (w * 112) 860
    in
    let width = min width (Gdk.Screen.width ~screen:toplevelWindow#screen ()) in
    (height, width)
  in

  let prevHeightPref = ref 0 in

  let sizeMainWindow () =
    (* Only update height if the preference changed, otherwise risk undoing
       user's manual height adjustments. Also assume no change if the
       preference is at the default value. *)
    let prefHeight = Prefs.read Uicommon.mainWindowHeight in
    if !prevHeightPref <> prefHeight &&
        (!prevHeightPref = 0 ||
          prefHeight <> Prefs.readDefault Uicommon.mainWindowHeight) then begin
      let (height, _) = calcWinSize ()
      and width = toplevelWindow#misc#allocation.width in
      toplevelWindow#resize ~height ~width
    end;
    prevHeightPref := prefHeight
  in
  let (height, width) = calcWinSize () in
  toplevelWindow#set_default_size ~height ~width;
  ignore (toplevelWindow#misc#connect#show ~callback:sizeMainWindow);

  (*********************************************************************
    Functions used to print in the main window
   *********************************************************************)
  let delayUpdates = ref false in

  let select row scroll =
    delayUpdates := true;
    mainWindow#selection#unselect_all ();
    mainWindow#selection#select_path row;
    mainWindow#set_cursor row status_view_col (* just a dummy column *);
    delayUpdates := false;
    if scroll then makeRowVisible row;
    updateDetails ()
  in
  let selectI i scroll = select (rowOfSi i) scroll in

  ignore (mainWindow#selection#connect#changed ~callback:
      (fun () -> if not !delayUpdates then updateDetails ()));

  let nextInteresting () =
    let l = Array.length !theState in
    let start = match currentRow () with Some (i, _, _) -> i + 1 | None -> 0 in
    let rec loop i =
      if i < l then
        match !theState.(i).ri.replicas with
          Different {direction = dir}
              when not (Prefs.read Uicommon.auto) || isConflict dir ->
            selectI i true
        | _ ->
            loop (i + 1) in
    loop start in
  let selectSomethingIfPossible () =
    if currentNumberRows () = 0 then nextInteresting () in

  let columnsOf si =
    let oldPath = Path.empty in
    let status =
      match si.ri.replicas with
        Different {direction = Conflict _} | Problem _ ->
          NoStatus
      | _ ->
          match si.whatHappened with
            None                     -> NoStatus
          | Some (Util.Succeeded, _) -> Done
          | Some (Util.Failed _, _)  -> Failed
    in
    let (r1, action, r2, path) =
      Uicommon.reconItem2stringList oldPath si.ri in
    (r1, action, r2, status, path)
  in

  let greenPixel  = "00dd00" in
  let redPixel    = "ff2040" in
  let lightbluePixel = "8888FF" in
  let orangePixel = "ff9303" in
(*
  let yellowPixel = "999900" in
  let blackPixel  = "000000" in
*)
  let buildPixmap p =
    GdkPixbuf.from_xpm_data p in
  let buildPixmaps f c1 =
    (buildPixmap (f c1), buildPixmap (f lightbluePixel)) in

  let doneIcon = buildPixmap Pixmaps.success in
  let failedIcon = buildPixmap Pixmaps.failure in
  let rightArrow = buildPixmaps Pixmaps.copyAB greenPixel in
  let leftArrow = buildPixmaps Pixmaps.copyBA greenPixel in
  let orangeRightArrow = buildPixmaps Pixmaps.copyAB orangePixel in
  let orangeLeftArrow = buildPixmaps Pixmaps.copyBA orangePixel in
  let ignoreAct = buildPixmaps Pixmaps.ignore redPixel in
  let failedIcons = (failedIcon, failedIcon) in
  let mergeLogo = buildPixmaps Pixmaps.mergeLogo greenPixel in
(*
  let rightArrowBlack = buildPixmap (Pixmaps.copyAB blackPixel) in
  let leftArrowBlack = buildPixmap (Pixmaps.copyBA blackPixel) in
  let mergeLogoBlack = buildPixmap (Pixmaps.mergeLogo blackPixel) in
*)

  let getArrow j action =
    let changedFromDefault = match !theState.(j).ri.replicas with
        Different diff -> diff.direction <> diff.default_direction
      | _ -> false in
    let sel pixmaps =
      if changedFromDefault then snd pixmaps else fst pixmaps in
    let pixmaps =
      match action with
        Uicommon.AError      -> failedIcons
      | Uicommon.ASkip _     -> ignoreAct
      | Uicommon.ALtoR false -> rightArrow
      | Uicommon.ALtoR true  -> orangeRightArrow
      | Uicommon.ARtoL false -> leftArrow
      | Uicommon.ARtoL true  -> orangeLeftArrow
      | Uicommon.AMerge      -> mergeLogo
    in
    sel pixmaps
  in


  let getStatusIcon = function
    | Failed   -> Some failedIcon
    | Done     -> Some doneIcon
    | NoStatus -> None in

  let displayRowAction row i action =
    mainWindowModel#set ~row ~column:c_action (getArrow i action) in
  let displayRowStatus row status =
    mainWindowModel#set ~row ~column:c_status (getStatusIcon status);
    if status <> NoStatus then
      mainWindowModel#set ~row ~column:c_statust "" in
  let displayRowPath row path =
    mainWindowModel#set ~row ~column:c_path (transcodeFilename path) in
  let displayRow row i r1 r2 action status path =
    mainWindowModel#set ~row ~column:c_replica1 r1;
    mainWindowModel#set ~row ~column:c_replica2 r2;
    displayRowAction row i action;
    displayRowStatus row status;
    displayRowPath row path;
    (*mainWindowModel#set ~row ~column:c_rowid i;*)
  in

  let displayMain() =
    (* The call to mainWindow#clear below side-effect current,
       so we save the current value before we clear out the main window and
       rebuild it. *)
    let savedCurrent = mainWindow#selection#get_selected_rows in
    mainWindow#set_model None;
    mainWindowModel#clear ();
    let tot = Array.length !theState - 1 in
    let totf = float_of_int (tot + 1) in
    progressBar#set_text (Printf.sprintf "Displaying %i items..." (tot + 1));
    for i = 0 to tot do
      if i mod 1024 = 0 then begin
        progressBar#set_fraction (max 0. (min 1. ((float_of_int i) /. totf)));
        gtk_sync false
      end;

      let (r1, action, r2, status, path) = columnsOf !theState.(i) in

      let row = mainWindowModel#append () in
      displayRow row i r1 r2 action status path;
    done;
    mainWindow#set_model (Some mainWindowModel#coerce);
    begin match savedCurrent with
    | []  -> selectSomethingIfPossible ()
    | [x] -> select x true
    | _   -> Safelist.iter (fun p -> mainWindow#selection#select_path p) savedCurrent
    end;

    progressBar#set_text ""; progressBar#set_fraction 0.;
    updateDetails ();  (* Do we need this line? *)
 in

  let redisplay i si iter =
    let (_, action, _, status, path) = columnsOf si in
    displayRowAction iter i action;
    displayRowStatus iter status;
    if status = Failed then displayRowPath iter (path ^
               "       [failed: click on this line for details]");
  in

  let fastRedisplay i =
    let si = !theState.(i) in
    let iter = mainWindowModel#get_iter (rowOfSi i) in
    let (_, action, _, status, path) = columnsOf si in
    displayRowStatus iter status;
    if status = Failed then begin
      displayRowPath iter (path ^
               "       [failed: click on this line for details]");
      match currentRow () with
      | Some (_, csi, _) when csi = si -> updateDetails ()
      | Some _ | None -> ()
    end
  in

  let updateRowStatus i newstatus =
    let row = mainWindowModel#get_iter (rowOfSi i) in
    let oldstatus = mainWindowModel#get ~row ~column:c_statust in
    if oldstatus <> newstatus then mainWindowModel#set ~row ~column:c_statust newstatus
  in

  let totalBytesToTransfer = ref Uutil.Filesize.zero in
  let totalBytesTransferred = ref Uutil.Filesize.zero in

  let t1 = ref 0. in
  let lastFrac = ref 0. in
  let sta = ref (Uicommon.Stats.init (Uutil.Filesize.zero)) in
  let displayGlobalProgress v =
    if v = 0. || abs_float (v -. !lastFrac) > 1. then begin
      lastFrac := v;
      progressBar#set_fraction (max 0. (min 1. (v /. 100.)))
    end;
    if v < 0.001 then
      progressBar#set_text " "
    else begin
      let t = Unix.gettimeofday () in
      Uicommon.Stats.update !sta t !totalBytesTransferred;
      let delta = t -. !t1 in
      if delta >= 0.5 then begin
        t1 := t;
        let remTime =
          if v >= 100. then "00:00 remaining" else
          (Uicommon.Stats.eta !sta "--:--") ^ " remaining"
        in
        let rate = Uicommon.Stats.avgRate1 !sta in
        let txt =
          if rate > 99. then
            Format.sprintf "%s  (%s)" remTime (rate2str rate)
          else
            remTime
        in
        progressBar#set_text txt
      end
    end
  in

  let showGlobalProgress b =
    (* Concatenate the new message *)
    totalBytesTransferred := Uutil.Filesize.add !totalBytesTransferred b;
    let v =
      (Uutil.Filesize.percentageOfTotalSize
         !totalBytesTransferred !totalBytesToTransfer)
    in
    displayGlobalProgress v
  in

  let root1IsLocal = ref true in
  let root2IsLocal = ref true in

  let initGlobalProgress b =
    let (root1,root2) = Globals.roots () in
    root1IsLocal := fst root1 = Local;
    root2IsLocal := fst root2 = Local;
    totalBytesToTransfer := b;
    totalBytesTransferred := Uutil.Filesize.zero;
    t1 := Unix.gettimeofday ();
    sta := Uicommon.Stats.init !totalBytesToTransfer;
    displayGlobalProgress 0.
  in

  let showProgress i bytes dbg =
    let i = Uutil.File.toLine i in
    let item = !theState.(i) in
    item.bytesTransferred <- Uutil.Filesize.add item.bytesTransferred bytes;
    let b = item.bytesTransferred in
    let len = item.bytesToTransfer in
    let newstatus =
      if b = Uutil.Filesize.zero || len = Uutil.Filesize.zero then "start "
      else if len = Uutil.Filesize.zero then
        Printf.sprintf "%5s " (Uutil.Filesize.toString b)
      else Util.percent2string (Uutil.Filesize.percentageOfTotalSize b len) in
    let dbg = if Trace.enabled "progress" then dbg ^ "/" else "" in
    let newstatus = dbg ^ newstatus in
    updateRowStatus i newstatus;
    showGlobalProgress bytes;
    gtk_sync false;
    begin match item.ri.replicas with
      Different diff ->
        begin match diff.direction with
          Replica1ToReplica2 ->
            if !root2IsLocal then
              clientWritten := !clientWritten +. Uutil.Filesize.toFloat bytes
            else
              serverWritten := !serverWritten +. Uutil.Filesize.toFloat bytes
        | Replica2ToReplica1 ->
            if !root1IsLocal then
              clientWritten := !clientWritten +. Uutil.Filesize.toFloat bytes
            else
              serverWritten := !serverWritten +. Uutil.Filesize.toFloat bytes
        | Conflict _ | Merge ->
            (* Diff / merge *)
            clientWritten := !clientWritten +. Uutil.Filesize.toFloat bytes
        end
    | _ ->
        assert false
    end
  in

  (* Install showProgress so that we get called back by low-level
     file transfer stuff *)
  Uutil.setProgressPrinter showProgress;

  (* Apply new ignore patterns to the current state, expecting that the
     number of reconitems will grow smaller. Adjust the display, being
     careful to keep the cursor as near as possible to its position
     before the new ignore patterns take effect. *)
  let ignoreAndRedisplay () =
    let lst = Array.to_list !theState in
    (* FIX: we should actually test whether any prefix is now ignored *)
    let keep sI = not (Globals.shouldIgnore sI.ri.path1) in
    theState := Array.of_list (Safelist.filter keep lst);
    displayMain() in

  let sortAndRedisplay () =
    let compareRIs = Sortri.compareReconItems() in
    Array.stable_sort (fun si1 si2 -> compareRIs si1.ri si2.ri) !theState;
    displayMain() in

  (******************************************************************
   Main detect-updates-and-reconcile logic
   ******************************************************************)

  let commitUpdates () =
    Trace.status "Updating synchronizer state";
    let t = Trace.startTimer "Updating synchronizer state" in
    gtk_sync true;
    Update.commitUpdates();
    Trace.showTimer t
  in

  let clearMainWindow () =
    grDisactivateAll ();
    make_busy toplevelWindow;
    mainWindow#set_model None;
    mainWindowModel#clear ();
    mainWindow#set_model (Some mainWindowModel#coerce);
    theState := [||];
    detailsWindow#buffer#set_text ""
  in

  let detectUpdatesAndReconcile () =
    clearMainWindow ();
    startStats ();
    progressBarPulse := true;
    sync_action := Some (fun () -> progressBar#pulse ());
    let findUpdates () =
      let t = Trace.startTimer "Checking for updates" in
      Trace.status "Looking for changes";
      let updates = Update.findUpdates ~wantWatcher:true !unsynchronizedPaths in
      Trace.showTimer t;
      updates in
    let reconcile updates =
      let t = Trace.startTimer "Reconciling" in
      let reconRes = Recon.reconcileAll ~allowPartial:true updates in
      Trace.showTimer t;
      reconRes in
    let (reconItemList, thereAreEqualUpdates, dangerousPaths) =
      reconcile (findUpdates ()) in
    if not !Update.foundArchives then commitUpdates ();
    if reconItemList = [] then begin
      if !Update.foundArchives then commitUpdates ();
      if thereAreEqualUpdates then
        Trace.status
          "Replicas have been changed only in identical ways since last sync"
      else
        Trace.status "Everything is up to date"
    end else
      Trace.status "Check and/or adjust selected actions; then press Go";
    theState :=
      Array.of_list
         (Safelist.map
            (fun ri -> { ri = ri;
                         bytesTransferred = Uutil.Filesize.zero;
                         bytesToTransfer = Uutil.Filesize.zero;
                         whatHappened = None })
            reconItemList);
    unsynchronizedPaths :=
      Some (Safelist.map (fun ri -> ri.path1) reconItemList, []);
    progressBarPulse := false; sync_action := None; displayGlobalProgress 0.;
    displayMain();
    progressBarPulse := false; sync_action := None; displayGlobalProgress 0.;
    stopStats ();
    grSet grGo (Array.length !theState > 0);
    grSet grRescan true;
    make_interactive toplevelWindow;
    if Prefs.read Globals.confirmBigDeletes then begin
      if dangerousPaths <> [] then begin
        Prefs.set Globals.batch false;
        Util.warn (Uicommon.dangerousPathMsg dangerousPaths)
      end;
    end;
  in

  (*********************************************************************
    Help menu
   *********************************************************************)
  let addDocSection (shortname, (name, docstr)) =
    let parent = toplevelWindow in
    if shortname = "about" then
      ignore (helpMenu#add_image_item
                ~stock:`ABOUT ~callback:(fun () -> documentation ~parent shortname)
                name)
    else if shortname <> "" && name <> "" then
      ignore (helpMenu#add_item
                ~callback:(fun () -> documentation ~parent shortname)
                name) in
  Safelist.iter addDocSection Strings.docs;

  (*********************************************************************
    Ignore menu
   *********************************************************************)
  let addRegExpByPath pathfunc =
    Util.StringSet.iter (fun pat -> Uicommon.addIgnorePattern pat)
      (currentSelectedFold
         (fun s si -> Util.StringSet.add (pathfunc si.ri.path1) s)
         Util.StringSet.empty);
    ignoreAndRedisplay ()
  in
  grAdd grAction
    (ignoreMenu#add_item ~key:GdkKeysyms._i
       ~callback:(fun () -> getLock (fun () ->
          addRegExpByPath Uicommon.ignorePath))
       "Permanently Ignore This _Path");
  grAdd grAction
    (ignoreMenu#add_item ~key:GdkKeysyms._E
       ~callback:(fun () -> getLock (fun () ->
          addRegExpByPath Uicommon.ignoreExt))
       "Permanently Ignore Files with this _Extension");
  grAdd grAction
    (ignoreMenu#add_item ~key:GdkKeysyms._N
       ~callback:(fun () -> getLock (fun () ->
          addRegExpByPath Uicommon.ignoreName))
       "Permanently Ignore Files with this _Name (in any Dir)");

  (*
  grAdd grRescan
    (ignoreMenu#add_item ~callback:
       (fun () -> getLock ignoreDialog) "Edit ignore patterns");
  *)

  (*********************************************************************
    Sort menu
   *********************************************************************)
  grAdd grRescan
    (sortMenu#add_item
       ~callback:(fun () -> getLock (fun () ->
          Sortri.sortByName();
          sortAndRedisplay()))
       "Sort by _Name");
  grAdd grRescan
    (sortMenu#add_item
       ~callback:(fun () -> getLock (fun () ->
          Sortri.sortBySize();
          sortAndRedisplay()))
       "Sort by _Size");
  grAdd grRescan
    (sortMenu#add_item
       ~callback:(fun () -> getLock (fun () ->
          Sortri.sortNewFirst();
          sortAndRedisplay()))
       "Sort Ne_w Entries First (toggle)");
  grAdd grRescan
    (sortMenu#add_item
       ~callback:(fun () -> getLock (fun () ->
          Sortri.restoreDefaultSettings();
          sortAndRedisplay()))
       "_Default Ordering");

  (*********************************************************************
    Main function : synchronize
   *********************************************************************)
  let synchronize () =
    if Array.length !theState = 0 then
      Trace.status "Nothing to synchronize"
    else begin
      grDisactivateAll ();
      make_busy toplevelWindow;

      Trace.status "Propagating changes";
      Uicommon.transportStart ();
      grSet grStop true;
      let totalLength =
        Array.fold_left
          (fun l si ->
             si.bytesTransferred <- Uutil.Filesize.zero;
             let len =
               if si.whatHappened = None then Common.riLength si.ri else
               Uutil.Filesize.zero
             in
             si.bytesToTransfer <- len;
             Uutil.Filesize.add l len)
          Uutil.Filesize.zero !theState in
      initGlobalProgress totalLength;
      let t = Trace.startTimer "Propagating changes" in
      let uiWrapper i theSI =
        match theSI.whatHappened with
          None ->
            let textDetailed = ref None in
            catch (fun () ->
                     Transport.transportItem
                       theSI.ri (Uutil.File.ofLine i)
                       (fun title text ->
                         textDetailed := (Some text);
                         if Prefs.read Uicommon.confirmmerge then
                           twoBoxAdvanced
                             ~parent:toplevelWindow
                             ~title:title
                             ~message:("Do you want to commit the changes to"
                                       ^ " the replicas ?")
                             ~longtext:text
                             ~advLabel:"View details..."
                             ~astock:`YES
                             ~bstock:`NO
                         else
                           true)
                     >>= (fun () ->
                       return Util.Succeeded))
                   (fun e ->
                     match e with
                       Util.Transient s ->
                         return (Util.Failed s)
                     | _ ->
                         fail e)
              >>= (fun res ->
                let rem =
                  Uutil.Filesize.sub
                    theSI.bytesToTransfer theSI.bytesTransferred
                in
                if rem <> Uutil.Filesize.zero then
                  showProgress (Uutil.File.ofLine i) rem "done";
                theSI.whatHappened <- Some (res, !textDetailed);
            fastRedisplay i;
            gtk_sync false;
            return ())
        | Some _ ->
            return () (* Already processed this one (e.g. merged it) *)
      in
      startStats ();
      Uicommon.transportItems !theState (fun {ri; _} -> not (Common.isDeletion ri)) uiWrapper;
      Uicommon.transportItems !theState (fun {ri; _} -> Common.isDeletion ri) uiWrapper;
      Uicommon.transportFinish ();
      grSet grStop false;
      Trace.showTimer t;
      commitUpdates ();
      stopStats ();

      let failureList =
        Array.fold_right
          (fun si l ->
             match si.whatHappened with
               Some (Util.Failed err, _) ->
                 (si, [err], "transport failure") :: l
             | _ ->
                 l)
          !theState []
      in
      let failureCount = List.length failureList in
      let failures =
        if failureCount = 0 then [] else
        [Printf.sprintf "%d failure%s"
           failureCount (if failureCount = 1 then "" else "s")]
      in
      let partialList =
        Array.fold_right
          (fun si l ->
             match si.whatHappened with
               Some (Util.Succeeded, _)
               when partiallyProblematic si.ri &&
                    not (problematic si.ri) ->
                 let errs =
                   match si.ri.replicas with
                     Different diff -> diff.errors1 @ diff.errors2
                   | _              -> assert false
                 in
                 (si, errs,
                  "partial transfer (errors during update detection)") :: l
             | _ ->
                 l)
          !theState []
      in
      let partialCount = List.length partialList in
      let partials =
        if partialCount = 0 then [] else
        [Printf.sprintf "%d partially transferred" partialCount]
      in
      let skippedList =
        Array.fold_right
          (fun si l ->
             match si.ri.replicas with
               Problem err ->
                 (si, [err], "error during update detection") :: l
             | Different diff when isConflict diff.direction ->
                 (si, [],
                  if isConflict diff.default_direction then
                    "conflict"
                  else "skipped") :: l
             | _ ->
                 l)
          !theState []
      in
      let skippedCount = List.length skippedList in
      let skipped =
        if skippedCount = 0 then [] else
        [Printf.sprintf "%d skipped" skippedCount]
      in
      let nostartCount =
        if not (Abort.isAll ()) then 0 else
          Array.fold_left
            (fun c si -> if si.whatHappened = None then c + 1 else c)
            0 !theState
      in
      let nostart =
        if nostartCount = 0 then [] else
        [Printf.sprintf "%d not started" nostartCount]
      in
      unsynchronizedPaths :=
        Some (Safelist.map (fun (si, _, _) -> si.ri.path1)
                (failureList @ partialList @ skippedList),
              []);
      Trace.status
        (Printf.sprintf "Synchronization complete         %s"
           (String.concat ", " (failures @ partials @ skipped @ nostart)));
      displayGlobalProgress 0.;

      grSet grRescan true;
      make_interactive toplevelWindow;

      let totalCount = failureCount + partialCount + skippedCount + nostartCount in
      if totalCount > 0 then begin
        let format n item sing plur =
          match n with
            0 -> []
          | 1 -> [Format.sprintf "one %s%s" item sing]
          | n -> [Format.sprintf "%d %s%s" n item plur]
        in
        let infos =
          format failureCount "failure" "" "s" @
          format partialCount "partially transferred director" "y" "ies" @
          format skippedCount "skipped item" "" "s" @
          format nostartCount "not started item" "" "s"
        in
        let message =
          (if failureCount = 0 && nostartCount = 0 then
             "The synchronization was successful.\n\n"
           else "") ^
          "The replicas are not fully synchronized.\n" ^
          (if totalCount < 2 then "There was" else "There were") ^
          begin match infos with
            [] -> assert false
          | [x] -> " " ^ x
          | l -> ":\n  - " ^ String.concat ";\n  - " l
          end ^
          "."
        in
        summaryBox ~parent:toplevelWindow
          ~title:"Synchronization summary" ~message ~f:
          (fun t ->
             let bullet = "\xe2\x80\xa2 " in
             let layout = Pango.Layout.create t#misc#pango_context#as_context in
             Pango.Layout.set_text layout bullet;
             let (n, _) = Pango.Layout.get_pixel_size layout in
             let path =
               t#buffer#create_tag [`FONT_DESC (Lazy.force fontBold)] in
             let description =
               t#buffer#create_tag [`FONT_DESC (Lazy.force fontItalic)] in
             let errorFirstLine =
               t#buffer#create_tag [`LEFT_MARGIN (n); `INDENT (- n)] in
             let errorNextLines =
               t#buffer#create_tag [`LEFT_MARGIN (2 * n)] in
             List.iter
               (fun (si, errs, desc) ->
                  t#buffer#insert ~tags:[path]
                    (transcodeFilename (Path.toString si.ri.path1));
                  t#buffer#insert ~tags:[description]
                    (" \xe2\x80\x94 " ^ desc ^ "\n");
                  List.iter
                    (fun err ->
                       let errl =
                         Str.split (Str.regexp_string "\n") (transcode err) in
                       match errl with
                         [] ->
                           ()
                       | f :: rem ->
                           t#buffer#insert ~tags:[errorFirstLine]
                             (bullet ^ f ^ "\n");
                           List.iter
                             (fun n ->
                                t#buffer#insert ~tags:[errorNextLines]
                                  (n ^ "\n"))
                             rem)
                    errs)
               (failureList @ partialList @ skippedList))
      end

    end in

  (*********************************************************************
    Buttons for -->, M, <--, Skip
   *********************************************************************)
  let doActionOnRow f i theSI iter =
    begin match theSI.whatHappened, theSI.ri.replicas with
      None, Different diff ->
        f theSI.ri diff;
        redisplay i theSI iter
    | _ ->
        ()
    end
  in
  let doAction f =
    match currentRow () with
      Some (i, si, iter) ->
        doActionOnRow f i si iter;
        nextInteresting ()
    | None ->
        currentSelectedIter (fun i si iter -> doActionOnRow f i si iter);
        updateDetails ()
  in
  let leftAction _ =
    doAction (fun _ diff -> diff.direction <- Replica2ToReplica1) in
  let rightAction _ =
    doAction (fun _ diff -> diff.direction <- Replica1ToReplica2) in
  let questionAction _ = doAction (fun _ diff -> diff.direction <- Conflict "") in
  let mergeAction    _ = doAction (fun _ diff -> diff.direction <- Merge) in

  let insert_button (toolbar : #GButton.toolbar) ~stock ~text ~tooltip ~callback () =
    let b = GButton.tool_button ~stock ~label:text ~packing:toolbar#insert () in
    ignore (b#connect#clicked ~callback);
    b#misc#set_tooltip_text tooltip;
    b
  in

(*  actionBar#insert_space ();*)
  grAdd grAction
    (insert_button actionBar
       ~stock:`GO_FORWARD
       ~text:"Left to Right"
       ~tooltip:"Propagate selected items\n\
                 from the left replica to the right one"
       ~callback:rightAction ());
(*  actionBar#insert_space ();*)
  grAdd grAction
    (insert_button actionBar ~text:"Skip"
       ~stock:`NO
       ~tooltip:"Skip selected items"
       ~callback:questionAction ());
(*  actionBar#insert_space ();*)
  grAdd grAction
    (insert_button actionBar
       ~stock:`GO_BACK
       ~text:"Right to Left"
       ~tooltip:"Propagate selected items\n\
                 from the right replica to the left one"
       ~callback:leftAction ());
(*  actionBar#insert_space ();*)
  grAdd grAction
    (insert_button actionBar
       ~stock:`ADD
       ~text:"Merge"
       ~tooltip:"Merge selected files"
       ~callback:mergeAction ());

  (*********************************************************************
    Diff / merge buttons
   *********************************************************************)
  let diffCmd () =
    match currentRow () with
      Some (i, item, _) ->
        getLock (fun () ->
          let len =
            match item.ri.replicas with
              Problem _ ->
                Uutil.Filesize.zero
            | Different diff ->
                snd (if !root1IsLocal then diff.rc2 else diff.rc1).size
          in
          item.bytesTransferred <- Uutil.Filesize.zero;
          item.bytesToTransfer <- len;
          initGlobalProgress len;
          startStats ();
          Uicommon.showDiffs item.ri
            (fun title text ->
               messageBox ~title:(transcode title) (transcode text))
            Trace.status (Uutil.File.ofLine i);
          stopStats ();
          displayGlobalProgress 0.;
          fastRedisplay i)
    | None ->
        () in

  actionBar#insert (GButton.separator_tool_item ());
  grAdd grDiff (insert_button actionBar ~text:"Diff"
                  ~stock:`DIALOG_INFO
                  ~tooltip:"Compare the two files at each replica"
                  ~callback:diffCmd ());

  (*********************************************************************
    Detail button
   *********************************************************************)
(*  actionBar#insert_space ();*)
  grAdd grDetail (insert_button actionBar ~text:"Details"
                    ~stock:`INFO
                    ~tooltip:"Show detailed information about\n\
                              an item, when available"
                    ~callback:showDetCommand ());

  (*********************************************************************
    Quit button
   *********************************************************************)
(*  actionBar#insert_space ();
  ignore (actionBar#insert_button ~text:"Quit"
            ~icon:((GMisc.image ~stock:`QUIT ())#coerce)
            ~tooltip:"Exit Unison"
            ~callback:safeExit ());
*)

  (*********************************************************************
    go button
   *********************************************************************)
  actionBar#insert (GButton.separator_tool_item ());
  grAdd grGo
    (insert_button actionBar ~text:"Go"
       (* tooltip:"Go with displayed actions" *)
       ~stock:`EXECUTE
       ~tooltip:"Perform the synchronization"
       ~callback:(fun () ->
                    getLock synchronize) ());

  grAdd grStop
    (insert_button actionBar ~text:"Stop"
       ~stock:`STOP
       ~tooltip:"Stop update propagation"
       ~callback:Abort.all ());

  (*********************************************************************
    Rescan button
   *********************************************************************)
  let profileInitSuccess = ref false in
  let updateFromProfile = ref (fun () -> ()) in

  let loadProfile p reload =
    debug (fun()-> Util.msg "Loading profile %s..." p);
    Trace.status "Loading profile";
    unsynchronizedPaths := None;
    profileInitSuccess := false;
    Uicommon.initPrefs ~profileName:p ~promptForRoots ~prepDebug ();
    Uicommon.connectRoots
      ~displayWaitMessage:(fun () -> if not reload then displayWaitMessage ())
      ~termInteract ();
    profileInitSuccess := true;
    !updateFromProfile ()
  in

  let reloadProfile () =
    let n =
      match !Prefs.profileName with
        None   -> assert false
      | Some n -> n
    in
    clearMainWindow ();
    if not (Prefs.profileUnchanged ()) || not (!profileInitSuccess) then
      loadProfile n true
    else Uicommon.connectRoots ~displayWaitMessage ~termInteract ()
  in

  let detectCmd () =
    if !profileInitSuccess then begin
      getLock detectUpdatesAndReconcile;
      updateDetails ();
      if Prefs.read Globals.batch then begin
        Prefs.set Globals.batch false; synchronize()
      end
    end else begin
      grSet grRescan true;
      make_interactive toplevelWindow
    end
  in
(*  actionBar#insert_space ();*)
  grAdd grRescan
    (insert_button actionBar ~text:"Rescan"
       ~stock:`REFRESH
       ~tooltip:"Check for updates"
       ~callback: (fun () -> reloadProfile(); detectCmd()) ());

  (*********************************************************************
    Profile change button
   *********************************************************************)
  actionBar#insert (GButton.separator_tool_item ());
  let profileChange _ =
    match getProfile false with
      None   -> ()
    | Some p -> clearMainWindow (); loadProfile p false; detectCmd ()
  in
  grAdd grRescan (insert_button actionBar ~text:"Change Profile"
                    ~stock:`OPEN
                    ~tooltip:"Select a different profile"
                    ~callback:profileChange ());

  (*********************************************************************
    Keyboard commands
   *********************************************************************)
  ignore
    (mainWindow#event#connect#key_press ~callback:
       begin fun ev ->
         let key = GdkEvent.Key.keyval ev in
         if key = GdkKeysyms._Left then begin
           leftAction (); GtkSignal.stop_emit (); true
         end else if key = GdkKeysyms._Right then begin
           rightAction (); GtkSignal.stop_emit (); true
         end else
           false
       end);

  (*********************************************************************
    Action menu
   *********************************************************************)
  let buildActionMenu init =
    let withDelayedUpdates f x =
      delayUpdates := true;
      f x;
      delayUpdates := false;
      updateDetails () in
    let actionMenu = replace_submenu "_Actions" actionItem in
    grAdd grRescan
      (actionMenu#add_image_item
         ~callback:(fun _ -> withDelayedUpdates mainWindow#selection#select_all ())
         ~image:((GMisc.image ~stock:`SELECT_ALL ~icon_size:`MENU ())#coerce)
         ~modi:[`CONTROL] ~key:GdkKeysyms._A
         "Select _All");
    grAdd grRescan
      (actionMenu#add_item
         ~callback:(fun _ -> withDelayedUpdates mainWindow#selection#unselect_all ())
         ~modi:[`SHIFT; `CONTROL] ~key:GdkKeysyms._A
         "_Deselect All");

    ignore (actionMenu#add_separator ());

    let (loc1, loc2) =
      if init then ("", "") else
      let (root1,root2) = Globals.roots () in
      (root2hostname root1, root2hostname root2)
    in
    let def_descr = "Left to Right" in
    let descr =
      if init || loc1 = loc2 then def_descr else
      Printf.sprintf "from %s to %s" loc1 loc2 in
    let left =
      actionMenu#add_image_item ~key:GdkKeysyms._greater ~callback:rightAction
        ~image:((GMisc.image ~stock:`GO_FORWARD ~icon_size:`MENU ())#coerce)
        ~name:("Propagate " ^ def_descr) ("Propagate " ^ descr) in
    grAdd grAction left;
    left#add_accelerator ~group:accel_group ~modi:[`SHIFT] GdkKeysyms._greater;
    left#add_accelerator ~group:accel_group GdkKeysyms._period;

    let def_descl = "Right to Left" in
    let descl =
      if init || loc1 = loc2 then def_descl else
      Printf.sprintf "from %s to %s"
        (Unicode.protect loc2) (Unicode.protect loc1) in
    let right =
      actionMenu#add_image_item ~key:GdkKeysyms._less ~callback:leftAction
        ~image:((GMisc.image ~stock:`GO_BACK ~icon_size:`MENU ())#coerce)
        ~name:("Propagate " ^ def_descl) ("Propagate " ^ descl) in
    grAdd grAction right;
    right#add_accelerator ~group:accel_group ~modi:[`SHIFT] GdkKeysyms._less;
    right#add_accelerator ~group:accel_group ~modi:[`SHIFT] GdkKeysyms._comma;

    let skip =
      actionMenu#add_image_item ~key:GdkKeysyms._slash ~callback:questionAction
        ~image:((GMisc.image ~stock:`NO ~icon_size:`MENU ())#coerce)
        "Do _Not Propagate Changes" in
    grAdd grAction skip;
    skip#add_accelerator ~group:accel_group ~modi:[`SHIFT] GdkKeysyms._minus;
    skip#add_accelerator ~group:accel_group GdkKeysyms._KP_Divide;

    let merge =
      actionMenu#add_image_item ~key:GdkKeysyms._m ~callback:mergeAction
        ~image:((GMisc.image ~stock:`ADD ~icon_size:`MENU ())#coerce)
        "_Merge the Files" in
    grAdd grAction merge;
  (* merge#add_accelerator ~group:accel_group ~modi:[`SHIFT] GdkKeysyms._m; *)

    (* Override actions *)
    ignore (actionMenu#add_separator ());
    grAdd grAction
      (actionMenu#add_item
         ~callback:(fun () ->
            doAction (fun ri _ ->
                        Recon.setDirection ri `Replica1ToReplica2 `Prefer))
         "Resolve Conflicts in Favor of First Root");
    grAdd grAction
      (actionMenu#add_item
         ~callback:(fun () ->
            doAction (fun ri _ ->
                        Recon.setDirection ri `Replica2ToReplica1 `Prefer))
         "Resolve Conflicts in Favor of Second Root");
    grAdd grAction
      (actionMenu#add_item
         ~callback:(fun () ->
            doAction (fun ri _ ->
                        Recon.setDirection ri `Newer `Prefer))
         "Resolve Conflicts in Favor of Most Recently Modified");
    grAdd grAction
      (actionMenu#add_item
         ~callback:(fun () ->
            doAction (fun ri _ ->
                        Recon.setDirection ri `Older `Prefer))
         "Resolve Conflicts in Favor of Least Recently Modified");
    ignore (actionMenu#add_separator ());
    grAdd grAction
      (actionMenu#add_item
         ~callback:(fun () ->
            doAction (fun ri _ -> Recon.setDirection ri `Newer `Force))
         "Force Newer Files to Replace Older Ones");
    grAdd grAction
      (actionMenu#add_item
         ~callback:(fun () ->
            doAction (fun ri _ -> Recon.setDirection ri `Older `Force))
         "Force Older Files to Replace Newer Ones");
    ignore (actionMenu#add_separator ());
    grAdd grAction
      (actionMenu#add_item
         ~callback:(fun () ->
            doAction (fun ri _ -> Recon.revertToDefaultDirection ri))
         "_Revert to Unison's Recommendation");
    grAdd grAction
      (actionMenu#add_item
         ~callback:(fun () ->
            doAction (fun ri _ -> Recon.setDirection ri `Merge `Force))
         "Revert to the Merging Default, if Available");

    (* Diff *)
    ignore (actionMenu#add_separator ());
    grAdd grDiff (actionMenu#add_image_item ~key:GdkKeysyms._d ~callback:diffCmd
        ~image:((GMisc.image ~stock:`DIALOG_INFO ~icon_size:`MENU ())#coerce)
        "Show _Diffs");

    (* Details *)
    grAdd grDetail
      (actionMenu#add_image_item ~key:GdkKeysyms._i ~callback:showDetCommand
        ~image:((GMisc.image ~stock:`INFO ~icon_size:`MENU ())#coerce)
        "Detailed _Information")

  in
  buildActionMenu true;

  (*********************************************************************
    Synchronization menu
   *********************************************************************)

  grAdd grGo
    (fileMenu#add_image_item ~key:GdkKeysyms._g
       ~image:(GMisc.image ~stock:`EXECUTE ~icon_size:`MENU () :> GObj.widget)
       ~callback:(fun () -> getLock synchronize)
       "_Go");
  grAdd grRescan
    (fileMenu#add_image_item ~key:GdkKeysyms._r
       ~image:(GMisc.image ~stock:`REFRESH ~icon_size:`MENU () :> GObj.widget)
       ~callback:(fun () -> reloadProfile(); detectCmd())
       "_Rescan");
  grAdd grRescan
    (fileMenu#add_item ~key:GdkKeysyms._a
       ~callback:(fun () ->
                    reloadProfile();
                    Prefs.set Globals.batch true;
                    detectCmd())
       "_Detect Updates and Proceed (Without Waiting)");
  grAdd grRescan
    (fileMenu#add_item ~key:GdkKeysyms._f
       ~callback:(
         fun () ->
           let rec loop i acc =
             if i >= Array.length (!theState) then acc else
             let notok =
               (match !theState.(i).whatHappened with
                   None-> true
                 | Some(Util.Failed _, _) -> true
                 | Some(Util.Succeeded, _) -> false)
              || match !theState.(i).ri.replicas with
                   Problem _ -> true
                 | Different diff -> isConflict diff.direction in
             if notok then loop (i+1) (i::acc)
             else loop (i+1) (acc) in
           let failedindices = loop 0 [] in
           let failedpaths =
             Safelist.map (fun i -> !theState.(i).ri.path1) failedindices in
           debug (fun()-> Util.msg "Rescaning with paths = %s\n"
                    (String.concat ", " (Safelist.map
                                           (fun p -> "'"^(Path.toString p)^"'")
                                           failedpaths)));
           let paths = Prefs.read Globals.paths in
           let confirmBigDeletes = Prefs.read Globals.confirmBigDeletes in
           Prefs.set Globals.paths failedpaths;
           Prefs.set Globals.confirmBigDeletes false;
           (* Modifying global paths does not play well with filesystem
              monitoring, so we disable it. *)
           unsynchronizedPaths := None;
           detectCmd();
           Prefs.set Globals.paths paths;
           Prefs.set Globals.confirmBigDeletes confirmBigDeletes;
           unsynchronizedPaths := None)
       "Re_check Unsynchronized Items");

  ignore (fileMenu#add_separator ());

  grAdd grRescan
    (fileMenu#add_image_item ~key:GdkKeysyms._p
       ~callback:(fun _ ->
          match getProfile false with
            None -> ()
          | Some(p) -> clearMainWindow (); loadProfile p false; detectCmd ())
       ~image:(GMisc.image ~stock:`OPEN ~icon_size:`MENU () :> GObj.widget)
       "Change _Profile...");

  let fastProf i key =
    let item = fileMenu#add_item ~key:key ~bindname:(string_of_int i) "" in
    item#misc#hide ();
    grAdd grRescan item;
    let show name =
      match item#children with
      | [] | _::_::_ -> ()
      | [l] ->
          let label = (GMisc.label_cast l) in
          label#set_label ("Select profile " ^ name);
          ignore (item#connect#activate
            ~callback:(fun _ ->
               if System.file_exists (Prefs.profilePathname name) then begin
                 Trace.status ("Loading profile " ^ name);
                 loadProfile name false; detectCmd ()
               end else
                 Trace.status ("Profile " ^ name ^ " not found"))
            );
          item#misc#show ()
    in
    (item#misc#hide, show) in

  let fastKeysyms =
    [| GdkKeysyms._0; GdkKeysyms._1; GdkKeysyms._2; GdkKeysyms._3;
       GdkKeysyms._4; GdkKeysyms._5; GdkKeysyms._6; GdkKeysyms._7;
       GdkKeysyms._8; GdkKeysyms._9 |] in

  let fastKeyitems = Array.init 10 (fun i -> fastProf i fastKeysyms.(i)) in

  let updateProfileKeyMenu () =
    if !Uicommon.profilesAndRoots = [] then Uicommon.scanProfiles ();

    Array.iteri
      (fun i v -> match v with
      | None -> (fst fastKeyitems.(i)) ()
      | Some (profile, info) -> (snd fastKeyitems.(i)) profile)
      Uicommon.profileKeymap
  in

  ignore (fileMenu#add_separator ());
  ignore (fileMenu#add_item
            ~callback:(fun _ -> statWin#show ()) "Show _Statistics");

  ignore (fileMenu#add_separator ());
  let quit =
    fileMenu#add_image_item
      ~key:GdkKeysyms._q ~callback:safeExit
      ~image:((GMisc.image ~stock:`QUIT ~icon_size:`MENU ())#coerce)
      "_Quit"
  in
  quit#add_accelerator ~group:accel_group ~modi:[`CONTROL] GdkKeysyms._q;

  (*********************************************************************
    Expert menu
   *********************************************************************)
  if Prefs.read Uicommon.expert then begin
    let (expertMenu, _) = add_submenu "Expert" in

    let addDebugToggle modname =
      ignore (expertMenu#add_check_item ~active:(Trace.enabled modname)
        ~callback:(fun b -> Trace.enable modname b)
        ("Debug '" ^ modname ^ "'")) in

    addDebugToggle "all";
    addDebugToggle "verbose";
    addDebugToggle "update";

    ignore (expertMenu#add_separator ());
    ignore (expertMenu#add_item
              ~callback:(fun () ->
                           Printf.fprintf stderr "\nGC stats now:\n";
                           Gc.print_stat stderr;
                           Printf.fprintf stderr "\nAfter major collection:\n";
                           Gc.full_major(); Gc.print_stat stderr;
                           flush stderr)
              "Show memory/GC stats")
  end;

  (*********************************************************************
    Finish up
   *********************************************************************)
  grDisactivateAll ();

  updateFromProfile :=
    (fun () ->
       displayNewProfileLabel ();
       setMainWindowColumnHeaders (Uicommon.roots2string ());
       sizeMainWindow ();
       buildActionMenu false);

  fatalErrorHandler :=
    (fun err ->
       grDisactivateAll ();
       make_interactive toplevelWindow;
       Trace.status ("Fatal error: " ^ err);
       inExit := true;
       fatalError err;
       inExit := false;
       match !Prefs.profileName with
       | Some _ -> grSet grRescan true
       | None ->  (* Normally should never get here; exceptions loading the
                     very first profile are handled in the [start] function. *)
           begin match getProfile true with
           | None -> exit 1
           | Some p -> clearMainWindow (); loadProfile p false; detectCmd ()
           end
    );


  ignore (toplevelWindow#event#connect#delete ~callback:
            (fun _ -> safeExit (); true));
  toplevelWindow#show ();
  fun p ->
    updateProfileKeyMenu ();
    mainWindow#misc#grab_focus ();
    loadProfile p false;
    detectCmd ()


(*********************************************************************
                               STARTUP
 *********************************************************************)

let start _ =
  try
    (* Stop GTK 3 from forcing client-side decorations *)
    begin
      try ignore (Unix.getenv "GTK_CSD") with
      | Unix.Unix_error _ | Not_found ->
          try Unix.putenv "GTK_CSD" "0" with
          | Unix.Unix_error _ -> ()
    end;

    (* Initialize the GTK library *)
    ignore (GMain.Main.init ());

    Util.warnPrinter :=
      Some (fun msg -> warnBox ~parent:(toplevelWindow ()) "Warning" msg);

    GtkSignal.user_handler :=
      (function
       | Util.Transient s | Util.Fatal s -> !fatalErrorHandler s
       | exn -> !fatalErrorHandler (Uicommon.exn2string exn));

    (* Ask the Remote module to call us back at regular intervals during
       long network operations. *)
    let rec tick () =
      gtk_sync true;
      Lwt_unix.sleep 0.05 >>= tick
    in
    ignore_result (tick ());

    let startGUI = createToplevelWindow () in

    (* Any exceptions here will be caught by the main catch handler
       and the GUI will exit. *)
    let getProfile () = match getProfile true with None -> exit 0 | Some x -> x in
    let profileName =
      match Uicommon.uiInitClRootsAndProfile ~prepDebug () with
      | Error s -> begin fatalError s;
                         Uicommon.clearClRoots (); getProfile () end
      | Ok None -> getProfile ()
      | Ok (Some s) -> s
    in

    (* Exceptions from here onwards will be caught by the inner catch handler
       and the GUI will not exit. Instead, the profile manager is re-opened.
       User has the option to quit in the profile manager. *)
    let rec initLoop profileName =
      try startGUI profileName with
      | Util.Transient s | Util.Fatal s ->
          s |> fatalError |> Uicommon.clearClRoots |> getProfile |> initLoop
      (* Since we have not started the GTK main loop yet, it is easier to
         handle exceptions here directly. [GtkSignal.safe_call] could be
         used but it will fail in case of subsequent exceptions without
         raising, thus escaping further exception handlers.
         This separate handling sequence could in theory be removed if
         [startGUI] is called while the GTK main loop is running. *)
    in
    initLoop profileName;

    (* Display the ui *)
(*JV: not useful, as Unison does not handle any signal
    ignore (GMain.Timeout.add 500 (fun _ -> true));
              (* Hack: this allows signals such as SIGINT to be
                 handled even when Gtk is waiting for events *)
*)
    GMain.Main.main ()
  with
  | Util.Transient s | Util.Fatal s -> fatalError ~quit:true s
  | exn -> fatalError ~quit:true (Uicommon.exn2string exn)

end (* module Private *)


(*********************************************************************
                            UI SELECTION
 *********************************************************************)

module Body : Uicommon.UI = struct

let start = function
    Uicommon.Text -> Uitext.Body.start Uicommon.Text
  | Uicommon.Graphic ->
      let displayAvailable =
        Util.osType = `Win32
          ||
        (try System.getenv "DISPLAY" <> "" with Not_found -> false)
          ||
        (try System.getenv "WAYLAND_DISPLAY" <> "" with Not_found -> false)
      in
      if displayAvailable then Private.start Uicommon.Graphic
      else begin
        Util.warn "DISPLAY and WAYLAND_DISPLAY not set or empty; starting the Text UI\n";
        Uitext.Body.start Uicommon.Text
      end

let defaultUi = Uicommon.Graphic

end (* module Body *)
