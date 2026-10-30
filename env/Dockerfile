  # Environnement de build CCBDos : Debian 13 + mkosi 27
  FROM debian:trixie
  ARG MKOSI_REF=v27
  RUN apt-get update \
   && apt-get install -y --no-install-recommends ca-certificates git pipx \
   && rm -rf /var/lib/apt/lists/*
  RUN pipx install --global "git+https://github.com/systemd/mkosi@${MKOSI_REF}"
  WORKDIR /work
  ENTRYPOINT ["mkosi"]
