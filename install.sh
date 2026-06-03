#!/usr/bin/env bash
# shellcheck disable=SC2155,SC2181

IMAGE_TAG='ghcr.io/tashigit/tashi-depin-worker:0'

TROUBLESHOOT_LINK='https://docs.tashi.network/nodes/node-installation/important-notes#troubleshooting'
MANUAL_UPDATE_LINK='https://docs.tashi.network/nodes/node-installation/important-notes#manual-update'

DOCKER_ROOTLESS_LINK='https://docs.docker.com/engine/install/linux-postinstall/'
PODMAN_ROOTLESS_LINK='https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md'

RUST_LOG='info,tashi_depin_worker=debug,tashi_depin_common=debug'

AGENT_PORT=39065

# Color codes
GREEN="\e[32m"
RED="\e[31m"
YELLOW="\e[33m"
RESET="\e[0m"
CHECKMARK="${GREEN}✓${RESET}"
CROSSMARK="${RED}✗${RESET}"
WARNING="${YELLOW}⚠${RESET}"

STYLE_BOLD=$(tput bold)
STYLE_NORMAL=$(tput sgr0)

WARNINGS=0
ERRORS=0

# Logging function (with level and timestamps if `LOG_EXPANDED` is set to a truthy value)
log() {
	# Allow the message to be piped for heredocs
	local message="${2:-$(cat)}"

	if [[ "${LOG_EXPANDED:-0}" -ne 0 ]]; then
		local level="$1"
		local timestamp=$(date +"%Y-%m-%d %H:%M:%S")

		printf "[%s] [%s] %b\n" "${timestamp}" "${level}" "${message}" 1>&2
	else
		printf "%b\n" "$message"
	fi
}

make_bold() {
	# Allows heredoc expansion with pipes
	local s="${1:-$(cat)}"

	printf "%s%s%s" "$STYLE_BOLD" "${s}" "$STYLE_NORMAL"
}

# Print a blank line for visual separation.
horizontal_line() {
	WIDTH=${COLUMNS:-$(tput cols)}
	FILL_CHAR='-'

	# Prints a zero-length string but specifies it should be `$COLUMNS` wide, so the `printf` command pads it with blanks.
	# We then use `tr` to replace those blanks with our padding character of choice.
	printf '\n%*s\n\n' "$WIDTH" '' | tr ' ' "$FILL_CHAR"
}

# munch args
POSITIONAL_ARGS=()

SUBCOMMAND=install

while [[ $# -gt 0 ]]; do
	case $1 in
		--ignore-warnings)
			IGNORE_WARNINGS=y
			;;
		-y | --yes)
			YES=1
			;;
		--auto-update)
			AUTO_UPDATE=y
			;;
		--image-tag=*)
			IMAGE_TAG="${1#"--image-tag="}"
			;;
		--install)
			SUBCOMMAND=install
			;;
		--update)
			SUBCOMMAND=update
			;;
		-*)
			echo "Unknown option $1"
			exit 1
			;;
		*)
			POSITIONAL_ARGS+=("$1")
			;;
	esac

	shift
done

set -- "${POSITIONAL_ARGS[@]}" # restore positional parameters

# Detect OS safely
detect_os() {
	OS=$(
		# shellcheck disable=SC1091
		source /etc/os-release >/dev/null 2>&1
		echo "${ID:-unknown}"
	)
	if [[ "$OS" == "unknown" && "$(uname -s)" == "Darwin" ]]; then
		OS="macos"
	fi
}

# Suggest package installation securely
suggest_install() {
	local package=$1
	case "$OS" in
		debian | ubuntu) echo "    sudo apt update && sudo apt install -y $package" ;;
		fedora) echo "    sudo dnf install -y $package" ;;
		arch) echo "    sudo pacman -S --noconfirm $package" ;;
		opensuse) echo "    sudo zypper install -y $package" ;;
		macos) echo "    brew install $package" ;;
		*) echo "    Please install '$package' manually for your OS." ;;
	esac
}

