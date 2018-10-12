module BuildType = struct
  include EsyLib.BuildType
  include EsyLib.BuildType.AsInPackageJson
end

module Solution = EsyInstall.Solution
module SandboxSpec = EsyInstall.SandboxSpec
module ManifestSpec = EsyInstall.ManifestSpec
module Package = EsyInstall.Package
module Version = EsyInstall.Version
module Source = EsyInstall.Source
module SourceType = EsyLib.SourceType
module Command = Package.Command
module CommandList = Package.CommandList
module ExportedEnv = Package.ExportedEnv
module Env = Package.Env
module SourceResolver = EsyInstall.SourceResolver
module Overrides = EsyInstall.Package.Overrides

module Release = struct
  type t = {
    releasedBinaries: string list;
    deleteFromBinaryRelease: (string list [@default []]);
  } [@@deriving (of_yojson { strict = false })]
end

module Scripts = struct

  [@@@ocaml.warning "-32"]
  type script = {
    command : Command.t;
  }
  [@@deriving ord]

  type t =
    script StringMap.t
    [@@deriving ord]

  let empty = StringMap.empty

  let of_yojson =
    let script (json: Json.t) =
      match CommandList.of_yojson json with
      | Ok command ->
        begin match command with
        | [] -> Error "empty command"
        | [command] -> Ok {command;}
        | _ -> Error "multiple script commands are not supported"
        end
      | Error err -> Error err
    in
    Json.Decode.stringMap script

  let find (cmd: string) (scripts: t) = StringMap.find_opt cmd scripts
end

(* aliases for opam types with to_yojson implementations *)
module OpamTypes = struct
  type filter = OpamTypes.filter

  let filter_to_yojson filter = `String (OpamFilter.to_string filter)

  type command = arg list * filter option [@@deriving to_yojson]
  and arg = simple_arg * filter option
  and simple_arg = OpamTypes.simple_arg =
    | CString of string
    | CIdent of string
end

type commands =
  | OpamCommands of OpamTypes.command list
  | EsyCommands of CommandList.t
  [@@deriving to_yojson]

type patch = Path.t * OpamTypes.filter option

let patch_to_yojson (path, filter) =
  let filter =
    match filter with
    | None -> `Null
    | Some filter -> `String (OpamFilter.to_string filter)
  in
  `Assoc ["path", Path.to_yojson path; "filter", filter]

type t = {
  name : string;
  version : Version.t;
  buildType : BuildType.t;
  buildCommands : commands;
  installCommands : commands;
  patches : patch list;
  substs : Path.t list;
  exportedEnv : ExportedEnv.t;
  buildEnv : Env.t;
} [@@deriving to_yojson]

let empty name version = {
  name;
  version;
  buildType = BuildType.OutOfSource;
  buildCommands = EsyCommands [];
  installCommands = EsyCommands [];
  patches = [];
  substs = [];
  exportedEnv = ExportedEnv.empty;
  buildEnv = StringMap.empty;
}

module EsyBuild = struct
  type packageJson = {
    esy: packageJsonEsy option [@default None];
  } [@@deriving (of_yojson {strict = false})]

  and packageJsonEsy = {
    build: (CommandList.t [@default CommandList.empty]);
    install: (CommandList.t [@default CommandList.empty]);
    buildsInSource: (BuildType.t [@default BuildType.OutOfSource]);
    exportedEnv: (ExportedEnv.t [@default ExportedEnv.empty]);
    buildEnv: (Env.t [@default Env.empty]);
    sandboxEnv: (Env.t [@default Env.empty]);
    release: (Release.t option [@default None]);
  } [@@deriving (of_yojson { strict = false })]

  let ofFile ~name ~version (path : Path.t) =
    let open RunAsync.Syntax in
    let%bind json = Fs.readJsonFile path in
    let%bind pkgJson = RunAsync.ofRun (Json.parseJsonWith packageJson_of_yojson json) in
    match pkgJson.esy with
    | Some m ->
      let build = {
        name;
        version;
        buildType = m.buildsInSource;
        exportedEnv = m.exportedEnv;
        buildEnv = m.buildEnv;
        buildCommands = EsyCommands (m.build);
        installCommands = EsyCommands (m.install);
        patches = [];
        substs = [];
      } in
      return (Some (build, Path.Set.singleton path))
    | None -> return None
end

let parseOpam data =
  if String.trim data = ""
  then None
  else Some (OpamFile.OPAM.read_from_string data)

