# Build CCBDos : sur le serveur ccbd, ou en local dans Docker.
#   just build           -> build en local, dans Docker
#   just build srv       -> build sur le serveur ccbd
#   just fetch           -> télécharge l'image du dernier build serveur
#   just all             -> build serveur + téléchargement
#   just vm              -> démarre la VM en local (Docker + KVM)
#   just virtualize      -> (re)crée et démarre la VM, premier démarrage prérempli (test du build)
#   just virtualize install -> idem, mais l'assistant de premier démarrage pose ses questions
#   just view            -> ouvre l'écran de la VM (fenêtre virt-viewer)
#   just connect         -> ouvre la console série de la VM (Ctrl-] pour sortir)
#   just ssh             -> se connecte en SSH (root) à la VM

set shell := ["bash", "-euo", "pipefail", "-c"]

# libvirt (même réglages que le prototype roddhjav/server)
virsh_c  := "--connect=qemu:///system"
vm_name  := "os-ccbdos"
vm_dir   := home_dir() / ".vm"
vm_ram   := "4096"
vm_cpus  := "4"
vm_disk  := "16G"

# Réponses à systemd-firstboot en mode test (credentials systemd passés à la VM)
fb_hostname := "ccbdos"
fb_locale   := "C.UTF-8"
fb_keymap   := "fr"
fb_timezone := "Europe/Paris"

# SSH : la clé publique est injectée dans la VM à sa création (credential systemd), pas dans l'image
ssh_key  := home_dir() / ".ssh/id_ed25519"
# VM recréée à chaque fois : on n'enregistre pas sa clé d'hôte
ssh_opt  := "-i " + ssh_key + " -o IdentitiesOnly=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o LogLevel=ERROR"

# Serveur
remote := "ccbd"          # alias SSH défini dans ~/.ssh/config
rdir   := "ccbdos"        # dossier de travail dans le home du serveur

# Docker
image  := "ccbdos-build"
docker := "docker run --rm --privileged -v \"$PWD\":/work"

out    := "mkosi.output"
stamp  := `date +%F_%H-%M-%S`

default:
    @just --list

# Build de l'image : where = docker (défaut) ou srv (serveur ccbd)
build where="docker":
    just build-{{where}}

# Build serveur puis téléchargement
all: build-srv fetch

# --- Serveur ---------------------------------------------------------------

# Envoie le dossier de travail (sans .git ni fichiers ignorés par git)
sync:
    rsync -az --delete --exclude .git --filter=':- .gitignore' ./ {{remote}}:{{rdir}}/

# Build sur le serveur, log horodaté en local
build-srv: sync
    mkdir -p logs
    ssh {{remote}} 'cd {{rdir}} && mkosi -B -f build' 2>&1 | tee "logs/{{stamp}}_build-srv.log"

