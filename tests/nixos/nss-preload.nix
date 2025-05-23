{
  lib,
  config,
  nixpkgs,
  ...
}:

let

  pkgs = config.nodes.client.nixpkgs.pkgs;

  nix-fetch = pkgs.writeText "fetch.nix" ''
    derivation {
        # This derivation is an copy from what is available over at
        # nix.git:corepkgs/fetchurl.nix
        builder = "builtin:fetchurl";

        # We're going to fetch data from the http_dns instance created before
        # we expect the content to be the same as the content available there.
        # ```
        # $ nix-hash --type sha256 --to-base32 $(echo "hello world" | sha256sum | cut -d " " -f 1)
        # 0ix4jahrkll5zg01wandq78jw3ab30q4nscph67rniqg5x7r0j59
        # ```
        outputHash = "0ix4jahrkll5zg01wandq78jw3ab30q4nscph67rniqg5x7r0j59";
        outputHashAlgo = "sha256";
        outputHashMode = "flat";

        name = "example.com";
        url = "http://example.com";

        unpack = false;
        executable = false;

        system = "builtin";

        preferLocalBuild = true;

        impureEnvVars = [
            "http_proxy" "https_proxy" "ftp_proxy" "all_proxy" "no_proxy"
            "HTTP_PROXY" "HTTPS_PROXY" "FTP_PROXY" "ALL_PROXY" "NO_PROXY"
        ];

        urls = [ "http://example.com" ];
      }
  '';
in

{
  name = "nss-preload";

  nodes = {
    http_dns =
      {
        lib,
        pkgs,
        config,
        ...
      }:
      {
        networking.firewall.enable = false;
        networking.interfaces.eth1.ipv6.addresses = lib.mkForce [
          {
            address = "fd21::1";
            prefixLength = 64;
          }
        ];
        networking.interfaces.eth1.ipv4.addresses = lib.mkForce [
          {
            address = "192.168.0.1";
            prefixLength = 24;
          }
        ];

        services.unbound = {
          enable = true;
          enableRootTrustAnchor = false;
          settings = {
            server = {
              interface = [
                "192.168.0.1"
                "fd21::1"
                "::1"
                "127.0.0.1"
              ];
              access-control = [
                "192.168.0.0/24 allow"
                "fd21::/64 allow"
                "::1 allow"
                "127.0.0.0/8 allow"
              ];
              local-data = [
                ''"example.com. IN A 192.168.0.1"''
                ''"example.com. IN AAAA fd21::1"''
                ''"tarballs.nixos.org. IN A 192.168.0.1"''
                ''"tarballs.nixos.org. IN AAAA fd21::1"''
              ];
            };
          };
        };

        services.nginx = {
          enable = true;
          virtualHosts."example.com" = {
            root = pkgs.runCommand "testdir" { } ''
              mkdir "$out"
              echo hello world > "$out/index.html"
            '';
          };
        };
      };

    # client consumes a remote resolver
    client =
      {
        lib,
        nodes,
        pkgs,
        ...
      }:
      {
        networking.useDHCP = false;
        networking.nameservers = [
          (lib.head nodes.http_dns.networking.interfaces.eth1.ipv6.addresses).address
          (lib.head nodes.http_dns.networking.interfaces.eth1.ipv4.addresses).address
        ];
        networking.interfaces.eth1.ipv6.addresses = [
          {
            address = "fd21::10";
            prefixLength = 64;
          }
        ];
        networking.interfaces.eth1.ipv4.addresses = [
          {
            address = "192.168.0.10";
            prefixLength = 24;
          }
        ];

        nix.settings.extra-sandbox-paths = lib.mkForce [ ];
        nix.settings.substituters = lib.mkForce [ ];
        nix.settings.sandbox = lib.mkForce true;
      };
  };

  testScript =
    { nodes, ... }:
    ''
      http_dns.wait_for_unit("network-addresses-eth1.service")
      http_dns.wait_for_unit("nginx")
      http_dns.wait_for_open_port(80)
      http_dns.wait_for_unit("unbound")
      http_dns.wait_for_open_port(53)

      client.start()
      client.wait_for_unit('multi-user.target')
      client.wait_for_unit('network-addresses-eth1.service')

      with subtest("can fetch data from a remote server outside sandbox"):
          client.succeed("nix --version >&2")
          client.succeed("curl -vvv http://example.com/index.html >&2")

      with subtest("nix-build can lookup dns and fetch data"):
          client.succeed("""
            nix-build ${nix-fetch} >&2
            """)
    '';
}