let readOpam path =
  let open RunAsync.Syntax in
  let%bind data = Fs.readFile path in
  let name = Path.(path |> remExt |> basename) in
  match parseOpam data with
  | Some opam -> return (Some (name, opam))
  | None -> return None

module OpamBuild = struct

  let build ~name ~version (manifest : Solution.Package.Opam.t) =
    let buildCommands =
      match manifest.override with
      | Some {EsyInstall.Package.OpamOverride. build = Some cmds; _} ->
        EsyCommands cmds
      | Some {EsyInstall.Package.OpamOverride. build = None; _}
      | None ->
        OpamCommands (OpamFile.OPAM.build manifest.opam)
    in

    let installCommands =
      match manifest.override with
      | Some {EsyInstall.Package.OpamOverride. install = Some cmds; _} ->
        EsyCommands cmds
      | Some {EsyInstall.Package.OpamOverride. install = None; _}
      | None ->
        OpamCommands (OpamFile.OPAM.install manifest.opam)
    in

    let patches =
      let patches = OpamFile.OPAM.patches manifest.opam in
      let f (name, filter) =
        let name = Path.v (OpamFilename.Base.to_string name) in
        (name, filter)
      in
      List.map ~f patches
    in

    let substs =
      let names = OpamFile.OPAM.substs manifest.opam in
      let f name = Path.v (OpamFilename.Base.to_string name) in
      List.map ~f names
    in

    let exportedEnv =
      match manifest.override with
      | Some {EsyInstall.Package.OpamOverride. exportedEnv;_} -> exportedEnv
      | None -> ExportedEnv.empty
    in

    {
      name;
      version;
      (* we assume opam installations are built in source *)
      buildType = BuildType.InSource;
      exportedEnv;
      buildEnv = Env.empty;
      buildCommands;
      installCommands;
      patches;
      substs;
    }

  let ofInstallationDir ~name ~version (path : Path.t) =
    let open RunAsync.Syntax in
    match%bind EsyInstall.EsyLinkFile.ofDirIfExists path with
    | None
    | Some { EsyInstall.EsyLinkFile. opam = None; _ } ->
      return None
    | Some { EsyInstall.EsyLinkFile. opam = Some info; _ } ->
      return (Some (build ~name ~version info, Path.Set.singleton path))

  let ofFile ~name ~version (path : Path.t) =
    let open RunAsync.Syntax in
    match%bind readOpam path with
    | None -> errorf "unable to load opam manifest at %a" Path.pp path
    | Some (_, opam) ->
      let info = {
        EsyInstall.Solution.Package.Opam.
        name = OpamPackage.Name.of_string name;
        version = OpamPackage.Version.of_string "unused";
        opam;
        override = None;
      } in
      return (Some (build ~name ~version info, Path.Set.singleton path))
end

let discoverManifest ~name ~version path =
  let open RunAsync.Syntax in

  let filenames =
    let dirname = Path.basename path in
    [
      `Esy, Path.v "esy.json";
      `Esy, Path.v "package.json";
      `Opam, Path.(v dirname |> addExt ".opam");
      `Opam, Path.v "opam";
    ]
  in

  let rec tryLoad = function
    | [] -> return None
    | (kind, fname)::rest ->
      let fname = Path.(path // fname) in
      if%bind Fs.exists fname
      then
        match kind with
        | `Esy -> EsyBuild.ofFile ~name ~version fname
        | `Opam -> OpamBuild.ofFile ~name ~version fname
      else tryLoad rest
  in

  tryLoad filenames

let ofDir ?manifest ~name ~version (path : Path.t) =
  let open RunAsync.Syntax in

  Logs_lwt.debug (fun m ->
    m "Manifest.ofDir %a %a"
    Fmt.(option ManifestSpec.Filename.pp) manifest
    Path.pp path
  );%lwt

  let manifest =
    match manifest with
    | None ->
      begin match%bind OpamBuild.ofInstallationDir ~name ~version path with
      | Some manifest -> return (Some manifest)
      | None -> discoverManifest ~name ~version path
      end
    | Some spec ->
      begin match spec with
      | ManifestSpec.Filename.Esy, fname ->
        let path = Path.(path / fname) in
        EsyBuild.ofFile ~name ~version path
      | ManifestSpec.Filename.Opam, fname ->
        let path = Path.(path / fname) in
        OpamBuild.ofFile ~name ~version path
      end
    in

    RunAsync.contextf manifest
      "reading package metadata from %a"
      Path.ppPretty path