# Télécharge le dernier build serveur (image compressée en zstd pour le transfert)
fetch:
    #!/usr/bin/env bash
    set -euo pipefail
    v=$(ssh {{remote}} 'cat {{rdir}}/mkosi.version')
    echo "Version : $v"
    ssh {{remote}} "cd {{rdir}}/{{out}} && for f in *_${v}_*.raw; do zstd -T0 -3 -f -q \"\$f\"; done"
    mkdir -p {{out}}
    rsync -a --info=progress2 --exclude '*.raw' "{{remote}}:{{rdir}}/{{out}}/*_${v}_*" {{out}}/
    for f in {{out}}/*_${v}_*.raw.zst; do zstd -d -f -q --rm "$f"; done
    echo "$v" > mkosi.version
    ls -lsh {{out}}/*_${v}_*

# --- Docker ----------------------------------------------------------------

# Image Docker de build (instantané si env/Dockerfile n'a pas changé)
docker-image:
    docker build -t {{image}} env/

# Build en local dans Docker, log horodaté
build-docker: docker-image
    mkdir -p logs
    {{docker}} {{image}} -B -f build 2>&1 | tee "logs/{{stamp}}_build-docker.log"
    docker run --rm -v "$PWD":/work --entrypoint chown {{image}} -R "$(id -u):$(id -g)" {{out}} mkosi.version .mkosi-private

# --- libvirt ---------------------------------------------------------------

# (Re)crée et démarre la VM depuis la dernière image : mode = test (premier démarrage prérempli) ou install (questions)
virtualize mode="test":
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "{{mode}}" == test || "{{mode}}" == install ]] || { echo "Mode inconnu '{{mode}}' : test ou install" >&2; exit 1; }
    img=$(find {{out}} -maxdepth 1 -type f -name 'CCBDos_*_x86-64.raw' -printf '%T@ %p\n' | sort -rn | head -1 | cut -d' ' -f2-)
    [[ -n "$img" ]] || { echo "Aucune image dans {{out}} : lancer 'just build' ou 'just fetch'" >&2; exit 1; }
    echo "Image : $img"
    # Supprime la VM précédente (et ses variables EFI) si elle existe
    if virsh {{virsh_c}} dominfo {{vm_name}} &>/dev/null; then
        virsh {{virsh_c}} destroy {{vm_name}} &>/dev/null || true
        virsh {{virsh_c}} undefine {{vm_name}} --nvram
    fi
    # Copie de travail dans ~/.vm : l'image de build reste intacte
    mkdir -p {{vm_dir}}
    cp --sparse=always "$img" {{vm_dir}}/{{vm_name}}.raw
    truncate -s {{vm_disk}} {{vm_dir}}/{{vm_name}}.raw
    # Credentials systemd transmis via SMBIOS : clé SSH toujours, réponses de firstboot en mode test
    creds=("ssh.authorized_keys.root=$(cat {{ssh_key}}.pub)")
    if [[ "{{mode}}" == test ]]; then
        creds+=("system.hostname={{fb_hostname}}" "firstboot.locale={{fb_locale}}"
                "firstboot.keymap={{fb_keymap}}" "firstboot.timezone={{fb_timezone}}")
    fi
    sysinfo="type=smbios"
    for i in "${!creds[@]}"; do sysinfo+=",oemStrings.entry$i=io.systemd.credential:${creds[$i]}"; done
    virt-install {{virsh_c}} \
        --import \
        --name {{vm_name}} \
        --vcpus {{vm_cpus}} \
        --ram {{vm_ram}} \
        --machine q35 \
        --boot uefi,firmware.feature0.name=secure-boot,firmware.feature0.enabled=no \
        --disk "path={{vm_dir}}/{{vm_name}}.raw,format=raw,bus=virtio" \
        --os-variant debian13 \
        --network network=default \
        --graphics spice \
        --video virtio \
        --channel spicevmc \
        --console pty,target_type=serial \
        --sysinfo "$sysinfo" \
        --noautoconsole
    if [[ "{{mode}}" == install ]]; then
        echo "VM {{vm_name}} démarrée : l'assistant de premier démarrage s'affiche dans la fenêtre"
        just view
    else
        echo "VM {{vm_name}} démarrée : 'just connect' ou 'just ssh' pour s'y connecter"
    fi

# Ouvre l'écran de la VM dans une fenêtre virt-viewer (détachée du terminal)
view:
    #!/usr/bin/env bash
    set -euo pipefail
    virsh {{virsh_c}} dominfo {{vm_name}} &>/dev/null || { echo "Pas de VM {{vm_name}} : lancer 'just virtualize'" >&2; exit 1; }
    if command -v virt-viewer &>/dev/null; then viewer=(virt-viewer)
    else viewer=(nix shell nixpkgs#virt-viewer --command virt-viewer); fi
    setsid -f "${viewer[@]}" {{virsh_c}} --wait {{vm_name}} &>/dev/null

# Ouvre la console série de la VM, en la démarrant si elle est arrêtée (Ctrl-] pour sortir)
connect:
    #!/usr/bin/env bash
    set -euo pipefail
    virsh {{virsh_c}} dominfo {{vm_name}} &>/dev/null || { echo "Pas de VM {{vm_name}} : lancer 'just virtualize'" >&2; exit 1; }
    [[ $(virsh {{virsh_c}} domstate {{vm_name}}) == running ]] || virsh {{virsh_c}} start {{vm_name}}
    exec virsh {{virsh_c}} console {{vm_name}}

# Se connecte en SSH (root) à la VM, via son adresse sur le réseau libvirt "default"
ssh:
    #!/usr/bin/env bash
    set -euo pipefail
    ip=$(virsh --quiet {{virsh_c}} domifaddr {{vm_name}} --source lease | grep -Eo '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1 || true)
    [[ -n "$ip" ]] || { echo "Pas d'adresse IP pour {{vm_name}} : VM démarrée ? (just virtualize)" >&2; exit 1; }
    exec ssh {{ssh_opt}} root@"$ip"

# Démarre la VM en local (KVM de l'hôte), quel que soit l'endroit du build
vm: docker-image
    {{docker}} -it --device /dev/kvm {{image}} vm

# Shell dans le conteneur, pour déboguer
shell: docker-image
    {{docker}} -it --entrypoint bash {{image}}

# Supprime sorties, cache et outillage locaux (créés en root par le conteneur)
clean: docker-image
    docker run --rm -v "$PWD":/work --entrypoint rm {{image}} -rf {{out}} mkosi.cache mkosi.tools mkosi.tools.manifest .mkosi-private
