# services.owly: owlyd, Owly's radio service, and the owly CLI.
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.owly;
  # The interfaces a session creates (packaging/90-owly-unmanaged.conf).
  ifaces = [
    "awdl0"
    "owlymon0"
    "owlyibss0"
    "owlyap0"
  ];
  toml = pkgs.formats.toml { };
in
{
  imports = [ ./omdrop-owl.nix ];

  options.services.owly = {
    enable = lib.mkEnableOption "Owly, AirDrop's Wi-Fi radio: owlyd and the owly CLI";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.callPackage ./package.nix { };
      defaultText = lib.literalExpression "pkgs.callPackage ./package.nix { }";
      description = "The owly package to use.";
    };

    settings = lib.mkOption {
      inherit (toml) type;
      default = { };
      example = {
        station = "wlp1s0";
        allow_untested = true;
        channels = [ 149 ];
      };
      description = "/etc/owly/radio.toml: how the radio is set up on this machine. See crates/owly-radio/src/config.rs for the keys.";
    };

    drivers = lib.mkOption {
      inherit (toml) type;
      default = { };
      example = {
        devices."14c3:7927" = {
          status = "tested";
          mode = "exclusive";
          channels = [ 6 ];
        };
      };
      description = "/etc/owly/drivers.toml: per-card quirk overrides on top of the built-in table. See crates/owly-radio/drivers.toml for the shape.";
    };

    openFirewall = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Open TCP 8771, where `owly receive` listens, on awdl0.";
    };

    receive = {
      enable = lib.mkEnableOption "a user service that holds the radio and takes AirDrops for the whole graphical session";

      dir = lib.mkOption {
        type = lib.types.str;
        default = "%h/Downloads";
        description = "Where received files go. systemd specifiers such as %h (home) are expanded.";
      };

      mode = lib.mkOption {
        type = lib.types.enum [
          "notify"
          "accept"
        ];
        default = "notify";
        description = "notify: ask through a desktop notification, click to accept. accept: take everything without asking.";
      };

      askTimeout = lib.mkOption {
        type = lib.types.ints.unsigned;
        default = 60;
        description = "In notify mode, seconds to wait for an answer before declining.";
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [
          "--iface"
          "awdl0"
        ];
        description = "Extra arguments passed to `owly receive`.";
      };

      polkit = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = ''
          Install a polkit rule letting members of {option}`services.owly.receive.polkitGroup`
          acquire the radio without an admin prompt. An unattended user service is not an active
          logind session, so without this the service's Acquire falls through to auth_admin and
          fails with no agent to answer it. Turning this on lets those users turn the radio on for
          AirDrop (which in exclusive mode takes Wi-Fi down) without authenticating.
        '';
      };

      polkitGroup = lib.mkOption {
        type = lib.types.str;
        default = "users";
        description = "The group the receive polkit rule grants radio access to.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];
    # owlyd's unit, and its D-Bus name, policy and activation file. D-Bus
    # starts it on the first call.
    systemd.packages = [ cfg.package ];
    services.dbus.packages = [ cfg.package ];
    security.polkit.enable = true;
    # owly send wakes Apple receivers with a BLE advert through BlueZ;
    # without it, sending reaches only phones already listening.
    hardware.bluetooth.enable = lib.mkDefault true;

    # What owlyd runs: nmcli to release and reconnect the station, from the
    # system's NetworkManager (an nmcli newer than the daemon can't release
    # it, "No such method SetManaged"); ip and ping for shared mode's check
    # that Wi-Fi passes traffic; mount for debugfs.
    systemd.services.owlyd.path = [
      config.networking.networkmanager.package
      pkgs.iproute2
      pkgs.iputils
      pkgs.util-linux
    ];

    environment.etc."owly/radio.toml" = lib.mkIf (cfg.settings != { }) {
      source = toml.generate "radio.toml" cfg.settings;
    };

    environment.etc."owly/drivers.toml" = lib.mkIf (cfg.drivers != { }) {
      source = toml.generate "drivers.toml" cfg.drivers;
    };

    systemd.user.services.owly-receive = lib.mkIf cfg.receive.enable {
      description = "Receive AirDrops with owly";
      partOf = [ "graphical-session.target" ];
      after = [ "graphical-session.target" ];
      wantedBy = [ "graphical-session.target" ];
      serviceConfig = {
        ExecStart =
          let
            r = cfg.receive;
            args =
              [
                "receive"
                "--radio"
                "--dir"
                r.dir
              ]
              ++ (
                if r.mode == "accept" then
                  [ "--accept" ]
                else
                  [
                    "--notify"
                    "--ask-timeout"
                    (toString r.askTimeout)
                  ]
              )
              ++ r.extraArgs;
          in
          "${lib.getExe' cfg.package "owly"} ${lib.escapeShellArgs args}";
        Restart = "on-failure";
        RestartSec = 5;
      };
      unitConfig = {
        StartLimitIntervalSec = 300;
        StartLimitBurst = 3;
      };
    };

    security.polkit.extraConfig = lib.mkIf (cfg.receive.enable && cfg.receive.polkit) ''
      polkit.addRule(function(action, subject) {
        if (action.id == "io.github.t4t5.Owly.acquire" &&
            subject.isInGroup("${cfg.receive.polkitGroup}")) {
          return polkit.Result.YES;
        }
      });
    '';

    networking.networkmanager.unmanaged = map (i: "interface-name:${i}") ifaces;
    networking.firewall.interfaces.awdl0.allowedTCPPorts = lib.mkIf cfg.openFirewall [ 8771 ];

    # packaging/10-owly-awdl0.link: udev must not give awdl0 a MAC address
    # of its own (AWDL-2).
    systemd.network.links."10-owly-awdl0" = {
      matchConfig.OriginalName = "awdl0";
      linkConfig.MACAddressPolicy = "none";
    };

    # NixOS restarts wpa_supplicant whenever a Wi-Fi interface comes or goes,
    # which drops the connection each time a session's monitor interface
    # does.
    services.udev.packages = [
      (pkgs.writeTextDir "lib/udev/rules.d/00-owly.rules" ''
        SUBSYSTEM=="net", KERNEL=="${lib.concatStringsSep "|" ifaces}", RUN:="${pkgs.coreutils}/bin/true"
      '')
    ];
  };
}