# Resolve commands dynamically
NPROC_CMD=$(command -v nproc || echo "")
GREP_CMD=$(command -v grep || echo "")
DF_CMD=$(command -v df || echo "")

# Check if a command exists
check_command() {
	command -v "$1" >/dev/null 2>&1
}

# Platform Check
check_platform() {
	PLATFORM_ARG=''

	local arch=$(uname -m)

	# Bash on MacOS doesn't support `@(pattern-list)` apparently?
	if [[ "$arch" == "amd64" || "$arch" == "x86_64" ]]; then
		log "INFO" "Platform Check: ${CHECKMARK} supported platform $arch"
	elif [[ "$OS" == "macos" && "$arch" == arm64 ]]; then
		# Ensure Apple Silicon runs the container as x86_64 using Rosetta
		PLATFORM_ARG='--platform linux/amd64'

		log "WARNING" "Platform Check: ${WARNING} unsupported platform $arch"
		log "INFO" <<-EOF
			MacOS Apple Silicon is not currently supported, but the worker can still run through the Rosetta compatibility layer.
			Performance and earnings will be less than a native node.
			You may be prompted to install Rosetta when the worker node starts.
		EOF
		((WARNINGS++))
	else
		log "ERROR" "Platform Check: ${CROSSMARK} unsupported platform $arch"
		log "INFO" "Join the Tashi Discord to request support for your system."
		((ERRORS++))
		return
	fi
}

# CPU Check
check_cpu() {
	case "$OS" in
		"macos")
			threads=$(sysctl -n hw.ncpu)
			;;
		*)
			if [[ -z "$NPROC_CMD" ]]; then
				log "WARNING" "'nproc' not found. Install coreutils:"
				suggest_install "coreutils"
				((ERRORS++))
				return
			fi
			threads=$("$NPROC_CMD")
			;;
	esac

	if [[ "$threads" -ge 4 ]]; then
		log "INFO" "CPU Check: ${CHECKMARK} Found $threads threads (>= 4 recommended)"
	elif [[ "$threads" -ge 2 ]]; then
		log "WARNING" "CPU Check: ${WARNING} Found $threads threads (>= 2 required, 4 recommended)"
		((WARNINGS++))
	else
		log "ERROR" "CPU Check: ${CROSSMARK} Only $threads threads found (Minimum: 2 required)"
		((ERRORS++))
	fi
}

# Memory Check
check_memory() {
	if [[ -z "$GREP_CMD" ]]; then
		log "ERROR" "Memory Check: ${WARNING} 'grep' not found. Install grep:"
		suggest_install "grep"
		((ERRORS++))
		return
	fi

	case "$OS" in
		"macos")
			total_mem_bytes=$(sysctl -n hw.memsize)
			total_mem_kb=$((total_mem_bytes / 1024))
			;;
		*)
			total_mem_kb=$("$GREP_CMD" MemTotal /proc/meminfo | awk '{print $2}')
			;;
	esac

	total_mem_gb=$((total_mem_kb / 1024 / 1024))

	if [[ "$total_mem_gb" -ge 4 ]]; then
		log "INFO" "Memory Check: ${CHECKMARK} Found ${total_mem_gb}GB RAM (>= 4GB recommended)"
	elif [[ "$total_mem_gb" -ge 2 ]]; then
		log "WARNING" "Memory Check: ${WARNING} Found ${total_mem_gb}GB RAM (>= 2GB required, 4GB recommended)"
		((WARNINGS++))
	else
		log "ERROR" "Memory Check: ${CROSSMARK} Only ${total_mem_gb}GB RAM found (Minimum: 2GB required)"
		((ERRORS++))
	fi
}

# Disk Space Check
check_disk() {
	case "$OS" in
		"macos")
			available_disk_kb=$(
				"$DF_CMD" -kcI 2>/dev/null |
					tail -1 |
					awk '{print $4}'
			)
			total_mem_bytes=$(sysctl -n hw.memsize)
			;;
		*)
			available_disk_kb=$(
				"$DF_CMD" -kx tmpfs --total 2>/dev/null |
					tail -1 |
					awk '{print $4}'
			)
			;;
	esac

	available_disk_gb=$((available_disk_kb / 1024 / 1024))

	if [[ "$available_disk_gb" -ge 20 ]]; then
		log "INFO" "Disk Space Check: ${CHECKMARK} Found ${available_disk_gb}GB free (>= 20GB required)"
	else
		log "ERROR" "Disk Space Check: ${CROSSMARK} Only ${available_disk_gb}GB free space (Minimum: 20GB required)"
		((ERRORS++))
	fi
}

