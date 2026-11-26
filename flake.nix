{
  description = "CodeRed Fleet: managed NixOS desktops that look like Windows";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    disko.url = "github:nix-community/disko/latest";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = {
    self,
    nixpkgs,
    disko,
  }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
    inherit (nixpkgs) lib;
  in {
    lib = {
      # A NixOS module declaring every user: <prefix>1..<prefix>N for each entry
      # in `generate`, plus one user per folder `dir/<name>/default.nix` (an
      # attrset merged over the generated defaults, so it can override them).
      mkUsers = {
        generate ? {},
        dir ? null,
      }: let
        # Normal, non-admin accounts. Homes are made at first login
        # (pam_mkhomedir), not for every account on every PC at activation.
        defaults = {
          isNormalUser = true;
          createHome = false;
        };
        generated = lib.concatMapAttrs (prefix: count:
          lib.genAttrs (lib.genList (i: "${prefix}${toString (i + 1)}") count) (_: {}))
        generate;
        folders = lib.optionalAttrs (dir != null) (
          lib.mapAttrs (name: _: import (dir + "/${name}"))
          (lib.filterAttrs (_: type: type == "directory") (builtins.readDir dir))
        );
      in {
        users.users = lib.mapAttrs (_: user: defaults // user) (generated // folders);
        security.pam.services = lib.genAttrs ["login" "su" "sshd"] (_: {makeHomeDir = true;});
      };

      # One nixosSystem per group of PCs (never per PC): every machine in a
      # group shares one closure; its name and identity come at enrolment.
      #
      # `settings` is the data a panel writes (fleet-settings.json, see README "Settings"):
      # it is validated, then applied to every group at normal priority, so a group's own
      # `modules` still win (with mkForce where they need to beat another normal-priority value).
      mkFleet = {
        groups,
        users ? {},
        rev ? null,
        settings ? {},
      }: let
        fail = msg: throw "mkFleet: fleet-settings: ${msg}";
        known = ["homepage" "usbStorage" "timezone" "wifi" "printers" "generate"];
        isStr = builtins.isString;
        entryOf = fields: where: e:
          if !(builtins.isAttrs e)
          then fail "`${where}` must be an object"
          else
            (map (f:
              if !(e ? ${f}) || !(isStr e.${f})
              then fail "`${where}.${f}` must be a string"
              else null)
            fields)
            ++ (map (k:
              if !(builtins.elem k fields)
              then fail "`${where}` has unknown key `${k}`"
              else null)
            (builtins.attrNames e));
        listOf = key: fields:
          if !(builtins.isList settings.${key})
          then fail "`${key}` must be a list"
          else lib.imap0 (i: entryOf fields "${key}[${toString i}]") settings.${key};
        validated =
          builtins.deepSeq [
            (
              if !(builtins.isAttrs settings)
              then fail "must be an object"
              else
                map (k:
                  if builtins.elem k known
                  then null
                  else fail "unknown key `${k}` (known: ${lib.concatStringsSep ", " known})") (builtins.attrNames settings)
            )
            (map (k:
              if settings ? ${k} && !(isStr settings.${k})
              then fail "`${k}` must be a string"
              else null) ["homepage" "timezone"])
            (lib.optional (settings ? usbStorage && !(builtins.isBool settings.usbStorage)) (fail "`usbStorage` must be true or false"))
            (lib.optionals (settings ? wifi) (listOf "wifi" ["ssid" "psk"]))
            (lib.optionals (settings ? printers) (listOf "printers" ["name" "uri"]))
            (lib.optionals (settings ? printers) (map (p:
              if builtins.match "[A-Za-z0-9_-]+" p.name == null
              then fail "printer name `${p.name}` is not CUPS-safe (letters, digits, _ and - only)"
              else null)
            settings.printers))
            (lib.optional (settings ? generate && !(builtins.isAttrs settings.generate && lib.all (n: builtins.isInt n && n >= 0) (builtins.attrValues settings.generate)))
              (fail "`generate` must map a prefix to a non-negative count, e.g. {\"student\": 30}"))
          ]
          null;
        settingsModule.config = lib.mkMerge [
          (lib.optionalAttrs (settings ? homepage) {programs.firefox.policies.Homepage.URL = settings.homepage;})
          (lib.optionalAttrs (settings ? usbStorage) {codered.fleet.school.allowUsbStorage = settings.usbStorage;})
          (lib.optionalAttrs (settings ? timezone) {time.timeZone = settings.timezone;})
          (lib.optionalAttrs (settings ? wifi) {
            networking.networkmanager.ensureProfiles.profiles = builtins.listToAttrs (map (w:
              lib.nameValuePair w.ssid {
                connection = {
                  id = w.ssid;
                  type = "wifi";
                  autoconnect = true;
                };
                wifi = {
                  ssid = w.ssid;
                  mode = "infrastructure";
                };
                wifi-security = {
                  key-mgmt = "wpa-psk";
                  psk = w.psk;
                };
                ipv4.method = "auto";
                ipv6.method = "auto";
              })
            settings.wifi);
          })
          (lib.optionalAttrs (settings ? printers && settings.printers != []) {
            services.printing.enable = true;
            hardware.printers.ensurePrinters =
              map (p: {
                name = p.name;
                deviceUri = p.uri;
                model = "everywhere";
              })
              settings.printers;
          })
        ];
        allUsers = users // {generate = (users.generate or {}) // (settings.generate or {});};
      in
        builtins.seq validated
        lib.mapAttrs (name: group:
          lib.nixosSystem {
            modules =
              [
                disko.nixosModules.disko
                ./modules/base.nix
                self.nixosModules.agent
                self.nixosModules.fallback
                self.nixosModules.${group.profile}
                (self.lib.mkUsers allUsers)
                settingsModule
                {
                  codered.fleet.agent.group = name;
                  codered.fleet.fallback.enable = lib.mkDefault true;
                  codered.fleet.agent.profile = lib.mkDefault group.profile;
                  system.configurationRevision = lib.mkIf (rev != null) rev;
                }
              ]
              ++ group.modules or [];
          })
        groups;
    };

    nixosModules = {
      agent = ./modules/agent.nix;
      desktop = ./modules/desktop.nix;
      directory = ./modules/directory.nix;
      fallback = ./modules/fallback.nix;
      hardening = ./modules/hardening.nix;
      school = ./modules/school.nix;
    };

    templates.school = {
      path = ./examples/school;
      description = "A school's fleet: lab and library PCs, students from a loop, staff from folders";
    };

    packages.${system} = {
      # `nix run .#new-user -- <name>` in a customer's fleet repo: one folder per person.
      new-user = pkgs.writeShellApplication {
        name = "new-user";
        text = ''
          name=''${1:-}
          if [[ ! $name =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
            echo "usage: nix run .#new-user -- <name>   (lower-case letters, digits, - and _)" >&2
            exit 1
          fi
          [[ -f flake.nix && -d users ]] || { echo "run this from your fleet repo (next to flake.nix and users/)" >&2; exit 1; }
          dir=users/$name
          [[ ! -e $dir ]] || { echo "$dir already exists" >&2; exit 1; }
          mkdir "$dir"
          cat > "$dir/default.nix" <<EOF
          # $name: merged into users.users.$name on every PC in the fleet.
          {
            description = "$name";
            # extraGroups = ["wheel"]; # uncomment to make $name an administrator
          }
          EOF
          echo "Created $dir/default.nix. Edit it, then: git add $dir && git commit"
        '';
      };

      # demo-lab as a raw UEFI disk (main.raw): systemd-boot and its own /nix/store.
      demo-image = self.nixosConfigurations.demo-lab.config.system.build.diskoImages;
    };

    # The school image as a QEMU VM. Demo password only here, never in lib.
    nixosConfigurations.school-vm =
      (self.lib.mkFleet {
        rev = self.rev or self.dirtyRev or null;
        groups.lab = {
          profile = "school";
          modules = [
            {
              networking.hostName = "school-vm";
              users.users = lib.genAttrs ["student1" "teacher1" "itadmin"] (_: {initialPassword = "demo";});
              # Reports to the live panel. The enrol token is read at runtime from the host's
              # $SHARED_DIR (mounted at /tmp/shared), so it never enters git or the store.
              codered.fleet.agent = {
                enable = true;
                url = "https://fleet.codered.lol";
                enrollTokenFile = "/tmp/shared/enroll-token";
              };
              virtualisation.vmVariant.virtualisation = {
                memorySize = 4096;
                cores = 2;
              };
            }
          ];
        };
        users = {
          generate.student = 30;
          dir = ./examples/school/users;
        };
      }).lab;

    # A demo PC installed on a disk (`demo-image`), so it can boot into an update the panel rolls
    # out. Its group is also its name, so `github:chowe99/fleet?rev=<any>#demo-lab` is what the
    # agent builds. Demo password and the 2-minute poll only here, never in lib or modules.
    nixosConfigurations.demo-lab =
      (self.lib.mkFleet {
        rev = self.rev or self.dirtyRev or null;
        groups.demo-lab = {
          profile = "school";
          modules = [
            {
              networking.hostName = "demo-lab-01";
              codered.fleet.hardening.level = "intermediary";
              users.users = lib.genAttrs ["student1" "teacher1" "itadmin"] (_: {initialPassword = "demo";});
              # The enrol token comes in over QEMU fw_cfg
              # (-fw_cfg name=opt/codered/enroll-token,file=<token>), so it never enters git or the store.
              boot.kernelModules = ["qemu_fw_cfg"];
              codered.fleet.agent = {
                enable = true;
                url = "https://fleet.codered.lol";
                enrollTokenFile = "/sys/firmware/qemu_fw_cfg/by_name/opt/codered/enroll-token/raw";
                flake = "github:chowe99/fleet";
              };
              systemd.timers.fleet-agent.timerConfig.OnUnitActiveSec = lib.mkForce "2min";
              # Bump this to make a new version to roll out (README: "See an update roll out").
              environment.etc."fleet-release".text = "demo-lab 3\n";
              # Sparse; room for the next generation's store paths.
              disko.devices.disk.main.imageSize = "24G";
            }
          ];
        };
        users = {
          generate.student = 30;
          dir = ./examples/school/users;
        };
      }).demo-lab;

    apps.${system} = {
      new-user = {
        type = "app";
        program = lib.getExe self.packages.${system}.new-user;
      };
      school-vm = {
        type = "app";
        # A host session that exports LD_LIBRARY_PATH (e.g. for JACK) makes QEMU load libraries
        # built against a different glibc, so drop it.
        program = toString (pkgs.writeShellScript "school-vm" ''
          unset LD_LIBRARY_PATH
          exec ${lib.getExe self.nixosConfigurations.school-vm.config.system.build.vm} "$@"
        '');
      };
    };

    checks.${system} = {
      fleet = import ./tests/fleet.nix {inherit self pkgs;};
      school = import ./tests/school.nix {inherit self pkgs;};
      agent-hardware = import ./tests/agent-hardware.nix {inherit self pkgs;};
      agent-actions = import ./tests/agent-actions.nix {inherit self pkgs;};
      settings = import ./tests/settings.nix {inherit self pkgs;};
      agent-config-fetch = import ./tests/agent-config-fetch.nix {inherit self pkgs;};
      hardening = import ./tests/hardening.nix {inherit self pkgs;};
      directory = import ./tests/directory.nix {inherit self pkgs;};
      fallback = import ./tests/fallback.nix {inherit self pkgs;};
    };
  };
}
