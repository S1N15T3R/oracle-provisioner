# ⚡ Oracle Cloud Always Free ARM Instance Provisioner

```text
  ██████╗  ██████╗██╗    ██████╗ ██████╗  ██████╗ ██╗   ██╗██╗███████╗██╗ ██████╗ ███╗   ██╗███████╗██████╗ 
 ██╔═══██╗██╔════╝██║    ██╔══██╗██╔══██╗██╔═══██╗██║   ██║██║██╔════╝██║██╔═══██╗████╗  ██║██╔════╝██╔══██╗
 ██║   ██║██║     ██║    ██████╔╝██████╔╝██║   ██║██║   ██║██║███████╗██║██║   ██║██╔██╗ ██║█████╗  ██████╔╝
 ██║   ██║██║     ██║    ██╔═══╝ ██╔══██╗██║   ██║╚██╗ ██╔╝██║╚════██║██║██║   ██║██║╚██╗██║██╔══╝  ██╔══██╗
 ╚██████╔╝╚██████╗██║    ██║     ██║  ██║╚██████╔╝ ╚████╔╝ ██║███████║██║╚██████╔╝██║ ╚████║███████╗██║  ██║
  ╚═════╝  ╚═════╝╚═╝    ╚═╝     ╚═╝  ╚═╝ ╚═════╝   ╚═══╝  ╚═╝╚══════╝╚═╝ ╚═════╝ ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝
```