# Docker or Podman Check
check_container_runtime() {
	if check_command "docker"; then
		log "INFO" "Container Runtime Check: ${CHECKMARK} Docker is installed"
		CONTAINER_RT=docker
	elif check_command "podman"; then
		log "INFO" "Container Runtime Check: ${CHECKMARK} Podman is installed"
		CONTAINER_RT=podman
	else
		log "ERROR" "Container Runtime Check: ${CROSSMARK} Neither Docker nor Podman is installed."
		suggest_install "docker.io"
		suggest_install "podman"
		((ERRORS++))
	fi
}

# Check network connectivity & NAT status
check_internet() {
	# Step 1: Confirm Public Internet Access (No ICMP Required)
	if curl -s --head --connect-timeout 3 https://google.com | grep "HTTP" >/dev/null 2>&1; then
		log "INFO" "Internet Connectivity: ${CHECKMARK} Device has public Internet access."
	elif wget --spider --timeout=3 --quiet https://google.com; then
		log "INFO" "Internet Connectivity: ${CHECKMARK} Device has public Internet access."
	else
		log "ERROR" "Internet Connectivity: ${CROSSMARK} No internet access detected!"
		((ERRORS++))
	fi
}

get_local_ip() {
	if [[ "$OS" == "macos" ]]; then
		LOCAL_IP=$(ifconfig -l | xargs -n1 ipconfig getifaddr)
	elif check_command hostname; then
		LOCAL_IP=$(hostname -I | awk '{print $1}')
	elif check_command ip; then
		# Use `ip route` to find what IP address connects to the internet
		LOCAL_IP=$(ip route get '1.0.0.0' | grep -Po "src \K(\S+)")
	fi
}

