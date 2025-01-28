let
  pkgs = import <nixpkgs> { };
in
pkgs.mkShell {
  nativeBuildInputs = with pkgs; [
    zls
    zig
    typescript-language-server
    vscode-langservers-extracted
    python3
    wabt
    gdb
  ];
}