> **Autonomous 24/7 capacity catcher for Oracle Cloud Always Free ARM (`VM.Standard.A1.Flex`) compute instances with self-tuning AIMD rate limiting, anti-ban protection, post-launch SSH verification, and clean termination.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Linux](https://img.shields.io/badge/Platform-Linux-orange.svg)](#)
[![OCI CLI](https://img.shields.io/badge/OCI%20CLI-3.x-red.svg)](https://docs.oracle.com/en-us/iaas/Content/API/Concepts/cliconcepts.htm)
[![Shape: VM.Standard.A1.Flex](https://img.shields.io/badge/Shape-VM.Standard.A1.Flex-green.svg)](#)

---

## 📌 The Problem

Oracle Cloud Infrastructure (OCI) offers an industry-leading **Always Free** tier that includes **4 OCPUs and 24 GB of RAM** powered by high-performance Ampere Altra ARM processors.

However, in high-demand regions (such as **Mumbai (`ap-mumbai-1`)**, **Frankfurt**, **Tokyo**, **Phoenix**, and **London**), capacity is perpetually exhausted:
```json
{
  "code": "InternalError",
  "message": "Out of host capacity.",
  "status": 500
}
```

Whenever an instance is deleted or swept by Oracle's idle reclaim engines, freed capacity is claimed within seconds by competing automated bots.

### Why Most Bots Fail
1. **Aggressive Hammering (HTTP 429 Bans)**: Naive scripts sleep 5–10 seconds. Oracle's API gateway throttles them with `429 Too Many Requests`, placing the account in a multi-minute penalty box or triggering permanent tenancy suspension.
2. **Hidden SDK Burst Retries**: By default, the OCI CLI retries failed requests up to 8 times under the hood. A single command silently fires an 8-request burst that burns through rate-limit token buckets.
3. **Premature SSH Alerts**: Scripts that report success immediately upon API acceptance fail when connecting, because cloud-init and `sshd` require 2–4 minutes to initialize after reaching `RUNNING`.
4. **Duplicate Provisioning Loops**: Bugs in loop exit logic frequently cause bots to continue requesting instances after one is already secured, consuming paid trial credits or exceeding Always Free quotas.

---

## 🚀 Key Features

* **🛡️ AIMD Self-Tuning Rate Engine**: Dynamically rides Oracle's token bucket refill rate (90s–100s). Gently speeds up during clean periods and backs off on 429s.
* **⚡ Single-Shot API Calls (`--no-retry`)**: Eliminates hidden Python SDK retry loops, ensuring deterministic 1-request per cycle execution (~0.9s RTT).
* **🔒 Strict Single-Instance Guarantee**: Immediately halts after provisioning and verifying **one** instance. Never loops or creates duplicate VMs.
* **🔍 Multi-Phase Post-Launch Pipeline**:
  1. Polls instance lifecycle state until `RUNNING` (timeout: 300s).
  2. Binds and verifies public IPv4 address.
  3. Waits for 60s cloud-init buffer.
  4. Probes TCP port 22 via netcat with `/dev/tcp` fallback.
  5. Performs real SSH key authentication and queries remote hostname/uptime.
* **📱 Rich Telegram Visual Alerts**: Real-time status cards detailing HTTP response codes, lifetime success ratios, and celebratory launch cards.
* **🌐 Network Outage Resilience**: Automatically pauses on Wi-Fi/network disconnects and resumes seamlessly when connectivity returns.
* **🔄 Systemd 24/7 Daemon**: Survives user logouts and system reboots via `systemd --user` with linger enabled.

---

## 🏗️ Architecture & Workflow

```text
 ┌────────────────────────────────────────────────────────┐
 │                   Provisioning Loop                    │
 └──────────────────────────┬─────────────────────────────┘
                            │
               [ Single-Shot Launch Request ]
               (oci compute instance launch)
                            │
              ┌─────────────┴─────────────┐
              ▼                           ▼
      [ HTTP 500 Capacity ]       [ HTTP 200 / Instance ID ]
              │                           │
    [ AIMD Cadence Sleep ]                ▼
    (85s-100s + Jitter)          [ Lifecycle Poll ]
              │                  (Wait for RUNNING state)
              │                           │
              │                           ▼
              │                  [ Retrieve Public IPv4 ]
              │                  (Wait for VNIC binding)
              │                           │
              │                           ▼
              │                  [ 60s cloud-init Buffer ]
              │                           │
              │                           ▼
              │                  [ Probe TCP Port 22 ]
              │                           │
              │                           ▼
              │                  [ Validate SSH Key Auth ]
              │                  (hostname && uptime)
              │                           │
              │                           ▼
              │                  [ Telegram Celebration Card ]
              │                           │
              │                           ▼
              └───────────────────► [ Clean Exit 0 ]
                                    (HALT - NEVER LOOP)
```

---

## 📦 Prerequisites

1. **Linux Host** (Ubuntu, Debian, Kali, Arch, CentOS, Fedora).
2. **Oracle Cloud CLI (`oci`)**: Configured and authenticated with API signing key:
   ```bash
   bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"
   oci setup config
   ```
3. **Core Utilities**: `bash` (v4+), `jq`, `curl`, `netcat` (`nc`), `openssh-client`.
4. **SSH Keypair**:
   ```bash
   ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -N ""
   ```

---

## ⚙️ Quick Start

### 1. Clone & Configure

```bash
git clone https://github.com/S1N15T3R/oracle-provisioner.git
cd oracle-provisioner

# Create your configuration from the template
cp config.env.example config.env
nano config.env
```

### 2. Populate `config.env`

Fill in your OCI tenancy details:

```bash
COMPARTMENT_ID="ocid1.tenancy.oc1..aaaaaaaaxxxxxxxxxxxxxxxxx"
SUBNET_ID="ocid1.subnet.oc1.ap-mumbai-1.aaaaaaaaxxxxxxxxx"
AVAILABILITY_DOMAIN="nGAL:AP-MUMBAI-1-AD-1"
IMAGE_OCID="ocid1.image.oc1.ap-mumbai-1.aaaaaaaa2jurqb3..."
SSH_KEY_PATH="$HOME/.ssh/id_ed25519"

# Desired Hardware (Always Free ARM)
SHAPE="VM.Standard.A1.Flex"
OCPU_COUNT=2
MEMORY_GB=12
BOOT_VOLUME_SIZE_GB=200
BOOT_VOLUME_VPUS=10
```

### 3. Test Credentials & Connectivity

Execute a single-attempt dry run to verify your OCIDs and API keys:

```bash
./oci_provision.sh --test
```

Expected output:
```text
[2026-09-26 10:00:00] 🧪 TEST MODE: Executing 1 launch attempt to verify OCI credentials
[2026-09-26 10:00:02] Attempt #1 | Result: CAPACITY (500) | Next: 95s
```

---

## 🖥️ Running as a 24/7 Background Service

To keep the provisioner running autonomously across terminal logouts and system reboots:

### 1. Enable User Lingering
```bash
loginctl enable-linger $USER
```

### 2. Install Systemd Service Unit
```bash
mkdir -p ~/.config/systemd/user
cp systemd/oci-provisioner.service ~/.config/systemd/user/

# Adjust path in service file if not installed in default location
sed -i "s|%h/development/oracle-provisioner|$(pwd)|g" ~/.config/systemd/user/oci-provisioner.service

# Reload and enable
systemctl --user daemon-reload
systemctl --user enable --now oci-provisioner.service
```

### 3. Monitor Telemetry
```bash
# Check service status and lifetime scoreboard
./oci_provision.sh --status

# Follow live output logs
tail -f ~/.oci/provisioner.log
```

---

## 📊 Telemetry & Scoreboard

Running `./oci_provision.sh --status` provides an instant dashboard:

```text
═══════════════════════════════════════════════════════════════════
  OCI INSTANCE PROVISIONER STATUS (Autonomous Catcher)
═══════════════════════════════════════════════════════════════════

  Service State   : active
  Active PID      : 71154
  Network Status  : Online ✓
  OCI Config      : ~/.oci/config ✓

─── Recent Activity Log ──────────────────────────────────────────
[2026-09-25 22:15:03] Attempt #51 | Result: CAPACITY (500) | Streak: 16 | Base: 87s
[2026-09-25 22:16:41] Attempt #52 | Result: CAPACITY (500) | Streak: 17 | Base: 87s
[2026-09-25 22:18:22] Attempt #53 | Result: CAPACITY (500) | Streak: 18 | Base: 87s
[2026-09-25 22:19:59] Attempt #54 | Result: CAPACITY (500) | Streak: 19 | Base: 87s
[2026-09-25 22:21:29] ⚡ AIMD Speed Probe: Clean run detected. Testing interval 85s
[2026-09-25 22:21:29] Attempt #55 | Result: CAPACITY (500) | Streak: 20 | Base: 85s

─── Lifetime Scoreboard ─────────────────────────────────────────
  Total Attempts  : 422
  Capacity (500)  : 101
  Rate-Limit (429): 18
═══════════════════════════════════════════════════════════════════
```

---

## 🛡️ Anti-Ban & Rate-Limit Strategy

| Scenario | HTTP Code | Bot Action | Timing |
|---|---|---|---|
| **Data Center Full** | `500` | Log capacity event, continue hunting | Base delay (85s–100s) + Jitter |
| **Token Refill Probe** | `500` | AIMD probe: shave 2s off interval after 5 clean hits | Gradually down to 85s floor |
| **Rate Limit Hit** | `429` | **Immediate Cooldown**: Step back base interval (+5s) | 1st: 135s · 2nd: 250s · 3rd: 360s |
| **Network Disconnect** | `—` | **Auto-Pause**: Halt API calls until connection returns | Probes 8.8.8.8 every 10s |
| **Success** | `200` | **Halt**: Enter post-launch SSH verification and exit | Strict `exit 0` |

---

## 📄 License

Distributed under the [MIT License](LICENSE). Created by [Abdul-Motalib-SamiR (S1N15T3R)](https://github.com/S1N15T3R).