get_public_ip() {
	PUBLIC_IP=$(curl -s https://api.ipify.org || wget -qO- https://api.ipify.org)
}

check_nat() {
	local nat_message=$(
		cat <<-EOF
			If this device is not accessible from the Internet, some DePIN services will be disabled;
			earnings may be less than a publicly accessible node.

			For maximum earning potential, ensure UDP port $AGENT_PORT is forwarded to this device.
			Consult your router’s manual or contact your Internet Service Provider for details.
		EOF
	);

	# Step 2: Get local & public IP
	get_local_ip
	get_public_ip

	if [[ -z "$LOCAL_IP" ]]; then
		log "WARNING" "NAT Check: ${WARNING} Could not determine local IP."
		log "WARNING" "$nat_message"
		return
	fi

	if [[ -z "$PUBLIC_IP" ]]; then
		log "WARNING" "NAT Check: ${WARNING} Could not determine public IP."
		log "WARNING" "$nat_message"
		return
	fi

	# Step 3: Determine NAT Type
	if [[ "$LOCAL_IP" == "$PUBLIC_IP" ]]; then
		log "INFO" "NAT Check: ${CHECKMARK} Open NAT / Publicly accessible (Public IP: $PUBLIC_IP)"
		return
	fi

	log "WARNING" "NAT Check: NAT detected (Local: $LOCAL_IP, Public: $PUBLIC_IP)"
	log "WARNING" "$nat_message"
}

check_root_required() {
	# Docker and Podman on Mac run a Linux VM. The client commands outside the VM do not require root.
	if [[ "$OS" == "macos" ]]; then
		SUDO_CMD=''
		log "INFO" "Privilege Check: ${CHECKMARK} Root privileges are not needed on MacOS"
		return
	fi

	if [[ "$CONTAINER_RT" == "docker" ]]; then
		if (groups "$USER" | grep docker >/dev/null); then
			log "INFO" "Privilege Check: ${CHECKMARK} User is in 'docker' group."
			log "INFO" "Worker container can be started without needing superuser privileges."
		elif [[ -w "$DOCKER_HOST" ]] || [[ -w "/var/run/docker.sock" ]]; then
			log "INFO" "Privilege Check: ${CHECKMARK} User has access to the Docker daemon socket."
			log "INFO" "Worker container can be started without needing superuser privileges."
		else
			SUDO_CMD="sudo -g docker"
			log "WARNING" "Privilege Check: ${WARNING} User is not in 'docker' group."
			log "WARNING" <<-EOF
				${WARNING} 'docker run' command will be executed using '${SUDO_CMD}'
				You may be prompted for your password during setup.

				Rootless configuration is recommended to avoid this requirement.
				For more information, see $DOCKER_ROOTLESS_LINK
			EOF
			((WARNINGS++))
		fi
	elif [[ "$CONTAINER_RT" == "podman" ]]; then
		# Check that the user and their login group are assigned substitute ID ranges
		if (grep "^$USER:" /etc/subuid >/dev/null) && (grep "^$(id -gn):" /etc/subgid >/dev/null); then
			log "INFO" "Privilege Check: ${CHECKMARK} User can create Podman containers without root."
			log "INFO" "Worker container can be started without needing superuser privileges."
		else
			SUDO_CMD="sudo"
			log "WARNING" "Privilege Check: ${WARNING} User cannot create rootless Podman containers."
			log "WARNING" <<-EOF
				${WARNING} 'podman run' command will be executed using '${SUDO_CMD}'
				You may be prompted for your sudo password during setup.

				Rootless configuration is recommended to avoid this requirement.
				For more information, see $PODMAN_ROOTLESS_LINK
			EOF
			((WARNINGS++))
		fi
	fi
}

prompt_auto_updates() {
	log "INFO" <<-EOF
		Your DePIN worker will require periodic updates to ensure that it keeps up with new features and bug fixes.
		Out-of-date workers may be excluded from the DePIN network and be unable to complete jobs or earn rewards.

		We recommend enabling automatic updates, which take place entirely in the container
		and do not make any changes to your system.

		Otherwise, you will need to check the worker logs regularly to see when a new update is available,
		and apply the update manually.\n
	EOF

	local choice=n

	if [[ (-t 2)]]; then # If stderr is not connected to a TTY, we can't prompt.
		prompt "Enable automatic updates? (Y/n) " choice
	fi

	# Blank line
	echo ""

	case "$choice" in
		n | N)
			log "INFO" "Automatic updates $(make_bold 'disabled'). For manual upgrade instructions, see:\n$MANUAL_UPDATE_LINK"
			;;
		*)
			log "INFO" "Automatic updates enabled."
			AUTO_UPDATE=y
			;;
	esac
}

prompt() {
	local prompt="${1?}"
	local variable="${2?}"

	# read -p in zsh is "read from coprocess", whatever that means
	printf "%b" "$prompt"

	# Always read from TTY even if piped in
	read -r "${variable?}" </dev/tty

	return $?
}

check_warnings() {
	if [[ "$ERRORS" -gt 0 ]]; then
		log "ERROR" "System does not meet minimum requirements. Exiting."
		exit 1
	elif [[ "$WARNINGS" -eq 0 ]]; then
		log "INFO" "System requirements met."
		return
	fi

	log "WARNING" "System meets minimum but not recommended requirements.\n"

	if [[ "$IGNORE_WARNINGS" ]]; then
			log "INFO" "'--ignore-warnings' was passed. Continuing with installation."
			return
	fi

	if [[ ! (-t 2) && ! $YES ]]; then # If stderr is not connected to a TTY, we can't prompt.
		log "ERROR" "Cannot prompt to continue. Re-run this with '--ignore-warnings' to continue installation."
		exit 1
	fi

	prompt "Do you want to continue anyway? (y/N) " choice

	if [[ "$choice" != [yY] ]]; then
		exit 0
	fi
}

