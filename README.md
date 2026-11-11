# sparkToolset

Clickable Start and Stop icons for the AI services on an NVIDIA DGX Spark: Docker, Kubernetes (k3s), vLLM models and Grafana. You click an icon instead of typing commands. Each icon asks before it changes anything, shows progress and closes by itself when it is done.

> **Unofficial.** This project is not affiliated with or endorsed by NVIDIA. NVIDIA and DGX are trademarks of NVIDIA Corporation.

## Words used here

| Word | What it means | Example on this machine |
|---|---|---|
| Docker | Runs programs in containers (a container is a program packed with its own settings). You start and stop them yourself. | A database or a chat web page in a container |
| Kubernetes (k3s) | A manager that starts, watches and restarts containers for you. k3s is a small, lightweight version. | The manager that runs your AI models |
| vLLM | A program that loads an AI model and answers questions sent to it | One vLLM per model, for example a medical language model |
| Grafana | A web page with charts about how the machine and the cluster are doing | The page the Open Grafana icon shows |
| Tunnel | A temporary private connection from a port on this computer to a service inside Kubernetes | Opens Grafana, which lives inside Kubernetes |

Docker and Kubernetes run separately. Stopping one does not stop the other.

## What you get

| Icon | What happens when you click it | When to use it |
|---|---|---|
| Start vLLM, Stop vLLM | Starts or stops AI models. With several models installed you tick the ones you want, and you get a memory warning before more than one runs. | To free memory, or to load a model |
| Start Kubernetes, Stop Kubernetes | Starts Kubernetes, or stops it gently: first the models, then the node is drained (its work is moved off) and k3s stops | Before maintenance, or to free the machine |
| Open Grafana | Opens a tunnel to Grafana and shows the page | To look at the charts |
| Start Docker, Stop Docker | Stop shuts down all running containers one by one and then the Docker service. Start brings the saved containers back. | To free memory, or before a restart |

The icons appear in the application menu and on the Desktop. Stop Docker and Stop Kubernetes may ask for your administrator password. For Docker and vLLM, a second click on an icon that is still working shows a live status window.

## Before you start

You need these programs. The installer and each icon check for them and tell you what is missing. They never install anything for you.

| Program | Why |
|---|---|
| `kubectl` | Talks to Kubernetes |
| `docker` | Needed only for the Docker icons |
| `systemctl`, `sudo` | Start and stop services (needs administrator rights) |
| `jq`, `curl`, `ss`, `flock`, `xdg-open` | Small helpers: read answers from other programs, make web requests, list open ports, make sure two actions do not run at once, open a page in the browser |
| `zenity`, `notify-send` | Optional: dialog windows and desktop notices. Without them the message is printed in the terminal. |

## Install

1. Download the toolset:

        git clone https://github.com/kodati3shrini3/sparkToolset.git
        cd sparkToolset

2. See what would be created. This changes nothing:

        ./installLaunchersMenuAndDesktop.sh --dry-run

3. Create the icons. Only programs whose software is installed get an icon:

        ./installLaunchersMenuAndDesktop.sh

Options: `--no-desktop` skips the Desktop icons. `--remove` removes the icons the installer created. It only touches the icons of this toolset.

## If your setup is different

The toolset was built on the author's machine. If yours differs, these are the places that matter:

| Part | What it expects | Why / how to change |
|---|---|---|
| vLLM | Models installed with the vLLM Production Stack Helm chart, found through the labels `app.kubernetes.io/part-of=vllm-stack` and `app.kubernetes.io/component=serving-engine` | Models with these labels appear in the list by themselves |
| Grafana | The service `kps-grafana` in the namespace `monitoring` (kube-prometheus-stack), opened on local port 23000 | These values are written in `grafana/openGrafana.sh` |
| Docker | The compose project `ai-stack` in `~/AI-Stack/docker-compose.yaml` | Set the variables `SPARK_DOCKER_PROJECT` and `SPARK_DOCKER_COMPOSE_FILE` |

## Related tools (separate repositories)

| Tool | What it does |
|---|---|
| [terminal4Spark](https://github.com/kodati3shrini3/terminal4Spark) | sparkTerminal: a terminal window with named tabs, a readable prompt per tab and an optional copy of each command result. Installed on its own. |
| [showPortsWidget](https://github.com/kodati3shrini3/showPortsWidget) | A window that lists which ports are open on this machine and what each one is for |

## Tested on

NVIDIA DGX Spark (GB10, ARM64), DGX OS (Ubuntu 24.04), k3s. The vLLM, Kubernetes and Grafana icons are tested most. The Docker icons are less tested.

## Warning

The Stop icons stop services. Stop Docker stops every running container. Read the dialog before you press OK.

## License

MIT, see `LICENSE`. Contributions are welcome: see `CONTRIBUTING.md`.
