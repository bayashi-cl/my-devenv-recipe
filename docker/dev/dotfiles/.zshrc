# Nix
if [ -e "${HOME}/.nix-profile/etc/profile.d/nix.sh" ]; then
  source "${HOME}/.nix-profile/etc/profile.d/nix.sh"
fi
# pure など Nix で入れた zsh 関数を補完・プロンプトで使えるようにする
fpath=("${HOME}/.nix-profile/share/zsh/site-functions" $fpath)

autoload -U promptinit; promptinit
zstyle ':prompt:pure:prompt:success' color green
prompt pure

autoload -Uz compinit && compinit
zstyle ':completion:*' menu select
zstyle ':completion:*' matcher-list 'm:{a-z}={A-Z}' 'r:|=*' 'l:|=* r:|=*'
zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'
zstyle ':completion:*:warnings' format '%F{red}-- no matches --%f'

HISTFILE="${HOME}/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000

setopt share_history
setopt hist_ignore_dups
setopt hist_ignore_space
setopt hist_reduce_blanks
setopt hist_verify

setopt auto_cd
setopt auto_pushd
setopt pushd_ignore_dups
setopt correct
setopt no_beep
setopt extended_glob
setopt glob_dots

path=(
  "${HOME}/.local/bin"
  "${HOME}/bin"
  $path
)
typeset -U path

export TERM="xterm-256color"