prompt_continue() {
	if [[ ! (-t 2) && ! $YES ]]; then # If stderr is not connected to a TTY, we can't prompt.
		log "ERROR" "Cannot prompt to continue. Re-run this with '--yes' to continue installation."
		exit 1
	fi

	prompt "Ready to $SUBCOMMAND worker node. Do you want to continue? (Y/n) " choice

	if [[ "$choice" == [nN] ]]; then
		exit 0
	fi

	echo ""
}

CONTAINER_NAME=tashi-depin-worker
AUTH_VOLUME=tashi-depin-worker-auth
AUTH_DIR="/home/worker/auth"

# Docker rejects `--pull=always` with an image SHA
PULL_FLAG=$([[ "$IMAGE_TAG" == ghcr* ]] && echo "--pull=always")

# shellcheck disable=SC2120
make_setup_cmd() {
		local sudo="${1-$SUDO_CMD}"

		cat <<-EOF
			${sudo:+"$sudo "}${CONTAINER_RT} run --rm -it \\
				--mount type=volume,src=$AUTH_VOLUME,dst=$AUTH_DIR \\
				$PULL_FLAG $PLATFORM_ARG $IMAGE_TAG \\
				interactive-setup $AUTH_DIR
		EOF
}

make_run_cmd() {
	local sudo="${1-$SUDO_CMD}"
	local cmd="${2-"run -d"}"
	local name="${3-$CONTAINER_NAME}"
	local volumes_from="${4+"--volumes-from=$4"}"

	local auto_update_arg=''
	local restart_arg=''

	if [[ $AUTO_UPDATE == "y" ]]; then
		auto_update_arg="--unstable-update-download-path /tmp/tashi-depin-worker"
	fi

	if [[ "$CONTAINER_RT" == "docker" ]]; then
		restart_arg="--restart=on-failure"
	fi

	cat <<-EOF
		${sudo:+"$sudo "}${CONTAINER_RT} $cmd -p "$AGENT_PORT:$AGENT_PORT" -p 127.0.0.1:9000:9000 \\
				--mount type=volume,src=$AUTH_VOLUME,dst=$AUTH_DIR \\
				--name "$name" -e RUST_LOG="$RUST_LOG" $volumes_from \\
				$PULL_FLAG $restart_arg $PLATFORM_ARG $IMAGE_TAG \\
				run $AUTH_DIR \\
				$auto_update_arg \\
				${PUBLIC_IP:+"--agent-public-addr=$PUBLIC_IP:$AGENT_PORT"}
	EOF
}

install() {
	log "INFO" "Installing worker. The commands being run will be printed for transparency.\n"

	log "INFO" "Starting worker in interactive setup mode.\n"

	local setup_cmd=$(make_setup_cmd)

	sh -c "set -ex; $setup_cmd"

	local exit_code=$?

	echo ""

	if [[ $exit_code -eq 130 ]]; then
		log "INFO" "Worker setup cancelled. You may re-run this script at any time."
		exit 0
	elif [[ $exit_code -ne 0 ]]; then
		log "ERROR" "Setup failed ($exit_code): ${CROSSMARK} Please see the following page for troubleshooting instructions: ${TROUBLESHOOT_LINK}."
		exit 1
	fi

	local run_cmd=$(make_run_cmd)

	sh -c "set -ex; $run_cmd"

	exit_code=$?

	echo ""

	if [[ $exit_code -ne 0 ]]; then
		log "ERROR" "Worker failed to start ($exit_code): ${CROSSMARK} Please see the following page for troubleshooting instructions: ${TROUBLESHOOT_LINK}."
	fi
}

