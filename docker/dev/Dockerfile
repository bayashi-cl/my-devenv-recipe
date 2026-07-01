FROM ubuntu:latest
ARG USERNAME=developer
SHELL ["/bin/bash", "-ec"]

RUN <<EOF
apt-get update
apt-get --yes --no-install-recommends install \
    curl ca-certificates sudo git xz-utils
rm -rf /var/lib/apt/lists/*
EOF

RUN <<EOF
usermod --login ${USERNAME} --home /home/${USERNAME} --move-home ubuntu
groupmod --new-name ${USERNAME} ubuntu
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}
chmod 0440 /etc/sudoers.d/${USERNAME}
EOF


USER ${USERNAME}
# Nix の single-user インストーラは $USER を参照する
ENV USER=${USERNAME}

# install Nix (single-user mode) and enable flakes
RUN <<EOF
sh <(curl -L https://nixos.org/nix/install) --no-daemon
mkdir -p ${HOME}/.config/nix
echo "experimental-features = nix-command flakes" > ${HOME}/.config/nix/nix.conf
EOF

# コンテナ全体・VS Code ターミナルで Nix のツールを使えるよう PATH を通す
ENV PATH=/home/${USERNAME}/.nix-profile/bin:${PATH}

# install dev tools defined in nix/flake.nix into the user profile
COPY --chown=${USERNAME}:${USERNAME} nix /home/${USERNAME}/.config/nix-tools
RUN <<EOF
source ${HOME}/.nix-profile/etc/profile.d/nix.sh
nix profile add ${HOME}/.config/nix-tools#devShell
# ビルド時にのみ必要だった store path を削除してイメージを小さくする
nix store gc
EOF


# configure
WORKDIR /workspace/my-devenv-recipe
COPY --chown=${USERNAME}:${USERNAME} dotfiles/.zshrc /home/${USERNAME}/.zshrc
