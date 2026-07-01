{
  description = "my-devenv-recipe dev tools";

  inputs = {
    # 全ツールを最新へ追従させるため unstable チャンネルを参照する
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      # Apple Silicon (aarch64) もサポート
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

      pkgsFor =
        system:
        import nixpkgs {
          inherit system;
          # claude-code は unfree ライセンス扱いのため許可する
          config.allowUnfree = true;
        };
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
        in
        {
          # 旧 Brewfile に対応する開発ツール一式を 1 つの環境にまとめる
          devShell = pkgs.buildEnv {
            name = "devcontainer-tools";
            paths = with pkgs; [
              deno # Secure runtime for JavaScript and TypeScript
              fd # Simple, fast and user-friendly alternative to find
              fzf # Command-line fuzzy finder written in Go
              gh # GitHub command-line tool
              git # Distributed revision control system
              lazygit # Simple terminal UI for git commands
              neovim # Ambitious Vim-fork focused on extensibility and agility
              zsh # UNIX shell (command interpreter)
              pure-prompt # Pretty, minimal and fast ZSH prompt
              ripgrep # Search tool like grep and The Silver Searcher
              uv # Extremely fast Python package installer and resolver
              claude-code # Terminal-based AI coding assistant
              less # Terminal pager
              jq # Command-line JSON processor
              postgresql # PostgreSQL client tools
            ];
          };

          default = self.packages.${system}.devShell;
        }
      );
    };
}
