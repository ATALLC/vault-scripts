{
  description = "An over-engineered Hello World in bash";

  # Nixpkgs / NixOS version to use.
  inputs.nixpkgs.url = "nixpkgs/nixos-21.05";

  outputs = { self, nixpkgs }:
    let

      # to work with older version of flakes
      lastModifiedDate = self.lastModifiedDate or self.lastModified or "19700101";

      # Generate a user-friendly version number.
      version = builtins.substring 0 8 lastModifiedDate;

      # System types to support.
      supportedSystems = [ "x86_64-linux" "x86_64-darwin" "aarch64-linux" "aarch64-darwin" ];

      # Helper function to generate an attrset '{ x86_64-linux = f "x86_64-linux"; ... }'.
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Nixpkgs instantiated for supported system types.
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; overlays = [ self.overlay ]; });

    in

    {

      # A Nixpkgs overlay.
      overlay = final: prev: {

        get-approle-credentials = with final; stdenv.mkDerivation rec {
          name = "get-approle-credentials-${version}";

          unpackPhase = ":";

          buildPhase =
            ''
              cat > get-approle-credentials <<EOF
              #! $SHELL
              # Check that an approle name was provided
              if [ -z "\$1" ]; then
                echo "Usage: get-approle-credentials <approle_name>"
                exit 1
              fi

              # Set the approle name
              approle_name=\$1

              # Prompt for Vault login
              echo "Please login to Vault..."
              ${pkgs.vault}/bin/vault login || { echo "Vault login failed."; exit 1; }


              # Check that login was successful
              if [ \$? -ne 0 ]; then
                echo "Vault login failed."
                exit 1
              fi

              sudo mkdir -p /var/lib/vault/\$approle_name
              sudo chmod -R 777 /var/lib/vault/\$approle_name

              # Retrieve and save the role-id
              role_id=\$(${pkgs.vault}/bin/vault read -field=role_id auth/approle/role/\$approle_name/role-id)
              echo \$role_id > /var/lib/vault/\$approle_name/role-id

              # Retrieve and save the secret-id
              secret_id=\$(${pkgs.vault}/bin/vault write -f -field=secret_id auth/approle/role/\$approle_name/secret-id)
              echo \$secret_id > /var/lib/vault/\$approle_name/secret-id

              sudo chmod -R 0400 /var/lib/vault/\$approle_name
              echo "AppRole credentials saved to '/var/lib/vault/\$approle_name/role-id' and '/var/lib/vault/\$approle_name/secret-id'."
              EOF
              chmod +x get-approle-credentials
            '';

          installPhase =
            ''
              mkdir -p $out/bin
              cp get-approle-credentials $out/bin/
            '';
        };

      };

      # Provide some binary packages for selected system types.
      packages = forAllSystems (system:
        {
          inherit (nixpkgsFor.${system}) get-approle-credentials;
        });

      # The default package for 'nix build'. This makes sense if the
      # flake provides only one package or there is a clear "main"
      # package.
      defaultPackage = forAllSystems (system: self.packages.${system}.get-approle-credentials);

      # A NixOS module, if applicable (e.g. if the package provides a system service).
      nixosModules.get-approle-credentials =
        { pkgs, ... }:
        {
          nixpkgs.overlays = [ self.overlay ];

          environment.systemPackages = [ pkgs.get-approle-credentials ];

          #systemd.services = { ... };
        };

      # Tests run by 'nix flake check' and by Hydra.
      checks = forAllSystems
        (system:
          with nixpkgsFor.${system};

          {
            inherit (self.packages.${system}) get-approle-credentials;

            # Additional tests, if applicable.
            test = stdenv.mkDerivation {
              name = "get-approle-credentials-test-${version}";

              buildInputs = [ get-approle-credentials ];

              unpackPhase = "true";

              buildPhase = ''
                echo 'running some integration tests'
                [[ $(get-approle-credentials) = 'Hello Nixers!' ]]
              '';

              installPhase = "mkdir -p $out";
            };
          }

          // lib.optionalAttrs stdenv.isLinux {
            # A VM test of the NixOS module.
            vmTest =
              with import (nixpkgs + "/nixos/lib/testing-python.nix") {
                inherit system;
              };

              makeTest {
                nodes = {
                  client = { ... }: {
                    imports = [ self.nixosModules.get-approle-credentials ];
                  };
                };

                testScript =
                  ''
                    start_all()
                    client.wait_for_unit("multi-user.target")
                    client.succeed("get-approle-credentials")
                  '';
              };
          }
        );

    };
}
