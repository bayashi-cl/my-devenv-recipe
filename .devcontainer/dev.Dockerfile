FROM docker.io/library/debian:trixie

ARG USERNAME
SHELL ["/bin/bash", "-ec"]

RUN <<EOF
apt-get update
apt-get install -y sudo postgresql-client curl
rm -rf /var/lib/apt/lists/*
EOF

RUN <<EOF
groupadd --gid 1000 ${USERNAME}
useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash ${USERNAME}
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/${USERNAME}
chmod 440 /etc/sudoers.d/${USERNAME}
EOF

USER ${USERNAME}

RUN curl https://mise.run | sh
