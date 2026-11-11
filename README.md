# sparkToolset

Desktop start/stop helpers for a single NVIDIA DGX Spark that runs k3s (Kubernetes), vLLM and Docker.
Each program asks before it changes anything, shows progress, and closes cleanly.

> **Unofficial.** This project is not affiliated with or endorsed by NVIDIA. NVIDIA and DGX are trademarks of NVIDIA Corporation.

## Programs

| Folder | Program | What it does |
|---|---|---|
| `vllm/` | Start vLLM, Stop vLLM | Starts or stops a vLLM model server in k3s; asks which model if several are installed |
| `kubernetes/` | Start Kubernetes, Stop Kubernetes | Starts k3s, or drains the node and stops k3s gently (stops vLLM first) |
| `grafana/` | Open Grafana | Opens a tunnel to Grafana in k3s and shows the page |
| `docker/` | Start Docker, Stop Docker | Stops all running containers gently and the Docker service; Start brings the saved containers back |
| separate repository: [terminal4Spark](https://github.com/kodati3shrini3/terminal4Spark) | sparkTerminal | A separate terminal window with named tabs, per-tab prompt settings and an optional copy of each command result. Installed on its own (see below) |
| `lib/` | Shared check | Each program checks that the software it needs is installed and says what is missing |

## Install

    git clone https://github.com/kodati3shrini3/sparkToolset.git
    cd sparkToolset
    ./installLaunchersMenuAndDesktop.sh --dry-run     # shows what would be created, changes nothing
    ./installLaunchersMenuAndDesktop.sh               # creates icons only for programs whose software is installed

`./installLaunchersMenuAndDesktop.sh --no-desktop` skips the Desktop icons, `./installLaunchersMenuAndDesktop.sh --remove` removes the icons it created. It only touches the launchers of this toolset.

## sparkTerminal (separate repository)

sparkTerminal is a terminal window with named tabs, a readable prompt for each tab and an optional copy of each command result to the clipboard. It now lives in its own repository, [terminal4Spark](https://github.com/kodati3shrini3/terminal4Spark), with its own install and uninstall scripts and its own README.

    git clone https://github.com/kodati3shrini3/terminal4Spark.git
    cd terminal4Spark
    ./installSparkTerminal.sh --dry-run    # shows what would be done, changes nothing
    ./installSparkTerminal.sh              # asks for a folder, then creates a Desktop icon and a menu entry

It is not installed by `installLaunchersMenuAndDesktop.sh`, and the other programs here do not need it.

## What it assumes

| Area | Assumption |
|---|---|
| Tools | `kubectl`, `jq`, `curl`, `flock`, `systemctl`, `sudo`, `ss`, `xdg-open`; `docker` for the Docker programs. `zenity` (dialogs) and `notify-send` (notices) are optional. |
| vLLM | Models deployed with the vLLM Production Stack Helm chart (labels `app.kubernetes.io/part-of=vllm-stack` and `app.kubernetes.io/component=serving-engine`) |
| Grafana | Service `kps-grafana` in namespace `monitoring` (kube-prometheus-stack), tunnel on local port 23000 |
| Docker | Compose project `ai-stack` at `~/AI-Stack/docker-compose.yaml`; override with `SPARK_DOCKER_PROJECT` and `SPARK_DOCKER_COMPOSE_FILE` |

## Tested on

NVIDIA DGX Spark (GB10, ARM64), DGX OS (Ubuntu 24.04), k3s. The vLLM, Kubernetes and Grafana programs are tested most. The Docker programs are less tested.

## Warning

The Stop programs stop services. Stop Docker stops every running container. Read the dialog before you press OK.

## License

MIT, see `LICENSE`.