update() {
	log "INFO" "Updating worker. The commands being run will be printed for transparency.\n"

	local container_old="$CONTAINER_NAME"
	local container_new="$CONTAINER_NAME-new"

	local create_cmd=$(make_run_cmd "" "create" "$container_new" "$container_old")

	# Execute this whole next block as `sudo` if necessary.
	# Piping means the sub-process reads line by line and can tell us right where it failed.
	# Note: when referring to local shell variables *in* the script, be sure to escape: \$foo
	${SUDO_CMD:+"$SUDO_CMD "}bash <<-EOF
		set -x

		($CONTAINER_RT inspect "$CONTAINER_NAME-old" >/dev/null 2>&1)

		if [ \$? -eq 0 ]; then
				echo "$CONTAINER_NAME-old already exists (presumably from a failed run), please delete it before continuing" 1>&2
				exit 1
		fi

		($CONTAINER_RT inspect "$container_new" >/dev/null 2>&1)

		if [ \$? -eq 0 ]; then
				echo "$container_new already exists (presumably from a failed run), please delete it before continuing" 1>&2
				exit 1
		fi

		set -ex

		$create_cmd
		$CONTAINER_RT stop $container_old
		$CONTAINER_RT start $container_new
		$CONTAINER_RT rename $container_old $CONTAINER_NAME-old
		$CONTAINER_RT rename $container_new $CONTAINER_NAME

		echo -n "Would you like to delete $CONTAINER_NAME-old? (Y/n) "
		read -r choice </dev/tty

		if [[ "\$choice" != [nN] ]]; then
				$CONTAINER_RT rm $CONTAINER_NAME-old
		fi
	EOF

	if [[ $? -ne 0 ]]; then
		log "ERROR" "Worker failed to upgrade: ${CROSSMARK} Please see the following page for troubleshooting instructions: ${TROUBLESHOOT_LINK}."
		exit 1
	fi
}

# Display ASCII Art (Tashi Logo)
display_logo() {
	cat 1>&2 <<-EOF

		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		#-:::::::::::::::::::::::::::::=%@@@@@@@@@@@@@@%=:::::::::::::::::::::::::::::-#
		@@*::::::::::::::::::::::::::::::+%@@@@@@@@@@%+::::::::::::::::::::::::::::::*@@
		@@@@+::::::::::::::::::::::::::::::+%@@@@@@%+::::::::::::::::::::::::::::::+@@@@
		@@@@@%=::::::::::::::::::::::::::::::+%@@%+::::::::::::::::::::::::::::::=%@@@@@
		@@@@@@@#-::::::::::::::::::::::::::::::@@::::::::::::::::::::::::::::::-#@@@@@@@
		@@@@@@@@@*:::::::::::::::::::::::::::::@@:::::::::::::::::::::::::::::*@@@@@@@@@
		@@@@@@@@@@%+:::::::::::::::::::::::::::@@:::::::::::::::::::::::::::+%@@@@@@@@@@
		@@@@@@@@@@@@%++++++++++++-:::::::::::::@@:::::::::::::-++++++++++++%@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@#-:::::::::::@@:::::::::::-#@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@*::::::::::@@::::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*:::::::::@@:::::::::*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@#:::::::::@@:::::::::#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@%+:::::::@@:::::::+%@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*-::::@@::::-*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@*-::@@::-*@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
		@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@#=@@=#@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@


	EOF
}

post_install() {
		echo ""

		log "INFO" "Worker is running: ${CHECKMARK}"

		echo ""

		local status_cmd="${SUDO_CMD:+"$sudo "}${CONTAINER_RT} ps"
		local logs_cmd="${sudo:+"$sudo "}${CONTAINER_RT} logs $CONTAINER_NAME"

		log "INFO" "To check the status of your worker: '$status_cmd' (name: $CONTAINER_NAME)"
		log "INFO" "To view the logs of your worker: '$logs_cmd'"
}

# Detect OS before running checks
detect_os

# Run all checks
display_logo

log "INFO" "Starting system checks..."

echo ""

check_platform
check_cpu
check_memory
check_disk
check_container_runtime
check_root_required
check_internet

echo ""

check_warnings

horizontal_line

# Integrated NAT check. This is separate from system requirements because most manually started worker nodes
# are expected to be behind some sort of NAT, so this is mostly informational.
check_nat

horizontal_line

prompt_auto_updates

horizontal_line

prompt_continue

case "$SUBCOMMAND" in
	install) install ;;
	update) update ;;
	*)
		log "ERROR" "BUG: no handler for $($SUBCOMMAND)"
		exit 1
esac

post_install
